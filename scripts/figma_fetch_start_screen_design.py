#!/usr/bin/env python3
"""
Получение данных макета start_screen (516:295) из Figma REST API.
Пишет в docs/figma_start_screen_design.json только данные из макета (цвета, размеры, отступы, типографика).
Использование: FIGMA_ACCESS_TOKEN=... или figma_token в docs/figma_auth_data.json
  python3 scripts/figma_fetch_start_screen_design.py
"""

import json
import os
import sys
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parent.parent
DOCS_DIR = REPO_ROOT / "docs"
FIGMA_AUTH_PATH = DOCS_DIR / "figma_auth_data.json"
OUTPUT_PATH = DOCS_DIR / "figma_start_screen_design.json"

FILE_KEY = "TZYqJZyQtl31Zao6JC8GSl"
START_SCREEN_NODE_ID = "516:295"


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
    """Figma color { r, g, b } (0-1) + optional opacity -> #RRGGBB."""
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
    """Figma fill: { type: 'SOLID', color: { r, g, b }, opacity? } -> #RRGGBB."""
    if not fill or fill.get("type") != "SOLID":
        return None
    c = fill.get("color") or {}
    return color_to_hex(c, fill.get("opacity", 1.0))


def gradient_to_design(fill):
    """Figma fill type GRADIENT_LINEAR / gradient-linear -> { colors: [#hex], stops: [0..1] }."""
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


def collect_by_name(node, name_to_id, by_id=None, path=""):
    name = (node.get("name") or "").strip()
    nid = node.get("id")
    if nid and name:
        name_to_id[name] = {"id": nid, "path": path, "node": node}
    if by_id is not None and nid:
        by_id[nid] = node
    for i, child in enumerate(node.get("children") or []):
        collect_by_name(child, name_to_id, by_id, f"{path}/{child.get('name', i)}")


