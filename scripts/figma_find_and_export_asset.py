#!/usr/bin/env python3
"""
Поиск узла в Figma по имени и экспорт в PNG.
Используется для ассетов вроде pic1_welcome_babushka.png.

Использование:
  export FIGMA_ACCESS_TOKEN="figd_..."
  python3 scripts/figma_find_and_export_asset.py "pic1_welcome_babushka" [output_filename]

Требования: requests (pip install requests)
"""

import json
import os
import sys
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parent.parent
ASSETS_DIR = REPO_ROOT / "mobile-app" / "assets" / "images" / "figma"
DOCS_DIR = REPO_ROOT / "docs"
FIGMA_AUTH_PATH = DOCS_DIR / "figma_auth_data.json"

FILE_KEY = "TZYqJZyQtl31Zao6JC8GSl"


def get_token():
    token = os.environ.get("FIGMA_ACCESS_TOKEN")
    if token:
        return token
    if FIGMA_AUTH_PATH.exists():
        with open(FIGMA_AUTH_PATH, encoding="utf-8") as f:
            data = json.load(f)
        return data.get("figma_token")
    return None


def find_node_by_name_substring(node, substring, path="", depth=0, max_depth=12):
    """Рекурсивно ищет узел по подстроке в имени. Возвращает node_id или None."""
    if depth > max_depth:
        return None
    name = (node.get("name") or "").lower()
    node_id = node.get("id")
    if node_id and substring.lower() in name:
        return node_id
    for child in node.get("children") or []:
        found = find_node_by_name_substring(
            child, substring, f"{path}/{child.get('name', '')}", depth + 1, max_depth
        )
        if found:
            return found
    return None


def main():
    try:
        import requests
    except ImportError:
        print("Ошибка: нужен модуль requests. Выполните: pip install requests", file=sys.stderr)
        sys.exit(1)

    if len(sys.argv) < 2:
        print("Использование: python3 figma_find_and_export_asset.py <подстрока_имени> [output.png]", file=sys.stderr)
        sys.exit(1)

    search_name = sys.argv[1]
    output_name = sys.argv[2] if len(sys.argv) > 2 else f"{search_name}.png"
    if not output_name.endswith(".png"):
        output_name += ".png"
    asset_path = ASSETS_DIR / output_name

    token = get_token()
    if not token:
        print("Ошибка: не задан FIGMA_ACCESS_TOKEN и не найден docs/figma_auth_data.json", file=sys.stderr)
        sys.exit(1)

    # 1. Получить файл (дерево документа)
    url = f"https://api.figma.com/v1/files/{FILE_KEY}"
    resp = requests.get(url, headers={"X-Figma-Token": token}, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma API: {resp.status_code}. {resp.text[:500]}", file=sys.stderr)
        sys.exit(1)

    doc = resp.json().get("document") or {}
    node_id = find_node_by_name_substring(doc, search_name)
    if not node_id:
        print(f"Узел с именем содержащим '{search_name}' не найден в файле.", file=sys.stderr)
        sys.exit(1)

    # 2. Экспорт изображения
    url = f"https://api.figma.com/v1/images/{FILE_KEY}?ids={quote(node_id)}&format=png&scale=2"
    resp = requests.get(url, headers={"X-Figma-Token": token}, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma Images API: {resp.status_code}. {resp.text[:500]}", file=sys.stderr)
        sys.exit(1)

    images = resp.json().get("images") or {}
    image_url = images.get(node_id)
    if not image_url:
        print("Ошибка: URL изображения не возвращён.", file=sys.stderr)
        sys.exit(1)

    img_resp = requests.get(image_url, timeout=30)
    if img_resp.status_code != 200:
        print(f"Ошибка загрузки изображения: {img_resp.status_code}", file=sys.stderr)
        sys.exit(1)

    ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    asset_path.write_bytes(img_resp.content)
    print(f"Ассет сохранён: {asset_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
