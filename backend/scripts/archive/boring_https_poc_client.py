#!/usr/bin/env python3
"""
Минимальный PoC для сценария 4 (Boring HTTPS): одно HTTPS-соединение к «прикрывающему» домену,
в теле POST — заглушка. Используется для записи трафика и проверки SNI/JA3 (фаза 1.3.1).
Запуск: python3 boring_https_poc_client.py [--url https://example.com] [--repeat N]
"""
import argparse
import ssl
import sys
import urllib.request

def main():
    parser = argparse.ArgumentParser(description="PoC Boring HTTPS: один POST к прикрывающему домену")
    parser.add_argument("--url", default="https://www.google.com/generate_204", help="URL для POST (прикрывающий домен)")
    parser.add_argument("--repeat", type=int, default=1, help="Количество запросов")
    args = parser.parse_args()
    url = args.url
    data = b'{"stub":1}'  # заглушка в теле
    req = urllib.request.Request(url, data=data, method="POST", headers={"Content-Type": "application/json"})
    ctx = ssl.create_default_context()
    for i in range(args.repeat):
        try:
            with urllib.request.urlopen(req, timeout=10, context=ctx) as r:
                pass  # игнорируем ответ
        except Exception as e:
            print(f"Request {i+1}: {e}", file=sys.stderr)
    print("PoC done.")

if __name__ == "__main__":
    main()
