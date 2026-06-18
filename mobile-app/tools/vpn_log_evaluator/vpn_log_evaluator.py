#!/usr/bin/env python3
"""VPN Log Evaluator - оценка VPN-сервиса GraniVPN по логам.
Поддерживает: plain logcat, JSON (Android Studio/DevTools export)."""
import argparse
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field

@dataclass
class VpnLogMetrics:
    connection_successes: int = 0
    connection_errors: int = 0
    connection_timing_success_ms: list = field(default_factory=list)
    protocols: dict = field(default_factory=lambda: defaultdict(int))
    native_crashes: int = 0
    tcp_bind_failures: int = 0
    no_space_left_count: int = 0
    connection_logger_errors: int = 0
    tun2socks_bind_timeouts: int = 0
    disconnect_durations_ms: list = field(default_factory=list)
    # Мониторинг: смена сети, трафик, reconnect
    network_changes: int = 0
    vpn_traffic_first_seen: int = 0
    reconnect_starts: int = 0
    disconnect_dones: int = 0

PATTERNS = {
    "success": re.compile(r"ПОДКЛЮЧЕНИЕ УСПЕШНО УСТАНОВЛЕНО", re.I),
    "connection_timing": re.compile(r"\[Connection timing\] result=(success|error) total_ms=(\d+)", re.I),
    "native_crash": re.compile(r"pthread_mutex_lock|Fatal signal 6", re.I),
    "tcp_bind_fail": re.compile(r"tcp_bind_to_netif failed", re.I),
    "no_space_left": re.compile(r"no space left", re.I),
    "connection_logger_error": re.compile(r"ConnectionLogger.*Ошибка|connection timeout", re.I),
    "tun2socks_bind_timeout": re.compile(r"Tun2SocksProcessService bind timeout", re.I),
    "disconnect_completed": re.compile(r"Отключение на сервере завершено за (\d+)ms", re.I),
    # Мониторинг: смена сети, трафик через туннель
    "network_change": re.compile(r"\[MONITOR\] network_change|network_change.*network_from", re.I),
    "vpn_traffic": re.compile(r"\[VPN_TRAFFIC\]|traffic_first_seen", re.I),
    "reconnect_start": re.compile(r"\[reconnect\] старт \(после смены сети\)|stage.*reconnect_start", re.I),
    "disconnect_done": re.compile(r"stage.*disconnect_done|disconnect_done", re.I),
}

def iter_messages(content):
    """Итерирует по сообщениям лога. Yields строки для parse_line."""
    try:
        data = json.loads(content)
        if isinstance(data, dict) and "logcatMessages" in data:
            for entry in data["logcatMessages"]:
                msg = entry.get("message") if isinstance(entry, dict) else None
                if isinstance(msg, str):
                    yield msg
            return
    except (json.JSONDecodeError, TypeError):
        pass
    for line in content.splitlines():
        yield line


def parse_line(m, line):
    if PATTERNS["success"].search(line): m.connection_successes += 1
    t = PATTERNS["connection_timing"].search(line)
    if t:
        if t.group(1) == "success":
            m.connection_timing_success_ms.append(int(t.group(2)))
        else: m.connection_errors += 1
    if PATTERNS["native_crash"].search(line): m.native_crashes += 1
    if PATTERNS["tcp_bind_fail"].search(line): m.tcp_bind_failures += 1
    if PATTERNS["no_space_left"].search(line): m.no_space_left_count += 1
    if PATTERNS["connection_logger_error"].search(line): m.connection_logger_errors += 1
    if PATTERNS["tun2socks_bind_timeout"].search(line): m.tun2socks_bind_timeouts += 1
    d = PATTERNS["disconnect_completed"].search(line)
    if d: m.disconnect_durations_ms.append(int(d.group(1)))
    if PATTERNS["network_change"].search(line): m.network_changes += 1
    if PATTERNS["vpn_traffic"].search(line): m.vpn_traffic_first_seen += 1
    if PATTERNS["reconnect_start"].search(line): m.reconnect_starts += 1
    if PATTERNS["disconnect_done"].search(line): m.disconnect_dones += 1

def compute_score(m):
    s = 100 - m.native_crashes*15 - m.tcp_bind_failures*25 - min(10, m.no_space_left_count//10)
    tot = m.connection_successes + m.connection_errors
    if tot and m.connection_errors:
        s -= int(30 * m.connection_errors / tot)
    if m.connection_timing_success_ms and sum(m.connection_timing_success_ms)/len(m.connection_timing_success_ms) > 8000:
        s -= 5
    if m.disconnect_durations_ms and sum(m.disconnect_durations_ms)/len(m.disconnect_durations_ms) > 3000:
        s -= 5
    s -= m.tun2socks_bind_timeouts * 10
    s -= min(5, m.connection_logger_errors // 3)  # незначительный штраф
    return max(0, min(100, s))

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--input", "-i", help="Файл логов (JSON или plain logcat)")
    p.add_argument("--quiet", "-q", action="store_true")
    a = p.parse_args()
    m = VpnLogMetrics()
    if a.input:
        with open(a.input, encoding="utf-8", errors="replace") as f:
            content = f.read()
    else:
        content = sys.stdin.read()
    for line in iter_messages(content):
        parse_line(m, line)
    score = compute_score(m)
    print(score) if a.quiet else None
    if not a.quiet:
        print("=" * 60)
        print("  ОЦЕНКА VPN-СЕРВИСА GRANIVPN ПО ЛОГАМ")
        print("=" * 60)
        tot = m.connection_successes + m.connection_errors
        rate = (100 * m.connection_successes / tot) if tot else 0
        print("  Успехов:", m.connection_successes, "Ошибок:", m.connection_errors, "Success rate:", f"{rate:.1f}%")
        print("  Native crash:", m.native_crashes, "tcp_bind:", m.tcp_bind_failures)
        print("  no_space_left:", m.no_space_left_count, "ConnectionLogger timeout:", m.connection_logger_errors)
        print("  Tun2Socks bind timeout:", m.tun2socks_bind_timeouts)
        if m.network_changes or m.vpn_traffic_first_seen or m.reconnect_starts or m.disconnect_dones:
            print("  [Мониторинг] Смена сети:", m.network_changes, "| Трафик по туннелю:", m.vpn_traffic_first_seen,
                  "| Reconnect start:", m.reconnect_starts, "| Disconnect done:", m.disconnect_dones)
        if m.connection_timing_success_ms:
            avg = sum(m.connection_timing_success_ms) / len(m.connection_timing_success_ms)
            print("  Подключение (avg ms):", int(avg))
        if m.disconnect_durations_ms:
            avg = sum(m.disconnect_durations_ms) / len(m.disconnect_durations_ms)
            print("  Отключение API (avg ms):", int(avg))
        print("  ОЦЕНКА:", score, "/ 100")
        print("=" * 60)
    return 0

if __name__ == "__main__": sys.exit(main())
