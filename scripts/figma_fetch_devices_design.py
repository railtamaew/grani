#!/usr/bin/env python3
"""
Получение данных макета экрана «Мои устройства» (1143:193) из Figma REST API.
Размеры карточек, отступы, цвета, типографика. Пишет docs/figma_devices_design.json.

Использование:
  export FIGMA_ACCESS_TOKEN="figd_..."   # или docs/figma_auth_data.json
  python3 scripts/figma_fetch_devices_design.py
"""

import json
import os
import sys
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parent.parent
DOCS_DIR = REPO_ROOT / "docs"
FIGMA_AUTH_PATH = DOCS_DIR / "figma_auth_data.json"
OUTPUT_PATH = DOCS_DIR / "figma_devices_design.json"

FILE_KEY = "TZYqJZyQtl31Zao6JC8GSl"
NODE_ID = "1143:193"


def get_token():
    token = os.environ.get("FIGMA_ACCESS_TOKEN")
    if token:
        return token
    if FIGMA_AUTH_PATH.exists():
        with open(FIGMA_AUTH_PATH, encoding="utf-8") as f:
            data = json.load(f)
        return data.get("figma_token") or None
    return None


def color_to_hex(c, opacity=1.0):
    if not c:
        return None
    r = round((c.get("r") or 0) * 255)
    g = round((c.get("g") or 0) * 255)
    b = round((c.get("b") or 0) * 255)
    a = c.get("a", opacity)
    if a < 1.0:
        return f"#{r:02X}{g:02X}{b:02X}{round(a * 255):02X}"
    return f"#{r:02X}{g:02X}{b:02X}"


def fill_to_hex(fill):
    if not fill or fill.get("type") != "SOLID":
        return None
    c = fill.get("color") or {}
    return color_to_hex(c, fill.get("opacity", 1.0))


def extract_node_data(node):
    """Извлекает absoluteBoundingBox, cornerRadius, fills, stroke, стили текста."""
    box = node.get("absoluteBoundingBox") or {}
    res = {
        "name": node.get("name"),
        "width": box.get("width"),
        "height": box.get("height"),
        "x": box.get("x"),
        "y": box.get("y"),
    }
    if node.get("cornerRadius") is not None:
        res["cornerRadius"] = node.get("cornerRadius")
    fills = node.get("fills") or []
    if fills:
        solid = next((f for f in fills if f.get("type") == "SOLID"), None)
        if solid:
            res["fill_hex"] = fill_to_hex(solid)
        if len(fills) > 1 or (fills and fills[0].get("type") != "SOLID"):
            res["fills_raw"] = [f.get("type") for f in fills]
    strokes = node.get("strokes") or []
    if strokes:
        res["stroke_hex"] = fill_to_hex(strokes[0])
    if node.get("type") == "TEXT":
        style = node.get("style") or {}
        res["characters"] = node.get("characters", "")
        res["fontSize"] = style.get("fontSize")
        res["fontWeight"] = style.get("fontWeight")
        res["fontFamily"] = style.get("fontFamily")
        if node.get("fills"):
            res["text_fill_hex"] = fill_to_hex(node["fills"][0])
    return res


def walk_nodes(node, out_list, depth=0, max_depth=6):
    """Рекурсивно собирает узлы с bounds."""
    if depth > max_depth:
        return
    name = node.get("name") or ""
    box = node.get("absoluteBoundingBox")
    if box:
        data = extract_node_data(node)
        data["depth"] = depth
        out_list.append(data)
    for child in node.get("children") or []:
        walk_nodes(child, out_list, depth + 1, max_depth)


def fetch_node(token):
    try:
        import requests
    except ImportError:
        print("Ошибка: нужен requests. Выполните: pip install requests", file=sys.stderr)
        sys.exit(1)
    ids_param = quote(NODE_ID)
    url = f"https://api.figma.com/v1/files/{FILE_KEY}/nodes?ids={ids_param}&depth=10"
    headers = {"X-Figma-Token": token}
    resp = requests.get(url, headers=headers, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma API: {resp.status_code}. {resp.text[:200]}", file=sys.stderr)
        sys.exit(1)
    return resp.json()


def main():
    token = get_token()
    if not token:
        print(
            "Ошибка: задайте FIGMA_ACCESS_TOKEN или добавьте figma_token в docs/figma_auth_data.json",
            file=sys.stderr,
        )
        sys.exit(1)

    data = fetch_node(token)
    nodes = data.get("nodes") or {}
    node_wrap = nodes.get(NODE_ID) or nodes.get(NODE_ID.replace(":", "-"))
    if not node_wrap:
        for k, v in nodes.items():
            if k.replace("-", ":") == NODE_ID or NODE_ID.replace(":", "-") == k:
                node_wrap = v
                break
    if not node_wrap:
        print(f"Узел {NODE_ID} не найден в ответе.", file=sys.stderr)
        sys.exit(1)

    doc = node_wrap.get("document")
    if not doc:
        print("Документ узла пуст.", file=sys.stderr)
        sys.exit(1)

    design = {
        "screen": NODE_ID,
        "screen_name": doc.get("name"),
        "frame": extract_node_data(doc),
        "children": [],
    }

    # Собираем дочерние узлы с bounds
    all_nodes = []
    walk_nodes(doc, all_nodes)

    # Группируем по типам для удобства
    cards = [n for n in all_nodes if "button_email" in (n.get("name") or "").lower()]
    text_nodes = [n for n in all_nodes if n.get("characters")]
    design["children_count"] = len(all_nodes)
    design["device_cards_sample"] = cards[:2] if cards else []
    design["text_nodes_sample"] = text_nodes[:15]
    design["all_nodes_with_bounds"] = [
        {"name": n.get("name"), "w": n.get("width"), "h": n.get("height"), "x": n.get("x"), "y": n.get("y")}
        for n in all_nodes[:40]
    ]

    # Вычисляем gap между заголовком и блоком "Подключено"
    title_nodes = [n for n in all_nodes if "Мои устройства" in (n.get("characters") or "")]
    connected_nodes = [n for n in all_nodes if "Подключено" in (n.get("characters") or "")]
    if title_nodes and connected_nodes:
        t = title_nodes[0]
        c = connected_nodes[0]
        design["title_to_connected_gap"] = round((c.get("y") or 0) - ((t.get("y") or 0) + (t.get("height") or 0)))

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump(design, f, indent=2, ensure_ascii=False)

    print(f"Сохранено: {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
