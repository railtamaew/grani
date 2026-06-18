#!/usr/bin/env python3
"""
Лабораторный тестовый клиент для туннеля Boring HTTPS (сценарий 4).
Подключается к PoC gateway (POST /tunnel), отправляет health check и опционально туннельные фреймы.
Используется для проверки «трафик идёт» в лаборатории без мобильного приложения.

Формат туннеля: 4 байта (big-endian длина) + payload. Health check: пустое тело или 1 байт.
Запуск:
  python bypass_lab_tunnel_client.py --url http://127.0.0.1:8799/api/vpn/tunnel
  python bypass_lab_tunnel_client.py --url https://gate.example.com/api/vpn/tunnel --frame "test"
"""
import argparse
import struct
import sys

try:
    import urllib.request
    import ssl
except ImportError:
    urllib.request = None
    ssl = None


def main():
    parser = argparse.ArgumentParser(
        description="Lab tunnel client: POST to Boring HTTPS gateway (health + optional frame)"
    )
    parser.add_argument(
        "--url",
        default="http://127.0.0.1:8799/api/vpn/tunnel",
        help="Gateway URL (POST /tunnel)",
    )
    parser.add_argument(
        "--frame",
        default=None,
        help="Optional payload to send as one tunnel frame (string or hex, e.g. deadbeef)",
    )
    parser.add_argument(
        "--repeat",
        type=int,
        default=1,
        help="Repeat requests (for traffic capture)",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Do not verify TLS (for lab only)",
    )
    args = parser.parse_args()

    if not urllib.request:
        print("urllib.request not available", file=sys.stderr)
        return 1

    url = args.url.rstrip("/")
    if not url.endswith("/tunnel"):
        url = url + "/tunnel" if not url.endswith("/") else url + "tunnel"

    ctx = ssl.create_default_context()
    if args.insecure:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

    for i in range(args.repeat):
        # 1) Health check: POST с пустым телом или 1 байт
        req = urllib.request.Request(url, data=b"", method="POST")
        req.add_header("Content-Type", "application/octet-stream")
        try:
            with urllib.request.urlopen(req, timeout=10, context=ctx) as r:
                print(f"Health check {i+1}: {r.status}")
        except Exception as e:
            print(f"Health check {i+1} failed: {e}", file=sys.stderr)
            return 1

        # 2) Опционально один туннельный фрейм
        if args.frame is not None:
            raw = args.frame
            if raw.startswith("0x") or all(c in "0123456789abcdefABCDEF" for c in raw.replace("0x", "")):
                try:
                    payload = bytes.fromhex(raw.replace("0x", ""))
                except ValueError:
                    payload = raw.encode("utf-8")
            else:
                payload = raw.encode("utf-8")
            body = struct.pack(">I", len(payload)) + payload
            req2 = urllib.request.Request(url, data=body, method="POST")
            req2.add_header("Content-Type", "application/octet-stream")
            try:
                with urllib.request.urlopen(req2, timeout=10, context=ctx) as r:
                    resp_body = r.read()
                    print(f"Tunnel frame {i+1}: status={r.status}, response_len={len(resp_body)}")
                    if len(resp_body) >= 4:
                        rlen = struct.unpack(">I", resp_body[:4])[0]
                        print(f"  Response frame length: {rlen}")
            except Exception as e:
                print(f"Tunnel frame {i+1} failed: {e}", file=sys.stderr)
                return 1

    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
