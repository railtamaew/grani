#!/usr/bin/env python3
"""
Получение данных макета HomeScreen (958:337) из Figma REST API.
Структура аналогична TrialUnifiedScreen: градиент, заголовок, подзаголовок, кнопка, сервер/протокол.
  python3 scripts/figma_fetch_home_screen_design.py
"""

import json
import os
import sys
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parent.parent
DOCS_DIR = REPO_ROOT / "docs"
FIGMA_AUTH_PATH = DOCS_DIR / "figma_auth_data.json"
OUTPUT_PATH = DOCS_DIR / "figma_home_screen_design.json"

FILE_KEY = "TZYqJZyQtl31Zao6JC8GSl"
HOME_NODE_ID = "958:337"


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


def collect_by_name(node, name_to_list, path=""):
    name = (node.get("name") or "").strip()
    nid = node.get("id")
    if nid and name:
        if name not in name_to_list:
            name_to_list[name] = []
        name_to_list[name].append({"id": nid, "path": path, "node": node})
    for i, child in enumerate(node.get("children") or []):
        collect_by_name(child, name_to_list, f"{path}/{child.get('name', i)}")


def extract_design(doc):
    design = {
        "source": "Figma API",
        "frame_id": HOME_NODE_ID,
        "design_width": 412,
        "design_height": 917,
    }
    by_name = {}
    collect_by_name(doc, by_name)

    frame_box = doc.get("absoluteBoundingBox") or {}
    design["frame"] = {
        "x": frame_box.get("x"), "y": frame_box.get("y"),
        "width": frame_box.get("width"), "height": frame_box.get("height"),
    }

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
        bg = by_name.get("background_box", [{}])[0].get("node") if by_name.get("background_box") else None
        if bg:
            fills = (bg.get("fills") or [])
            design["background"] = {"bounds": bg.get("absoluteBoundingBox") or {}}
            if fills:
                design["background"]["color_hex"] = fill_to_hex(fills[0])

    for key in ("Подписка активна", "title", "textBlock", "title_block", "content"):
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
                if "characters" in n:
                    design["title"]["text"] = n.get("characters", "")
                break
            for ch in n.get("children") or []:
                if ch.get("type") == "TEXT" and ("Подписка" in (ch.get("name") or "") or "активна" in (ch.get("name") or "")):
                    style = ch.get("style") or {}
                    design["title"] = {
                        "fontSize": style.get("fontSize"),
                        "fontWeight": style.get("fontWeight"),
                        "letterSpacing": style.get("letterSpacing"),
                        "lineHeightPx": style.get("lineHeightPx"),
                        "fontFamily": style.get("fontFamily"),
                        "fills": [fill_to_hex(f) for f in (ch.get("fills") or []) if fill_to_hex(f)],
                        "bounds": ch.get("absoluteBoundingBox") or {},
                        "text": ch.get("characters", ""),
                    }
                    break
            if "title" in design:
                break
        if "title" in design:
            break

    for key in ("Сервис активен", "subtitle", "description"):
        nodes = by_name.get(key, [])
        for item in nodes:
            n = item["node"]
            if n.get("type") == "TEXT":
                style = n.get("style") or {}
                design["subtitle"] = {
                    "fontSize": style.get("fontSize"),
                    "fontWeight": style.get("fontWeight"),
                    "fills": [fill_to_hex(f) for f in (n.get("fills") or []) if fill_to_hex(f)],
                    "text": n.get("characters", ""),
                }
                break
        if "subtitle" in design:
            break

    # 4 состояния: OFF, ON, CONNECTING, DISCONNECTING — только слои "title" и "subtitle" внутри content
    state_names = ("OFF", "ON", "CONNECTING", "DISCONNECTING")
    design["states"] = {}

    def find_state_frames(node, acc):
        name = (node.get("name") or "").strip()
        if name in state_names:
            acc.append((name, node))
        for ch in node.get("children") or []:
            find_state_frames(ch, acc)

    def find_node_by_name(node, target_name):
        if (node.get("name") or "").strip() == target_name and node.get("type") == "TEXT":
            return node.get("characters", "")
        for ch in node.get("children") or []:
            out = find_node_by_name(ch, target_name)
            if out is not None:
                return out
        return None

    state_frames = []
    find_state_frames(doc, state_frames)
    for sname, frame in state_frames:
        content = None
        for c in frame.get("children") or []:
            if (c.get("name") or "").strip().lower() in ("content", "textblock", "title_block"):
                content = c
                break
        node_to_scan = content if content else frame
        title_text = (find_node_by_name(node_to_scan, "title") or "").replace("\r", "").strip()
        subtitle_text = (find_node_by_name(node_to_scan, "subtitle") or "").replace("\r", "").strip()
        design["states"][sname] = {"title": title_text, "subtitle": subtitle_text}

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

    url = f"https://api.figma.com/v1/files/{FILE_KEY}/nodes?ids={quote(HOME_NODE_ID)}&depth=10"
    resp = requests.get(url, headers={"X-Figma-Token": token}, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma API: {resp.status_code}. {resp.text[:500]}", file=sys.stderr)
        sys.exit(1)

    data = resp.json()
    nodes = data.get("nodes") or {}
    wrap = nodes.get(HOME_NODE_ID)
    if not wrap:
        print("Ошибка: узел 958:337 не найден", file=sys.stderr)
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
