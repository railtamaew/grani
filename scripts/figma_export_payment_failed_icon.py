#!/usr/bin/env python3
"""
Экспорт только иконки (щит с «!») из bottom sheet «Оплата не прошла» (Figma 958:444)
в mobile-app/assets/images/figma/payment_failed_icon.png.

Использование:
  export FIGMA_ACCESS_TOKEN="figd_..."
  python3 scripts/figma_export_payment_failed_icon.py

Требования: requests (pip install requests)
"""

import json
import os
import sys
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parent.parent
ASSET_PATH = REPO_ROOT / "mobile-app" / "assets" / "images" / "figma" / "payment_failed_icon.png"
DOCS_DIR = REPO_ROOT / "docs"
FIGMA_AUTH_PATH = DOCS_DIR / "figma_auth_data.json"

FILE_KEY = "TZYqJZyQtl31Zao6JC8GSl"
# Bottom sheet «Оплата не прошла» (Figma 958:444)
FRAME_NODE_ID = "958:444"
ICON_NAMES = ("icon", "Icon", "shield", "Shield", "payment_failed_icon", "error_icon", "error")


def get_token():
    token = os.environ.get("FIGMA_ACCESS_TOKEN")
    if token:
        return token
    if FIGMA_AUTH_PATH.exists():
        with open(FIGMA_AUTH_PATH, encoding="utf-8") as f:
            data = json.load(f)
        return data.get("figma_token")
    return None


def find_icon_node_id(node, depth=0, max_depth=8):
    if depth > max_depth:
        return None
    name = (node.get("name") or "").strip()
    node_id = node.get("id")
    if node_id:
        name_lower = name.lower()
        for candidate in ICON_NAMES:
            if candidate.lower() == name_lower or candidate.lower() in name_lower:
                return node_id
    for child in node.get("children") or []:
        found = find_icon_node_id(child, depth + 1, max_depth)
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

    # 1. Получить дерево bottom sheet и найти узел иконки
    url = f"https://api.figma.com/v1/files/{FILE_KEY}/nodes?ids={quote(FRAME_NODE_ID)}&depth=8"
    resp = requests.get(url, headers={"X-Figma-Token": token}, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma API: {resp.status_code}. {resp.text}", file=sys.stderr)
        sys.exit(1)

    nodes = resp.json().get("nodes") or {}
    doc = (nodes.get(FRAME_NODE_ID) or {}).get("document")
    if not doc:
        print("Ошибка: не найден документ узла", FRAME_NODE_ID, file=sys.stderr)
        sys.exit(1)

    icon_node_id = find_icon_node_id(doc)
    if not icon_node_id:
        children = doc.get("children") or []
        for c in children:
            cid = c.get("id")
            if cid and c.get("type") in ("FRAME", "COMPONENT", "GROUP", "VECTOR", "BOOLEAN_OPERATION"):
                icon_node_id = cid
                break
        if not icon_node_id and children:
            icon_node_id = children[0].get("id")
    if not icon_node_id:
        print("Ошибка: не найден узел иконки в макете 958:444.", file=sys.stderr)
        sys.exit(1)

    # 2. Экспорт изображения только иконки
    url = f"https://api.figma.com/v1/images/{FILE_KEY}?ids={quote(icon_node_id)}&format=png&scale=2"
    resp = requests.get(url, headers={"X-Figma-Token": token}, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma Images API: {resp.status_code}. {resp.text}", file=sys.stderr)
        sys.exit(1)

    images = resp.json().get("images") or {}
    image_url = images.get(icon_node_id)
    if not image_url:
        print("Ошибка: URL изображения не возвращён.", file=sys.stderr)
        sys.exit(1)

    img_resp = requests.get(image_url, timeout=30)
    if img_resp.status_code != 200:
        print(f"Ошибка загрузки изображения: {img_resp.status_code}", file=sys.stderr)
        sys.exit(1)

    ASSET_PATH.parent.mkdir(parents=True, exist_ok=True)
    ASSET_PATH.write_bytes(img_resp.content)
    print(f"Ассет сохранён: {ASSET_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
