#!/usr/bin/env python3
"""
Получение данных макета trial_start (562:732, TrialUnifiedScreen) из Figma REST API.
Пишет docs/figma_trial_unified_design.json: градиент фона, размеры, цвета, типографика.
  python3 scripts/figma_fetch_trial_unified_design.py
"""

import json
import os
import sys
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parent.parent
DOCS_DIR = REPO_ROOT / "docs"
FIGMA_AUTH_PATH = DOCS_DIR / "figma_auth_data.json"
OUTPUT_PATH = DOCS_DIR / "figma_trial_unified_design.json"

FILE_KEY = "TZYqJZyQtl31Zao6JC8GSl"
TRIAL_NODE_ID = "562:732"


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


def gradient_to_design(fill):
    if not fill:
        return None
    t = (fill.get("type") or "").lower()
    if t not in ("gradient_linear", "gradient-linear"):
        return None
    stops = fill.get("gradientStops") or []
    if not stops:
        return None
    sorted_stops = sorted(stops, key=lambda s: s.get("position", 0))
    colors = []
    positions = []
    for s in sorted_stops:
        hex_c = color_to_hex(s.get("color") or {})
        if hex_c:
            colors.append(hex_c)
            positions.append(round(s.get("position", 0), 4))
    return {"colors_hex": colors, "stops": positions} if colors else None


def collect_by_name(node, name_to_list, by_id=None, path=""):
    name = (node.get("name") or "").strip()
    nid = node.get("id")
    if nid and name:
        if name not in name_to_list:
            name_to_list[name] = []
        name_to_list[name].append({"id": nid, "path": path, "node": node})
    if by_id is not None and nid:
        by_id[nid] = node
    for i, child in enumerate(node.get("children") or []):
        collect_by_name(child, name_to_list, by_id, f"{path}/{child.get('name', i)}")


def first_node(by_name, *keys):
    for k in keys:
        nodes = by_name.get(k, [])
        if nodes:
            return nodes[0]["node"]
    return None


