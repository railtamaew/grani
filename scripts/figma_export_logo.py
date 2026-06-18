#!/usr/bin/env python3
"""
Экспорт актуального логотипа из макета Figma в mobile-app/assets/images/figma/logo_grani_new.png.
Используется для замены старого логотипа на трёх экранах (Start, AuthEmail, AuthCode).

Использование:
  export FIGMA_ACCESS_TOKEN="figd_..."
  python3 scripts/figma_export_logo.py

Требования: requests (pip install requests)
"""

import json
import os
import sys
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parent.parent
ASSET_PATH = REPO_ROOT / "mobile-app" / "assets" / "images" / "figma" / "logo_grani_new.png"
DOCS_DIR = REPO_ROOT / "docs"
FIGMA_AUTH_PATH = DOCS_DIR / "figma_auth_data.json"

FILE_KEY = "TZYqJZyQtl31Zao6JC8GSl"
FRAME_NODE_ID = "516:295"  # StartScreen — логотип тот же на всех трёх экранах
LOGO_NAMES = ("logoGrani", "logo_grani_new 1", "logo_grani_new", "Logo", "logo")


def get_token():
    token = os.environ.get("FIGMA_ACCESS_TOKEN")
    if token:
        return token
    if FIGMA_AUTH_PATH.exists():
        with open(FIGMA_AUTH_PATH, encoding="utf-8") as f:
            data = json.load(f)
        return data.get("figma_token")
    return None


def name_matches(name, allowed_names):
    if not name:
        return False
    name_lower = name.lower()
    for n in allowed_names:
        if name == n or (n.lower() in name_lower) or (name_lower in n.lower()):
            return True
    return False


def find_logo_node_id(node):
    """Рекурсивно ищет узел логотипа по имени, возвращает node id или None."""
    name = node.get("name") or ""
    node_id = node.get("id")
    if node_id and name_matches(name, LOGO_NAMES):
        return node_id
    for child in node.get("children") or []:
        found = find_logo_node_id(child)
        if found:
            return found
    return None


def main():
    try:
        import requests
    except ImportError:
        print("Ошибка: нужен модуль requests. Выполните: pip install requests", file=sys.stderr)
        sys.exit(1)

    token = get_token()
    if not token:
        print("Ошибка: не задан FIGMA_ACCESS_TOKEN и не найден docs/figma_auth_data.json с figma_token", file=sys.stderr)
        sys.exit(1)

    # 1. Получить дерево узлов и найти id логотипа
    url = f"https://api.figma.com/v1/files/{FILE_KEY}/nodes?ids={quote(FRAME_NODE_ID)}&depth=8"
    resp = requests.get(url, headers={"X-Figma-Token": token}, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma API: {resp.status_code}. {resp.text}", file=sys.stderr)
        sys.exit(1)

    data = resp.json()
    nodes = data.get("nodes") or {}
    doc = (nodes.get(FRAME_NODE_ID) or {}).get("document")
    if not doc:
        print("Ошибка: не найден документ узла", FRAME_NODE_ID, file=sys.stderr)
        sys.exit(1)

    logo_node_id = find_logo_node_id(doc)
    if not logo_node_id:
        print("Ошибка: узел логотипа не найден в макете. Проверьте имена слоёв (LOGO_NAMES).", file=sys.stderr)
        sys.exit(1)

    # 2. Запросить URL экспорта изображения
    url = f"https://api.figma.com/v1/images/{FILE_KEY}?ids={quote(logo_node_id)}&format=png&scale=2"
    resp = requests.get(url, headers={"X-Figma-Token": token}, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma Images API: {resp.status_code}. {resp.text}", file=sys.stderr)
        sys.exit(1)

    images = resp.json().get("images") or {}
    image_url = images.get(logo_node_id)
    if not image_url:
        print("Ошибка: URL изображения не возвращён.", file=sys.stderr)
        sys.exit(1)

    # 3. Скачать и сохранить
    img_resp = requests.get(image_url, timeout=30)
    if img_resp.status_code != 200:
        print(f"Ошибка загрузки изображения: {img_resp.status_code}", file=sys.stderr)
        sys.exit(1)

    ASSET_PATH.parent.mkdir(parents=True, exist_ok=True)
    ASSET_PATH.write_bytes(img_resp.content)
    print(f"Логотип сохранён: {ASSET_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
