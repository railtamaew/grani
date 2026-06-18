#!/usr/bin/env python3
"""
Скачивание иконки приложения из Figma (фирменная G) и сохранение для flutter_launcher_icons.
Макет: https://www.figma.com/design/TZYqJZyQtl31Zao6JC8GSl/GRANI?node-id=1050-374

Использование:
  python3 scripts/figma_export_app_icon.py

Требования: requests. Токен: FIGMA_ACCESS_TOKEN или docs/figma_auth_data.json (figma_token).
После экспорта запустите в mobile-app: flutter pub run flutter_launcher_icons
"""

import json
import os
import sys
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parent.parent
DOCS_DIR = REPO_ROOT / "docs"
FIGMA_AUTH_PATH = DOCS_DIR / "figma_auth_data.json"
OUTPUT_PATH = REPO_ROOT / "mobile-app" / "assets" / "icons" / "icon_01.png"

FILE_KEY = "TZYqJZyQtl31Zao6JC8GSl"
APP_ICON_NODE_ID = "1033:124"


def get_token():
    token = os.environ.get("FIGMA_ACCESS_TOKEN")
    if token:
        return token
    if FIGMA_AUTH_PATH.exists():
        with open(FIGMA_AUTH_PATH, encoding="utf-8") as f:
            data = json.load(f)
        return data.get("figma_token") or None
    return None


def main():
    try:
        import requests
    except ImportError:
        print("Ошибка: pip install requests", file=sys.stderr)
        sys.exit(1)

    token = get_token()
    if not token:
        print("Ошибка: задайте FIGMA_ACCESS_TOKEN или figma_token в docs/figma_auth_data.json", file=sys.stderr)
        sys.exit(1)

    # Figma Images API: ids с дефисом (1033-124), scale=2 для 1024px если фрейм 512
    api_id = APP_ICON_NODE_ID.replace(":", "-")
    url = f"https://api.figma.com/v1/images/{FILE_KEY}"
    params = {"ids": api_id, "format": "png", "scale": "2"}
    resp = requests.get(url, headers={"X-Figma-Token": token}, params=params, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma Images API: {resp.status_code}. {resp.text[:400]}", file=sys.stderr)
        sys.exit(1)

    data = resp.json()
    images = data.get("images") or {}
    image_url = next((v for v in images.values() if v), None)
    if not image_url:
        print("Ошибка: URL изображения не возвращён. Проверьте node-id 1050:374 в макете.", file=sys.stderr)
        sys.exit(1)

    img_resp = requests.get(image_url, timeout=30)
    if img_resp.status_code != 200:
        print(f"Ошибка загрузки изображения: {img_resp.status_code}", file=sys.stderr)
        sys.exit(1)

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_bytes(img_resp.content)
    print(f"Иконка сохранена: {OUTPUT_PATH}")
    print("Дальше в mobile-app выполните: flutter pub run flutter_launcher_icons")
    return 0


if __name__ == "__main__":
    sys.exit(main())