def extract_design(doc):
    design = {
        "source": "Figma API",
        "frame_id": TRIAL_NODE_ID,
        "design_width": 412,
        "design_height": 917,
    }
    by_name = {}
    by_id = {}
    collect_by_name(doc, by_name, by_id)

    frame_box = doc.get("absoluteBoundingBox") or {}
    fx = frame_box.get("x", 0)
    fy = frame_box.get("y", 0)
    design["frame"] = {
        "x": fx, "y": fy,
        "width": frame_box.get("width", 412),
        "height": frame_box.get("height", 917),
    }

    # Фон: градиент на корневом фрейме
    root_fills = doc.get("fills") or []
    for f in root_fills:
        grad = gradient_to_design(f)
        if grad:
            design["background_gradient"] = grad
            break
        solid = fill_to_hex(f)
        if solid:
            design["background"] = {"color_hex": solid}
            break
    if "background_gradient" not in design and "background" not in design:
        bg = first_node(by_name, "background_box", "backgroundBox", "pic1", "положка")
        if bg:
            fills = (bg.get("fills") or [])
            design["background"] = {"bounds": bg.get("absoluteBoundingBox") or {}}
            if fills:
                design["background"]["color_hex"] = fill_to_hex(fills[0])

    # Заголовок "Тестовый период"
    for key in ("Тестовый период", "title", "textBlock", "title_block"):
        nodes = by_name.get(key, [])
        for item in nodes:
            n = item["node"]
            if n.get("type") == "TEXT":
                style = n.get("style") or {}
                design["title"] = {
                    "fontSize": style.get("fontSize"),
                    "fontWeight": style.get("fontWeight"),
                    "letterSpacing": style.get("letterSpacing"),
                    "lineHeightPx": style.get("lineHeightPx"),
                    "fontFamily": style.get("fontFamily"),
                    "fills": [fill_to_hex(f) for f in (n.get("fills") or []) if fill_to_hex(f)],
                    "bounds": n.get("absoluteBoundingBox") or {},
                }
                break
            # FRAME с TEXT-детьми
            for ch in n.get("children") or []:
                if ch.get("type") == "TEXT" and "Тестовый" in (ch.get("name") or ""):
                    style = ch.get("style") or {}
                    design["title"] = {
                        "fontSize": style.get("fontSize"),
                        "fontWeight": style.get("fontWeight"),
                        "letterSpacing": style.get("letterSpacing"),
                        "lineHeightPx": style.get("lineHeightPx"),
                        "fontFamily": style.get("fontFamily"),
                        "fills": [fill_to_hex(f) for f in (ch.get("fills") or []) if fill_to_hex(f)],
                        "bounds": ch.get("absoluteBoundingBox") or {},
                    }
                    break
            if "title" in design:
                break
        if "title" in design:
            break

    # Подзаголовок
    for key in ("Подтверждённая регистрация", "Можете протестировать", "subtitle", "description"):
        nodes = by_name.get(key, [])
        for item in nodes:
            n = item["node"]
            if n.get("type") == "TEXT":
                style = n.get("style") or {}
                design["subtitle"] = {
                    "fontSize": style.get("fontSize"),
                    "fontWeight": style.get("fontWeight"),
                    "fills": [fill_to_hex(f) for f in (n.get("fills") or []) if fill_to_hex(f)],
                }
                break
        if "subtitle" in design:
            break
    if "subtitle" not in design:
        for name, items in by_name.items():
            if items and "протестировать" in (name or "").lower():
                n = items[0]["node"]
                if n.get("type") == "TEXT":
                    style = n.get("style") or {}
                    design["subtitle"] = {
                        "fontSize": style.get("fontSize"),
                        "fontWeight": style.get("fontWeight"),
                        "fills": [fill_to_hex(f) for f in (n.get("fills") or []) if fill_to_hex(f)],
                    }
                break

    # Таймер "осталось"
    for name, items in by_name.items():
        if items and "осталось" in (name or "").lower():
            n = items[0]["node"]
            if n.get("type") == "TEXT":
                style = n.get("style") or {}
                design["timer"] = {
                    "fontSize": style.get("fontSize"),
                    "fontWeight": style.get("fontWeight"),
                    "fills": [fill_to_hex(f) for f in (n.get("fills") or []) if fill_to_hex(f)],
                    "bounds": n.get("absoluteBoundingBox") or {},
                }
            break

    # Кнопка подключения (подключить / подключено)
    for name, items in by_name.items():
        if not items:
            continue
        n = items[0]["node"]
        name_lower = (name or "").lower()
        if "подключить" in name_lower or "подключено" in name_lower or name_lower == "button_connection":
            if n.get("type") in ("FRAME", "COMPONENT", "INSTANCE"):
                box = n.get("absoluteBoundingBox") or {}
                design["connection_button"] = {
                    "width": box.get("width"),
                    "height": box.get("height"),
                    "bounds": box,
                }
                for ch in n.get("children") or []:
                    if ch.get("type") == "TEXT":
                        style = ch.get("style") or {}
                        design["connection_button"]["label_style"] = {
                            "fontSize": style.get("fontSize"),
                            "fontWeight": style.get("fontWeight"),
                            "fills": [fill_to_hex(f) for f in (ch.get("fills") or []) if fill_to_hex(f)],
                        }
                        design["connection_button"]["label_text"] = ch.get("characters", "")
                        break
                # stroke/ring color from first child with stroke
                for ch in n.get("children") or []:
                    strokes = ch.get("strokes") or []
                    if strokes:
                        design["connection_button"]["stroke_hex"] = fill_to_hex(strokes[0]) if strokes[0].get("type") == "SOLID" else None
                        break
            break

    # Положка / карточка (VpnCard)
    for key in ("положка", "VpnCard", "card", "подложка"):
        nodes = by_name.get(key, [])
        if nodes:
            n = nodes[0]["node"]
            box = n.get("absoluteBoundingBox") or {}
            design["card"] = {
                "x": box.get("x"), "y": box.get("y"),
                "width": box.get("width"), "height": box.get("height"),
                "cornerRadius": n.get("cornerRadius"),
            }
            fills = n.get("fills") or []
            if fills:
                design["card"]["background_hex"] = fill_to_hex(fills[0])
            break

    # Список имён слоёв для отладки
    design["_layer_names"] = sorted(by_name.keys())

    return design


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

    url = f"https://api.figma.com/v1/files/{FILE_KEY}/nodes?ids={quote(TRIAL_NODE_ID)}&depth=10"
    resp = requests.get(url, headers={"X-Figma-Token": token}, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma API: {resp.status_code}. {resp.text[:500]}", file=sys.stderr)
        sys.exit(1)

    data = resp.json()
    nodes = data.get("nodes") or {}
    wrap = nodes.get(TRIAL_NODE_ID)
    if not wrap:
        print("Ошибка: узел 562:732 не найден", file=sys.stderr)
        sys.exit(1)
    doc = wrap.get("document")
    if not doc:
        print("Ошибка: document пустой", file=sys.stderr)
        sys.exit(1)

    design = extract_design(doc)
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump(design, f, indent=2, ensure_ascii=False)
    print(f"Данные макета записаны: {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
