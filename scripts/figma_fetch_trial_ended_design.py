#!/usr/bin/env python3
"""
Получение данных макета TrialEndedScreen / paywall (562:488) из Figma REST API.
Пишет docs/figma_trial_ended_design.json: фон, размеры, цвета, типографика, карточки тарифов.
  python3 scripts/figma_fetch_trial_ended_design.py
"""

import json
import os
import sys
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parent.parent
DOCS_DIR = REPO_ROOT / "docs"
FIGMA_AUTH_PATH = DOCS_DIR / "figma_auth_data.json"
OUTPUT_PATH = DOCS_DIR / "figma_trial_ended_design.json"

FILE_KEY = "TZYqJZyQtl31Zao6JC8GSl"
TRIAL_ENDED_NODE_ID = "562:488"


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


def text_style_from_node(node):
    if node.get("type") != "TEXT":
        return None
    style = node.get("style") or {}
    return {
        "fontSize": style.get("fontSize"),
        "fontWeight": style.get("fontWeight"),
        "letterSpacing": style.get("letterSpacing"),
        "lineHeightPx": style.get("lineHeightPx"),
        "fontFamily": style.get("fontFamily"),
        "fills": [fill_to_hex(f) for f in (node.get("fills") or []) if fill_to_hex(f)],
        "text": node.get("characters", ""),
    }


def extract_design(doc):
    design = {
        "source": "Figma API",
        "frame_id": TRIAL_ENDED_NODE_ID,
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

    # Фон: корневой фрейм
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
        bg = None
        for key in ("background_box", "backgroundBox", "подложка", "card"):
            if by_name.get(key):
                bg = by_name[key][0]["node"]
                break
        if bg:
            design["background"] = {"bounds": bg.get("absoluteBoundingBox") or {}}
            fills = bg.get("fills") or []
            if fills:
                design["background"]["color_hex"] = fill_to_hex(fills[0])

    # Заголовок — по имени слоя или по содержимому TEXT
    for name, items in by_name.items():
        if not items:
            continue
        n = items[0]["node"]
        if "Для продолжения" in (name or "") or "выберите тариф" in (name or "").lower():
            s = text_style_from_node(n)
            if s:
                design["title"] = s
                break
        if n.get("type") == "TEXT" and ("продолжения" in (n.get("characters") or "") or "тариф" in (n.get("characters") or "").lower()):
            design["title"] = text_style_from_node(n)
            break
    if "title" not in design:
        for items in [by_name.get("Content", []), by_name.get("Текст", [])]:
            for item in (items or []):
                node = item.get("node", {})
                for ch in node.get("children") or []:
                    if ch.get("type") == "TEXT" and "продолжения" in (ch.get("characters") or ""):
                        design["title"] = text_style_from_node(ch)
                        break
                if "title" in design:
                    break
            if "title" in design:
                break

    # Подзаголовок
    for name, items in by_name.items():
        if not items:
            continue
        n = items[0]["node"]
        if "Оформи подписку" in (name or ""):
            s = text_style_from_node(n)
            if s:
                design["subtitle"] = s
                break
            for ch in n.get("children") or []:
                s = text_style_from_node(ch)
                if s:
                    design["subtitle"] = s
                    break
        if n.get("type") == "TEXT" and "Оформи подписку" in (n.get("characters") or ""):
            design["subtitle"] = text_style_from_node(n)
            break
        if "subtitle" in design:
            break

    # Таймер "осталось"
    for name, items in by_name.items():
        if items and "осталось" in (name or "").lower():
            n = items[0]["node"]
            s = text_style_from_node(n)
            if s:
                design["timer"] = s
            break

    # Подложка с карточками (контейнер)
    for key in ("подложка", "card", "tariff_card_container", "content"):
        nodes = by_name.get(key, [])
        if not nodes:
            continue
        n = nodes[0]["node"]
        box = n.get("absoluteBoundingBox") or {}
        design["card_container"] = {
            "x": box.get("x"), "y": box.get("y"),
            "width": box.get("width"), "height": box.get("height"),
            "cornerRadius": n.get("cornerRadius"),
        }
        fills = n.get("fills") or []
        if fills:
            design["card_container"]["background_hex"] = fill_to_hex(fills[0])
        break

    # Карточка тарифа (бейдж число/период, цена, описание)
    for name, items in by_name.items():
        if not items:
            continue
        n = items[0]["node"]
        name_lower = (name or "").lower()
        if "тариф" not in name_lower and "tariff" not in name_lower and "карточка" not in name_lower:
            continue
        if n.get("type") not in ("FRAME", "COMPONENT", "GROUP", "INSTANCE"):
            continue
        box = n.get("absoluteBoundingBox") or {}
        design["tariff_card"] = {
            "width": box.get("width"), "height": box.get("height"),
            "cornerRadius": n.get("cornerRadius"),
        }
        for ch in n.get("children") or []:
            if ch.get("type") == "TEXT":
                s = text_style_from_node(ch)
                if s:
                    txt = (s.get("text") or "").strip()
                    if txt.isdigit() or "месяц" in txt or "месяцев" in txt:
                        design["tariff_card"]["badge_style"] = s
                    elif "$" in txt or "₽" in txt or "в месяц" in txt:
                        design["tariff_card"]["price_style"] = s
                    else:
                        design["tariff_card"]["description_style"] = s
        if "tariff_card" in design:
            break

    # Дополнительно: ищем по содержимому текст "осталось", бейдж, цену
    if "timer" not in design:
        for name, items in by_name.items():
            for item in items:
                n = item["node"]
                if n.get("type") == "TEXT" and "00:00" in (n.get("characters") or ""):
                    design["timer"] = text_style_from_node(n)
                    break
            if "timer" in design:
                break

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

    url = f"https://api.figma.com/v1/files/{FILE_KEY}/nodes?ids={quote(TRIAL_ENDED_NODE_ID)}&depth=10"
    resp = requests.get(url, headers={"X-Figma-Token": token}, timeout=15)
    if resp.status_code != 200:
        print(f"Ошибка Figma API: {resp.status_code}. {resp.text[:500]}", file=sys.stderr)
        sys.exit(1)

    data = resp.json()
    nodes = data.get("nodes") or {}
    wrap = nodes.get(TRIAL_ENDED_NODE_ID)
    if not wrap:
        print("Ошибка: узел 562:488 не найден", file=sys.stderr)
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
