#!/usr/bin/env python3
"""
Лабораторная оценка сценариев обхода: захват трафика и базовый анализ pcap.

Использование:
  # Захват 30 сек на интерфейсе any (требуются права на захват)
  python bypass_lab_capture_traffic.py --duration 30 --out /tmp/capture.pcap

  # Анализ существующего pcap (базовая сводка)
  python bypass_lab_capture_traffic.py --analyze /path/to/capture.pcap

См. также: docs/VPN_BYPASS_LAB_EVALUATION.md
"""

import argparse
import subprocess
import sys
import os
from pathlib import Path


def capture(interface: str, duration: int, out_path: str) -> bool:
    """Захват трафика через tcpdump."""
    out_path = os.path.abspath(out_path)
    parent = os.path.dirname(out_path)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    cmd = [
        "tcpdump",
        "-i", interface,
        "-w", out_path,
        "-s", "0",
        "not", "host", "127.0.0.1",
    ]
    print(f"Захват на интерфейсе {interface} в течение {duration} сек -> {out_path}")
    print("Запустите нужный трафик (VPN, браузер, PoC клиент) в другом окне.")
    try:
        subprocess.run(cmd, timeout=duration + 5)
    except FileNotFoundError:
        print("Ошибка: tcpdump не найден. Установите tcpdump или запустите вручную:")
        print("  sudo tcpdump -i any -w <файл.pcap> -s 0")
        return False
    except subprocess.TimeoutExpired:
        pass
    print(f"Сохранено: {out_path}")
    return os.path.isfile(out_path)


def _run_tshark(pcap_path: str, display_filter: str, fields: list) -> list:
    """Запуск tshark с полями; возвращает список строк (по одной на пакет)."""
    try:
        cmd = ["tshark", "-r", pcap_path, "-Y", display_filter, "-T", "fields"]
        for f in fields:
            cmd.extend(["-e", f])
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            return []
        return [l.strip() for l in (r.stdout or "").strip().splitlines() if l.strip()]
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []


def analyze_with_tshark(pcap_path: str) -> bool:
    """Базовый анализ через tshark (если установлен): порты, SNI, JA3/JA4, размеры первых пакетов."""
    if not os.path.isfile(pcap_path):
        print(f"Файл не найден: {pcap_path}")
        return False
    try:
        from collections import Counter

        # Подсчёт соединений по портам назначения
        lines = _run_tshark(pcap_path, "tcp", ["tcp.dstport", "ip.dst"])
        if not lines:
            print("Нет TCP-пакетов в pcap.")
        else:
            ports = Counter()
            for line in lines:
                parts = line.split("\t")
                if parts:
                    try:
                        ports[int(parts[0])] += 1
                    except (ValueError, IndexError):
                        pass
            print("Порты назначения (топ):")
            for port, count in ports.most_common(15):
                print(f"  {port}: {count} пакетов")

        # SNI (TLS Client Hello)
        snis = _run_tshark(pcap_path, "tls.handshake.type == 1", ["tls.handshake.extensions_server_name"])
        if snis:
            print("SNI (TLS Client Hello):")
            for s in sorted(set(snis))[:20]:
                print(f"  {s}")

        # JA3 (TLS Client Hello fingerprint) — поддерживается в tshark 3.2+
        ja3_lines = _run_tshark(pcap_path, "tls.handshake.type == 1", ["tls.handshake.ja3"])
        if ja3_lines:
            print("JA3 (TLS Client Hello):")
            for ja3 in sorted(set(ja3_lines))[:15]:
                print(f"  {ja3}")
        else:
            # Попробуем поле ja3 (без точки)
            ja3_alt = _run_tshark(pcap_path, "tls.handshake.type == 1", ["ja3"])
            if ja3_alt:
                print("JA3:")
                for ja3 in sorted(set(ja3_alt))[:15]:
                    print(f"  {ja3}")

        # Размеры первых N пакетов (client->server, по frame.len)
        frame_lens = _run_tshark(pcap_path, "tcp", ["frame.len"])[:20]
        if frame_lens:
            print("Размеры первых пакетов (байт):")
            print("  " + ", ".join(frame_lens[:15]))

        return True
    except FileNotFoundError:
        print("tshark не установлен. Установите Wireshark/tshark для детального разбора (SNI, JA3).")
        _analyze_fallback_tcpdump(pcap_path)
        return True


def _analyze_fallback_tcpdump(pcap_path: str) -> None:
    """Fallback: базовая сводка через tcpdump при отсутствии tshark."""
    import re
    try:
        r = subprocess.run(
            ["tcpdump", "-r", pcap_path, "-n"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=30,
        )
        lines = (r.stdout or "").strip().splitlines()
        if r.returncode != 0 and not lines:
            return
        print(f"Пакетов в pcap (tcpdump): {len(lines)}")
        # Грубый подсчёт портов из вывода tcpdump (формат .443: или >.443 )
        ports: dict = {}
        for line in lines:
            for m in re.finditer(r"[.>](\d{2,5})(?:\s|:|$)", line):
                try:
                    p = int(m.group(1))
                    if 1 <= p <= 65535:
                        ports[p] = ports.get(p, 0) + 1
                except ValueError:
                    pass
        if ports:
            from collections import Counter
            top = Counter(ports).most_common(10)
            print("Порты (топ по упоминаниям):")
            for port, count in top:
                print(f"  {port}: {count}")
    except FileNotFoundError:
        pass


def main():
    parser = argparse.ArgumentParser(description="Захват и базовый анализ трафика для оценки сценариев обхода")
    parser.add_argument("--duration", type=int, default=30, help="Длительность захвата в секундах")
    parser.add_argument("--out", default="/tmp/bypass_lab_capture.pcap", help="Путь к выходному pcap")
    parser.add_argument("--interface", "-i", default="any", help="Сетевой интерфейс для tcpdump")
    parser.add_argument("--analyze", metavar="PCAP", help="Только анализ существующего pcap")
    args = parser.parse_args()

    if args.analyze:
        analyze_with_tshark(args.analyze)
        print("\nДальше: сравните JA3/JA4 с эталоном (браузер/приложение). См. docs/VPN_BYPASS_LAB_EVALUATION.md")
        return 0

    if os.geteuid() != 0:
        print("Захват пакетов обычно требует прав root. Запустите: sudo python ...")
    ok = capture(args.interface, args.duration, args.out)
    if ok:
        print("\nАнализ записанного файла:")
        analyze_with_tshark(args.out)
        print("\nДальше: docs/VPN_BYPASS_LAB_EVALUATION.md")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
