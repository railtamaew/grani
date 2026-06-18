#!/usr/bin/env python3
"""
Экспорт ассетов стартового экрана из Figma (frame 516:295): логотип, иконки Google и Email.
SVG и картинки сохраняются в mobile-app/assets/images/figma/.
Токен: FIGMA_ACCESS_TOKEN или docs/figma_auth_data.json (figma_token).
  python3 scripts/figma_export_start_screen_assets.py
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
START_SCREEN_NODE_ID = "516:295"

# Имена слоёв в макете Figma (как в панели Layers). Сначала актуальное имя "logo".
EXPORTS = [
    ("logo", "logo_grani_new.png"),        # слой logo в #StartScreen — новый лого
    ("logoGrani", "logo_grani_new.png"),   # fallback старых макетов
    ("iconGoogle", "google_logo.png"),
    ("Email", "email_icon.png"),
]
# Для логотипа: один выходной файл, ищем первый найденный из списка имён
LOGO_NAMES_ORDER = ["logo", "logoGrani", "logo_grani_new 1"]


def get_token():
    token = os.environ.get("FIGMA_ACCESS_TOKEN")
    if token:
        return token
    if FIGMA_AUTH_PATH.exists():
        with open(FIGMA_AUTH_PATH, encoding="utf-8") as f:
            data = json.load(f)
        return data.get("figma_token") or None
    return None


def find_node_id_by_name(node, name, depth=0, max_depth=12):
    if depth > max_depth:
        return None
    nname = (node.get("name") or "").strip()
    if nname == name and node.get("id"):
        return node.get("id")
    for child in node.get("children") or []:
        found = find_node_id_by_name(child, name, depth + 1, max_depth)
        if found:
            return found
    return None


def find_node_by_id(node, nid, depth=0, max_depth=12):
    if depth > max_depth:
        return None
    if node.get("id") == nid:
        return nid
    for child in node.get("children") or []:
        found = find_node_by_id(child, nid, depth + 1, max_depth)
        if found:
            return found
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

    # 1. Получить дерево start_screen и найти node_id для каждого ассета
    url = f"https://api.figma.com/v1/files/{FILE_KEY}/nodes?ids={quote(START_SCREEN_NODE_ID)}&depth=10"
    resp = requests.get(url, headers={"X-Figma-Token": token}, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma API: {resp.status_code}. {resp.text[:300]}", file=sys.stderr)
        sys.exit(1)
    doc = (resp.json().get("nodes") or {}).get(START_SCREEN_NODE_ID, {}).get("document")
    if not doc:
        print("Ошибка: не найден document start_screen", file=sys.stderr)
        sys.exit(1)

    node_ids = {}
    for logo_name in LOGO_NAMES_ORDER:
        nid = find_node_id_by_name(doc, logo_name)
        if nid:
            node_ids["logo_grani_new.png"] = nid
            print(f"Логотип: найден слой '{logo_name}', id={nid}")
            break
    if "logo_grani_new.png" not in node_ids:
        print("Предупреждение: слой логотипа (logo / logoGrani) не найден в макете", file=sys.stderr)
    for figma_name, out_name in EXPORTS:
        if out_name == "logo_grani_new.png":
            continue
        nid = find_node_id_by_name(doc, figma_name)
        if nid:
            node_ids[out_name] = nid
        else:
            print(f"Предупреждение: узел '{figma_name}' не найден, пропуск {out_name}", file=sys.stderr)
    if not node_ids:
        print("Нет узлов для экспорта", file=sys.stderr)
        sys.exit(1)

    # 2. Экспорт: PNG для растров (Figma Images API)
    ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    ids_param = ",".join(quote(nid) for nid in node_ids.values())
    url = f"https://api.figma.com/v1/images/{FILE_KEY}?ids={ids_param}&format=png&scale=2"
    resp = requests.get(url, headers={"X-Figma-Token": token}, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma Images API: {resp.status_code}. {resp.text[:300]}", file=sys.stderr)
        sys.exit(1)
    images = resp.json().get("images") or {}
    id_to_name = {nid: name for name, nid in zip(node_ids.keys(), node_ids.values())}
    for nid, img_url in images.items():
        if not img_url:
            print(f"Предупреждение: нет URL для узла {nid}", file=sys.stderr)
            continue
        out_name = id_to_name.get(nid)
        if not out_name:
            continue
        path = ASSETS_DIR / out_name
        img_resp = requests.get(img_url, timeout=30)
        if img_resp.status_code != 200:
            print(f"Ошибка загрузки {out_name}: {img_resp.status_code}", file=sys.stderr)
            continue
        path.write_bytes(img_resp.content)
        print(f"Сохранено: {path}")

    print("Экспорт ассетов стартового экрана завершён.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
