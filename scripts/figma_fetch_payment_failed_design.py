#!/usr/bin/env python3
"""
Получение данных макета bottom sheet «Оплата не прошла» (958:444) из Figma.
Пишет docs/figma_payment_failed_design.json: типографика заголовка и описания.
  python3 scripts/figma_fetch_payment_failed_design.py
"""

import json
import os
import sys
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parent.parent
DOCS_DIR = REPO_ROOT / "docs"
FIGMA_AUTH_PATH = DOCS_DIR / "figma_auth_data.json"
OUTPUT_PATH = DOCS_DIR / "figma_payment_failed_design.json"

FILE_KEY = "TZYqJZyQtl31Zao6JC8GSl"
NODE_ID = "958:444"


def get_token():
    token = os.environ.get("FIGMA_ACCESS_TOKEN")
    if token:
        return token
    if FIGMA_AUTH_PATH.exists():
        with open(FIGMA_AUTH_PATH, encoding="utf-8") as f:
            data = json.load(f)
        return data.get("figma_token") or None
    return None


def fill_to_hex(fill):
    if not fill or fill.get("type") != "SOLID":
        return None
    c = fill.get("color") or {}
    r = round((c.get("r") or 0) * 255)
    g = round((c.get("g") or 0) * 255)
    b = round((c.get("b") or 0) * 255)
    a = c.get("a", 1.0)
    if a < 1.0:
        return f"#{r:02X}{g:02X}{b:02X}{round(a * 255):02X}"
    return f"#{r:02X}{g:02X}{b:02X}"


def collect_text_styles(node, out_list, path=""):
    if node.get("type") == "TEXT":
        style = node.get("style") or {}
        out_list.append({
            "name": node.get("name"),
            "path": path,
            "characters": (node.get("characters") or "")[:80],
            "fontSize": style.get("fontSize"),
            "fontWeight": style.get("fontWeight"),
            "letterSpacing": style.get("letterSpacing"),
            "lineHeightPx": style.get("lineHeightPx"),
            "fontFamily": style.get("fontFamily"),
            "fills": [fill_to_hex(f) for f in (node.get("fills") or []) if fill_to_hex(f)],
        })
    for i, child in enumerate(node.get("children") or []):
        collect_text_styles(child, out_list, f"{path}/{child.get('name', i)}")


def main():
    try:
        import requests
    except ImportError:
        print("Ошибка: pip install requests", file=sys.stderr)
        sys.exit(1)

    token = get_token()
    if not token:
        print("Ошибка: FIGMA_ACCESS_TOKEN или figma_token в docs/figma_auth_data.json", file=sys.stderr)
        sys.exit(1)

    url = f"https://api.figma.com/v1/files/{FILE_KEY}/nodes?ids={quote(NODE_ID)}&depth=10"
    resp = requests.get(url, headers={"X-Figma-Token": token}, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma API: {resp.status_code}. {resp.text[:300]}", file=sys.stderr)
        sys.exit(1)

    nodes = resp.json().get("nodes") or {}
    doc = (nodes.get(NODE_ID) or {}).get("document")
    if not doc:
        print("Ошибка: документ узла 958:444 не найден", file=sys.stderr)
        sys.exit(1)

    texts = []
    collect_text_styles(doc, texts)

    design = {
        "source": "Figma API",
        "node_id": NODE_ID,
        "design_width": 412,
        "design_height": 917,
        "texts": texts,
    }

    # Выделить заголовок и описание по содержимому
    for t in texts:
        chars = (t.get("characters") or "").strip()
        if "Оплата не прошла" in chars or "не прошла" in chars:
            design["title"] = t
        elif "Мы не смогли" in chars or "списать" in chars:
            design["description"] = t

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump(design, f, indent=2, ensure_ascii=False)
    print(f"Данные записаны: {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
