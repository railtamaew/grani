#!/usr/bin/env python3
"""
Экспорт иконок плитки быстрого доступа (Quick Settings Tile) из Figma.

На панели быстрых настроек фон и подпись задаёт система; приложению нужна только
иконка (круг с «G»). Скрипт экспортирует кадр плитки и обрезает его до области
иконки (Ellipse 1 в макете).

- node 1050-373: состояние «отключено» → ic_tile.png
- node 1050-374: состояние «включено» → ic_tile_active.png

Использование:
  FIGMA_TOKEN=xxx python3 scripts/export_quick_tile_from_figma.py
  python3 scripts/export_quick_tile_from_figma.py --token YOUR_TOKEN
"""
import io
import os
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ANDROID_RES = SCRIPT_DIR.parent / "android" / "app" / "src" / "main" / "res" / "drawable"
FILE_KEY = "TZYqJZyQtl31Zao6JC8GSl"
SCALE = 2
NODES = [
    ("1050:373", "ic_tile.png"),        # отключено
    ("1050:374", "ic_tile_active.png"), # включено
]


def get_icon_crop_rect(token: str, node_id: str):
    """Возвращает (x, y, w, h) области иконки относительно кадра, в координатах Figma."""
    import requests
    r = requests.get(
        f"https://api.figma.com/v1/files/{FILE_KEY}/nodes",
        headers={"X-Figma-Token": token},
        params={"ids": node_id, "depth": 4},
        timeout=30,
    )
    r.raise_for_status()
    doc = r.json()["nodes"][node_id]["document"]
    frame = doc.get("absoluteBoundingBox") or {}
    fx, fy = frame.get("x", 0), frame.get("y", 0)
    for c in doc.get("children", []):
        if c.get("type") == "ELLIPSE" or (c.get("name") or "").startswith("Ellipse"):
            b = c.get("absoluteBoundingBox") or {}
            return (
                b.get("x", 0) - fx,
                b.get("y", 0) - fy,
                b.get("width", 0),
                b.get("height", 0),
            )
    return None


def export_one(token: str, node_id: str, out_path: Path, scale: int = SCALE, crop_icon_only: bool = True) -> bool:
    import requests
    from PIL import Image

    url = f"https://api.figma.com/v1/images/{FILE_KEY}"
    r = requests.get(
        url,
        headers={"X-Figma-Token": token},
        params={"ids": node_id, "format": "png", "scale": scale},
        timeout=30,
    )
    r.raise_for_status()
    data = r.json()
    if "images" not in data or node_id not in data["images"]:
        print(f"Узел {node_id} не найден в ответе API")
        return False
    img_r = requests.get(data["images"][node_id], timeout=30)
    img_r.raise_for_status()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    if crop_icon_only:
        rect = get_icon_crop_rect(token, node_id)
        if rect:
            x, y, w, h = rect
            img = Image.open(io.BytesIO(img_r.content)).convert("RGBA")
            # координаты в пикселях (масштаб экспорта)
            left = int(x * scale)
            top = int(y * scale)
            width = int(w * scale)
            height = int(h * scale)
            # не выходить за границы
            left = max(0, min(left, img.width - 1))
            top = max(0, min(top, img.height - 1))
            width = min(width, img.width - left)
            height = min(height, img.height - top)
            if width > 0 and height > 0:
                img = img.crop((left, top, left + width, top + height))
            out_path.write_bytes(_png_bytes(img))
            print(f"Сохранено (только иконка): {out_path}")
        else:
            out_path.write_bytes(img_r.content)
            print(f"Сохранено (кадр целиком, область иконки не найдена): {out_path}")
    else:
        out_path.write_bytes(img_r.content)
        print(f"Сохранено: {out_path}")
    return True


def _png_bytes(pil_image) -> bytes:
    buf = io.BytesIO()
    pil_image.save(buf, format="PNG")
    return buf.getvalue()


def main():
    token = os.getenv("FIGMA_TOKEN")
    if not token and len(sys.argv) >= 3 and sys.argv[1] == "--token":
        token = sys.argv[2]
    if not token:
        print("Задайте FIGMA_TOKEN или: python3 scripts/export_quick_tile_from_figma.py --token YOUR_TOKEN")
        sys.exit(1)
    for node_id, filename in NODES:
        out = ANDROID_RES / filename
        if not export_one(token, node_id, out, crop_icon_only=True):
            sys.exit(1)
    print("Готово. В drawable лежат только иконки (круг с G); фон и подпись задаёт система.")


if __name__ == "__main__":
    main()
