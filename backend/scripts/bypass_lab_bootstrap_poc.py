#!/usr/bin/env python3
"""
PoC сценария 6 (Bootstrap): получение конфига через DoH и/или HTTPS к прикрывающему домену.
Лабораторный скрипт для проверки: доступность DoH, загрузка и парсинг bootstrap JSON.
Не требует мобильного приложения.

Использование:
  # Проверка DoH (резолв домена через Cloudflare DoH)
  python3 bypass_lab_bootstrap_poc.py --doh api.granilink.com

  # Загрузка bootstrap с указанного URL (наш API или прикрывающий)
  python3 bypass_lab_bootstrap_poc.py --url https://api.granilink.com/api/vpn/bootstrap

  # DoH + загрузка с первого полученного URL
  python3 bypass_lab_bootstrap_poc.py --doh api.granilink.com --bootstrap-path /api/vpn/bootstrap
"""
import argparse
import json
import sys

try:
    import urllib.request
    import ssl
except ImportError:
    urllib.request = ssl = None


# DoH endpoint (Cloudflare)
DOH_URL = "https://cloudflare-dns.com/dns-query"


def doh_resolve(name: str, qtype: str = "A", timeout: int = 10) -> list:
    """Резолв имени через DoH (Cloudflare). Возвращает список записей (для A — IP)."""
    if not urllib.request:
        return []
    url = f"{DOH_URL}?name={name}&type={qtype}"
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/dns-json")
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            data = json.loads(r.read().decode())
    except Exception as e:
        print(f"DoH request failed: {e}", file=sys.stderr)
        return []
    answers = data.get("Answer") or []
    if qtype == "A":
        return [a["data"] for a in answers if a.get("type") == 1]
    return [a.get("data") for a in answers if a.get("data")]


def fetch_bootstrap(url: str, timeout: int = 10, insecure: bool = False) -> dict:
    """GET bootstrap JSON с URL. Возвращает dict с api_base_urls и ttl_seconds."""
    if not urllib.request:
        return {}
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/json")
    ctx = ssl.create_default_context()
    if insecure:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        print(f"Bootstrap GET failed: {e}", file=sys.stderr)
        return {}


def main():
    parser = argparse.ArgumentParser(
        description="Lab PoC Bootstrap (scenario 6): DoH and/or HTTPS bootstrap config"
    )
    parser.add_argument("--doh", metavar="NAME", help="Resolve hostname via DoH (Cloudflare)")
    parser.add_argument(
        "--url",
        metavar="URL",
        help="Fetch bootstrap JSON from URL (e.g. https://api.example.com/api/vpn/bootstrap)",
    )
    parser.add_argument(
        "--bootstrap-path",
        default="/api/vpn/bootstrap",
        help="Path for bootstrap when using --doh to build URL (default: /api/vpn/bootstrap)",
    )
    parser.add_argument("--insecure", action="store_true", help="Do not verify TLS")
    parser.add_argument("--timeout", type=int, default=10, help="Request timeout seconds")
    args = parser.parse_args()

    if not args.doh and not args.url:
        parser.print_help()
        print("\nProvide --doh and/or --url.", file=sys.stderr)
        return 1

    ok = True

    if args.doh:
        print(f"DoH resolve: {args.doh}")
        ips = doh_resolve(args.doh, timeout=args.timeout)
        if ips:
            print(f"  IPs: {ips}")
            if args.bootstrap_path and not args.url:
                # Построить URL по первому IP (для проверки доступности; Host header нужен для TLS)
                base = f"https://{args.doh}"
                path = args.bootstrap_path if args.bootstrap_path.startswith("/") else "/" + args.bootstrap_path
                args.url = base.rstrip("/") + path
                print(f"  Bootstrap URL: {args.url}")
        else:
            print("  No A records (DoH failed or NXDOMAIN)")
            ok = False

    if args.url:
        print(f"Fetch bootstrap: {args.url}")
        data = fetch_bootstrap(args.url, timeout=args.timeout, insecure=args.insecure)
        if data:
            urls = data.get("api_base_urls") or []
            ttl = data.get("ttl_seconds", 0)
            print(f"  api_base_urls: {urls}")
            print(f"  ttl_seconds: {ttl}")
            print("  Config parsed OK.")
        else:
            print("  Failed to fetch or parse bootstrap.")
            ok = False

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
