#!/usr/bin/env python3
"""
PoC сценария 1 (Traffic Mimicry): туннельный запрос с TLS-отпечатком, имитирующим браузер.
Для сравнения с эталоном: записать pcap этого скрипта и эталонного браузера, сравнить JA3
и размеры пакетов через bypass_lab_capture_traffic.py --analyze.

Если установлен curl_cffi — используется impersonate (Chrome); иначе — обычный requests
(отпечаток будет типичным для Python). Установка: pip install curl_cffi
"""
import argparse
import struct
import sys

try:
    from curl_cffi import requests as curl_requests
    HAS_CURL_CFFI = True
except ImportError:
    HAS_CURL_CFFI = False

try:
    import requests
except ImportError:
    requests = None


def main():
    parser = argparse.ArgumentParser(description="Lab PoC Traffic Mimicry: tunnel request with browser-like TLS")
    parser.add_argument("--url", default="http://127.0.0.1:8799/api/vpn/tunnel", help="Gateway tunnel URL")
    parser.add_argument("--impersonate", default="chrome", help="curl_cffi impersonate (chrome, safari, etc.)")
    parser.add_argument("--frame", default="mimic", help="Payload string for one tunnel frame")
    args = parser.parse_args()

    url = args.url.rstrip("/")
    if not url.endswith("/tunnel"):
        url = url + "/tunnel" if not url.endswith("/") else url + "tunnel"

    payload = args.frame.encode("utf-8")
    body = struct.pack(">I", len(payload)) + payload

    try:
        if HAS_CURL_CFFI:
            r = curl_requests.post(url, content=body, impersonate=args.impersonate, timeout=10)
            print(f"curl_cffi ({args.impersonate}): status={r.status_code}, len={len(r.content)}")
        elif requests:
            r = requests.post(url, data=body, timeout=10)
            print(f"requests (default TLS): status={r.status_code}, len={len(r.content)}")
            print("(Install curl_cffi for JA3 mimicry: pip install curl_cffi)", file=sys.stderr)
        else:
            print("Install requests or curl_cffi", file=sys.stderr)
            return 1
    except Exception as e:
        print(f"Request failed: {e}", file=sys.stderr)
        return 1

    if r.status_code != 200:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
