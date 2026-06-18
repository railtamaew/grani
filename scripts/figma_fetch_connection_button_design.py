#!/usr/bin/env python3
"""
Получение данных макета кнопки подключения VPN (939:555) из Figma REST API.
Четыре состояния: OFF, ON, CONNECTING, DISCONNECTING.
Пишет docs/figma_connection_button_design.json: размеры, толщина дуги, разрыв дуги, цвета.
  python3 scripts/figma_fetch_connection_button_design.py
"""

import json
import os
import sys
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parent.parent
DOCS_DIR = REPO_ROOT / "docs"
FIGMA_AUTH_PATH = DOCS_DIR / "figma_auth_data.json"
OUTPUT_PATH = DOCS_DIR / "figma_connection_button_design.json"

FILE_KEY = "TZYqJZyQtl31Zao6JC8GSl"
NODE_ID = "939:555"


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


def collect_by_name(node, name_to_list, path=""):
    name = (node.get("name") or "").strip()
    nid = node.get("id")
    if nid and name:
        if name not in name_to_list:
            name_to_list[name] = []
        name_to_list[name].append({"id": nid, "path": path, "node": node})
    for i, child in enumerate(node.get("children") or []):
        collect_by_name(child, name_to_list, f"{path}/{child.get('name', i)}")


def extract_node_data(node, frame_origin=None):
    """Извлекает размеры, stroke, fills из узла (кольцо/дуга/круг/лейбл)."""
    box = node.get("absoluteBoundingBox") or {}
    w = box.get("width")
    h = box.get("height")
    x = box.get("x")
    y = box.get("y")
    res = {"width": w, "height": h, "x": x, "y": y}
    stroke_weight = node.get("strokeWeight")
    if stroke_weight is not None:
        res["strokeWeight"] = stroke_weight
    strokes = node.get("strokes") or []
    if strokes:
        res["stroke_hex"] = fill_to_hex(strokes[0])
    fills = node.get("fills") or []
    if fills and node.get("type") != "TEXT":
        res["fill_hex"] = fill_to_hex(fills[0])
    if node.get("type") == "TEXT":
        res["characters"] = node.get("characters", "")
        style = node.get("style") or {}
        res["fontSize"] = style.get("fontSize")
        res["fontWeight"] = style.get("fontWeight")
        res["fontFamily"] = style.get("fontFamily")
        res["letterSpacing"] = style.get("letterSpacing")
        res["lineHeightPx"] = style.get("lineHeightPx")
        res["text_fills"] = [fill_to_hex(f) for f in (node.get("fills") or []) if fill_to_hex(f)]
    return res


def extract_state(state_name, by_name, design):
    """Извлекает данные для одного состояния (OFF, ON, CONNECTING, DISCONNECTING)."""
    key = state_name.lower().replace(" ", "_")
    if key == "connected":
        key = "on"
    states_list = by_name.get(state_name, []) or by_name.get(key, [])
    if not states_list:
        return
    frame = states_list[0]["node"]
    box = frame.get("absoluteBoundingBox") or {}
    design[key] = {
        "frame": {"width": box.get("width"), "height": box.get("height"), "x": box.get("x"), "y": box.get("y")},
        "children": [],
        "connection_button": None,
    }
    for ch in frame.get("children") or []:
        ch_name = (ch.get("name") or "").strip()
        ch_data = extract_node_data(ch)
        ch_data["name"] = ch_name
        design[key]["children"].append(ch_data)
        if ch_name == "connection_button":
            btn_box = ch.get("absoluteBoundingBox") or {}
            design[key]["connection_button"] = {
                "width": btn_box.get("width"),
                "height": btn_box.get("height"),
                "x": btn_box.get("x"),
                "y": btn_box.get("y"),
            }
            for sub in ch.get("children") or []:
                sub_name = (sub.get("name") or "").strip()
                if sub_name == "ring":
                    design[key]["ring"] = extract_node_data(sub)
                    design[key]["ring"]["name"] = sub_name
                    design[key]["strokeWeight"] = sub.get("strokeWeight")
                    if (sub.get("strokes") or []):
                        design[key]["stroke_hex"] = fill_to_hex(sub.get("strokes")[0])
                elif sub_name == "label":
                    design[key]["label"] = {
                        "text": sub.get("characters", ""),
                        "fontSize": (sub.get("style") or {}).get("fontSize"),
                        "fontWeight": (sub.get("style") or {}).get("fontWeight"),
                        "fills": [fill_to_hex(f) for f in (sub.get("fills") or []) if fill_to_hex(f)],
                    }
                elif sub.get("type") in ("ELLIPSE", "RECTANGLE") and (sub.get("fills") or []):
                    if not sub.get("strokes") or len(sub.get("strokes") or []) == 0:
                        design[key]["inner_fill_hex"] = fill_to_hex((sub.get("fills") or [None])[0])
                        b = sub.get("absoluteBoundingBox") or {}
                        design[key]["inner_size"] = {"width": b.get("width"), "height": b.get("height")}
        if ch.get("type") == "TEXT" and "label" not in design[key]:
            design[key]["label"] = {
                "text": ch.get("characters", ""),
                "fontSize": (ch.get("style") or {}).get("fontSize"),
                "fontWeight": (ch.get("style") or {}).get("fontWeight"),
                "fills": [fill_to_hex(f) for f in (ch.get("fills") or []) if fill_to_hex(f)],
            }
    if "strokeWeight" not in design[key]:
        for ch in frame.get("children") or []:
            sw = ch.get("strokeWeight")
            if sw is not None:
                design[key]["strokeWeight"] = sw
                if (ch.get("strokes") or []):
                    design[key]["stroke_hex"] = fill_to_hex(ch.get("strokes")[0])
                break


def extract_design(doc):
    design = {
        "source": "Figma API",
        "node_id": NODE_ID,
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

    # Варианты: OFF, ON, CONNECTING, DISCONNECTING (или вложенные фреймы)
    for state in ("OFF", "ON", "CONNECTING", "DISCONNECTING"):
        extract_state(state, by_name, design)

    # Если узел — один фрейм с детьми ring/label, разбираем его как одно состояние
    children = doc.get("children") or []
    if not design.get("off") and len(children) > 0:
        first = children[0]
        box = doc.get("absoluteBoundingBox") or {}
        design["single"] = {
            "frame": {"width": box.get("width"), "height": box.get("height")},
            "children": [extract_node_data(c) for c in children],
        }
        for ch in children:
            if ch.get("type") == "TEXT":
                design["single"]["label"] = {
                    "text": ch.get("characters", ""),
                    "fontSize": (ch.get("style") or {}).get("fontSize"),
                    "fontWeight": (ch.get("style") or {}).get("fontWeight"),
                    "fills": [fill_to_hex(f) for f in (ch.get("fills") or []) if fill_to_hex(f)],
                }
            if ch.get("strokeWeight") is not None:
                design["single"]["strokeWeight"] = ch.get("strokeWeight")
                design["single"]["stroke_hex"] = fill_to_hex((ch.get("strokes") or [None])[0]) if (ch.get("strokes") or []) else None

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

    url = f"https://api.figma.com/v1/files/{FILE_KEY}/nodes?ids={quote(NODE_ID)}&depth=12"
    resp = requests.get(url, headers={"X-Figma-Token": token}, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma API: {resp.status_code}. {resp.text[:500]}", file=sys.stderr)
        sys.exit(1)

    data = resp.json()
    nodes = data.get("nodes") or {}
    wrap = nodes.get(NODE_ID)
    if not wrap:
        print("Ошибка: узел 939:555 не найден", file=sys.stderr)
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
