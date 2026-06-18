#!/usr/bin/env python3
"""
Получение данных макета auth_email_input_error (516:223, экран ввода кода) из Figma REST API.
Пишет docs/figma_auth_code_design.json: градиент фона, размеры, цвета, типографика.
  python3 scripts/figma_fetch_auth_code_design.py
"""

import json
import os
import sys
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parent.parent
DOCS_DIR = REPO_ROOT / "docs"
FIGMA_AUTH_PATH = DOCS_DIR / "figma_auth_data.json"
OUTPUT_PATH = DOCS_DIR / "figma_auth_code_design.json"

FILE_KEY = "TZYqJZyQtl31Zao6JC8GSl"
AUTH_CODE_NODE_ID = "516:223"


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
    """Собирает узлы по имени; при дубликатах имён добавляет в список."""
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


def extract_design(doc):
    design = {
        "source": "Figma API",
        "frame_id": AUTH_CODE_NODE_ID,
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
        for bg_name in ("pic1", "положка"):
            nodes = by_name.get(bg_name, [])
            if nodes:
                bg = nodes[0]["node"]
                fills = (bg.get("fills") or [])
                design["background"] = {"bounds": bg.get("absoluteBoundingBox") or {}}
                if fills:
                    design["background"]["color_hex"] = fill_to_hex(fills[0])
                break

    # Блок заголовка: "text" (FRAME) с "Введите код" и "Мы отправили код вам на email"
    text_frames = by_name.get("text", [])
    if text_frames:
        text_frame = text_frames[0]["node"]
        box = text_frame.get("absoluteBoundingBox") or {}
        design["title_block"] = {"x": box.get("x"), "y": box.get("y"), "width": box.get("width"), "height": box.get("height")}
        for ch in text_frame.get("children") or []:
            name = (ch.get("name") or "").strip()
            style = ch.get("style") or {}
            ch_box = ch.get("absoluteBoundingBox") or {}
            if "Введите код" in name:
                design["title"] = {
                    "fontSize": style.get("fontSize"),
                    "fontWeight": style.get("fontWeight"),
                    "letterSpacing": style.get("letterSpacing"),
                    "lineHeightPx": style.get("lineHeightPx"),
                    "fontFamily": style.get("fontFamily"),
                    "fills": [fill_to_hex(f) for f in (ch.get("fills") or []) if fill_to_hex(f)],
                    "bounds": ch_box,
                }
            elif "отправили" in name or "email" in name.lower():
                design["subtitle"] = {
                    "fontSize": style.get("fontSize"),
                    "fontWeight": style.get("fontWeight"),
                    "letterSpacing": style.get("letterSpacing"),
                    "lineHeightPx": style.get("lineHeightPx"),
                    "fontFamily": style.get("fontFamily"),
                    "fills": [fill_to_hex(f) for f in (ch.get("fills") or []) if fill_to_hex(f)],
                    "bounds": ch_box,
                }

    # PIN-код (подпись)
    pin_labels = by_name.get("PIN-код", [])
    if pin_labels and pin_labels[0]["node"].get("type") == "TEXT":
        n = pin_labels[0]["node"]
        style = n.get("style") or {}
        design["pin_label"] = {
            "fontSize": style.get("fontSize"),
            "fontWeight": style.get("fontWeight"),
            "fills": [fill_to_hex(f) for f in (n.get("fills") or []) if fill_to_hex(f)],
        }

    # Ошибка: "❌ Неверный код, попробуйте ещё раз"
    for key in ("❌ Неверный код, попробуйте ещё раз", "Неверный код"):
        err_list = by_name.get(key, [])
        if err_list:
            n = err_list[0]["node"]
            if n.get("type") == "TEXT":
                style = n.get("style") or {}
                design["error_message"] = {
                    "fontSize": style.get("fontSize"),
                    "fontWeight": style.get("fontWeight"),
                    "fills": [fill_to_hex(f) for f in (n.get("fills") or []) if fill_to_hex(f)],
                }
                break

    # Ссылка "Отправить код повторно (28)"
    resend_list = by_name.get("Отправить код повторно (28)", [])
    if not resend_list:
        for k, v in by_name.items():
            if "Отправить код повторно" in k and v:
                resend_list = v
                break
    if resend_list and resend_list[0]["node"].get("type") == "TEXT":
        n = resend_list[0]["node"]
        style = n.get("style") or {}
        design["resend_link"] = {
            "fontSize": style.get("fontSize"),
            "fontWeight": style.get("fontWeight"),
            "fills": [fill_to_hex(f) for f in (n.get("fills") or []) if fill_to_hex(f)],
        }

    # Поле ввода PIN (первое из "поле ввода")
    pole_list = by_name.get("поле ввода", [])
    if pole_list:
        first_pole = pole_list[0]["node"]
        box = first_pole.get("absoluteBoundingBox") or {}
        fills = (first_pole.get("fills") or [])
        design["pin_box"] = {
            "node_id": first_pole.get("id"),
            "x": box.get("x"), "y": box.get("y"),
            "width": box.get("width"), "height": box.get("height"),
            "cornerRadius": first_pole.get("cornerRadius"),
            "background_hex": fill_to_hex(fills[0]) if fills else None,
        }

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

    url = f"https://api.figma.com/v1/files/{FILE_KEY}/nodes?ids={quote(AUTH_CODE_NODE_ID)}&depth=10"
    resp = requests.get(url, headers={"X-Figma-Token": token}, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma API: {resp.status_code}. {resp.text[:500]}", file=sys.stderr)
        sys.exit(1)

    data = resp.json()
    nodes = data.get("nodes") or {}
    wrap = nodes.get(AUTH_CODE_NODE_ID)
    if not wrap:
        print("Ошибка: узел 516:223 не найден", file=sys.stderr)
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