def extract_design(doc):
    design = {
        "source": "Figma API",
        "frame_id": START_SCREEN_NODE_ID,
        "design_width": 412,
        "design_height": 917,
    }
    by_name = {}
    by_id = {}
    collect_by_name(doc, by_name, by_id)

    frame_box = doc.get("absoluteBoundingBox") or {}
    design["frame"] = {
        "x": frame_box.get("x", 0),
        "y": frame_box.get("y", 0),
        "width": frame_box.get("width", 412),
        "height": frame_box.get("height", 917),
    }

    # Фон: градиент на корневом фрейме #StartScreen (Fill в панели Design)
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
        bg = (by_name.get("backgroundBox") or {}).get("node") or by_id.get("516:297")
        if bg:
            design["background"] = {}
            fills = (bg.get("fills") or [])
            if fills:
                design["background"]["color_hex"] = fill_to_hex(fills[0])
            design["background"]["bounds"] = bg.get("absoluteBoundingBox") or {}

    # Логотип: по имени слоя в макете (сначала "logo", затем старые варианты)
    logo = (
        (by_name.get("logo") or {}).get("node")
        or (by_name.get("logoGrani") or {}).get("node")
        or by_id.get("516:306")
    )
    if logo:
        box = logo.get("absoluteBoundingBox") or {}
        design["logo"] = {
            "node_id": logo.get("id"),
            "x": box.get("x"),
            "y": box.get("y"),
            "width": box.get("width"),
            "height": box.get("height"),
        }

    # textBlock
    text_block = by_name.get("textBlock", {}).get("node")
    if text_block:
        box = text_block.get("absoluteBoundingBox") or {}
        design["textBlock"] = {"x": box.get("x"), "y": box.get("y"), "width": box.get("width"), "height": box.get("height")}
        for ch in text_block.get("children") or []:
            name = (ch.get("name") or "").strip()
            style = ch.get("style") or {}
            ch_box = ch.get("absoluteBoundingBox") or {}
            if name == "title":
                design["title"] = {
                    "fontSize": style.get("fontSize"),
                    "fontWeight": style.get("fontWeight"),
                    "letterSpacing": style.get("letterSpacing"),
                    "lineHeightPx": style.get("lineHeightPx"),
                    "fontFamily": style.get("fontFamily"),
                    "fills": [fill_to_hex(f) for f in (ch.get("fills") or []) if fill_to_hex(f)],
                    "bounds": ch_box,
                }
            elif name == "subtitle":
                design["subtitle"] = {
                    "fontSize": style.get("fontSize"),
                    "fontWeight": style.get("fontWeight"),
                    "letterSpacing": style.get("letterSpacing"),
                    "lineHeightPx": style.get("lineHeightPx"),
                    "fontFamily": style.get("fontFamily"),
                    "fills": [fill_to_hex(f) for f in (ch.get("fills") or []) if fill_to_hex(f)],
                    "bounds": ch_box,
                }

    # Кнопка Google: "поле ввода" (516:308) или ищем по первому FRAME с иконкой
    for label in ("поле ввода", "button_google"):
        btn = by_name.get(label, {}).get("node")
        if btn and btn.get("type") == "FRAME":
            box = btn.get("absoluteBoundingBox") or {}
            fills = (btn.get("fills") or [])
            design["button_google"] = {
                "node_id": btn.get("id"),
                "x": box.get("x"), "y": box.get("y"),
                "width": box.get("width"), "height": box.get("height"),
                "cornerRadius": btn.get("cornerRadius"),
                "background_hex": fill_to_hex(fills[0]) if fills else None,
            }
            for c in btn.get("children") or []:
                if (c.get("name") or "").strip() == "iconGoogle":
                    design["button_google"]["icon_node_id"] = c.get("id")
                elif c.get("type") == "TEXT":
                    design["button_google"]["text_style"] = {
                        "fontSize": (c.get("style") or {}).get("fontSize"),
                        "fontWeight": (c.get("style") or {}).get("fontWeight"),
                    }
            break

    # button_email (517:571)
    btn_email = by_name.get("button_email", {}).get("node")
    if btn_email:
        box = btn_email.get("absoluteBoundingBox") or {}
        fills = (btn_email.get("fills") or [])
        design["button_email"] = {
            "node_id": btn_email.get("id"),
            "x": box.get("x"), "y": box.get("y"),
            "width": box.get("width"), "height": box.get("height"),
            "cornerRadius": btn_email.get("cornerRadius"),
            "background_hex": fill_to_hex(fills[0]) if fills else None,
        }
        for c in btn_email.get("children") or []:
            if (c.get("name") or "").strip() == "Email":
                design["button_email"]["icon_node_id"] = c.get("id")
            elif c.get("type") == "TEXT":
                design["button_email"]["text_style"] = {
                    "fontSize": (c.get("style") or {}).get("fontSize"),
                    "fontWeight": (c.get("style") or {}).get("fontWeight"),
                }

    # Войти (frame 516:300), privacyText (516:298) — текст и стили
    enter_frame = by_name.get("Войти", {}).get("node")
    if enter_frame:
        for c in enter_frame.get("children") or []:
            if c.get("type") == "TEXT":
                style = c.get("style") or {}
                design["link_sign_in"] = {
                    "fontSize": style.get("fontSize"),
                    "fontWeight": style.get("fontWeight"),
                    "fills": [fill_to_hex(f) for f in (c.get("fills") or []) if fill_to_hex(f)],
                }
                break
    privacy = by_name.get("privacyText", {}).get("node")
    if privacy:
        for c in privacy.get("children") or []:
            if c.get("type") == "TEXT":
                style = c.get("style") or {}
                design["privacy_link"] = {
                    "fontSize": style.get("fontSize"),
                    "fontWeight": style.get("fontWeight"),
                    "fills": [fill_to_hex(f) for f in (c.get("fills") or []) if fill_to_hex(f)],
                }
                break

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

    url = f"https://api.figma.com/v1/files/{FILE_KEY}/nodes?ids={quote(START_SCREEN_NODE_ID)}&depth=10"
    resp = requests.get(url, headers={"X-Figma-Token": token}, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma API: {resp.status_code}. {resp.text[:500]}", file=sys.stderr)
        sys.exit(1)

    data = resp.json()
    nodes = data.get("nodes") or {}
    wrap = nodes.get(START_SCREEN_NODE_ID)
    if not wrap:
        print("Ошибка: узел start_screen не найден в ответе", file=sys.stderr)
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
