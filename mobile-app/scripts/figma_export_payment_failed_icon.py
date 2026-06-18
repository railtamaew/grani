#!/usr/bin/env python3
"""
Экспорт иконки «Оплата не прошла» из Figma (модалка 958:444 или дочерний узел с иконкой).

Использование:
    FIGMA_ACCESS_TOKEN=xxx python3 scripts/figma_export_payment_failed_icon.py
    или
    python3 scripts/figma_export_payment_failed_icon.py --token xxx

Экспортирует SVG (вектор) в assets/images/figma/payment_failed_icon.svg
и при необходимости PNG в payment_failed_icon.png.
"""

import argparse
import os
import sys
from pathlib import Path

try:
    import requests
except ImportError:
    print("Установите requests: pip install requests")
    sys.exit(1)

FILE_KEY = "TZYqJZyQtl31Zao6JC8GSl"
# Узел модалки «Оплата не прошла» (958:444). Иконка может быть внутри — экспортируем фрейм как SVG.
NODE_ID = "958-444"
ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets" / "images" / "figma"


def get_node_children(token: str):
    """Получить дочерние узлы 958:444, чтобы найти иконку."""
    url = f"https://api.figma.com/v1/files/{FILE_KEY}/nodes"
    params = {"ids": NODE_ID, "depth": 3}
    headers = {"X-Figma-Token": token}
    r = requests.get(url, headers=headers, params=params, timeout=30)
    r.raise_for_status()
    data = r.json()
    nodes = data.get("nodes", {})
    key = list(nodes.keys())[0] if nodes else None
    if key and "document" in nodes[key]:
        return nodes[key]["document"].get("children", [])
    return []


def export_image(token: str, node_id: str, fmt: str, scale: str = "1") -> str | None:
    """Экспорт узла в формате svg или png. Возвращает URL изображения."""
    url = f"https://api.figma.com/v1/images/{FILE_KEY}"
    params = {"ids": node_id, "format": fmt, "scale": scale}
    headers = {"X-Figma-Token": token}
    r = requests.get(url, headers=headers, params=params, timeout=30)
    r.raise_for_status()
    data = r.json()
    images = data.get("images", {})
    # API может вернуть ключ с ":" (958:444) или с "-" (958-444)
    return images.get(node_id) or images.get(node_id.replace("-", ":"))


def main():
    parser = argparse.ArgumentParser(description="Export payment failed icon from Figma")
    parser.add_argument("--token", help="Figma Personal Access Token")
    parser.add_argument("--format", choices=["svg", "png"], default="svg")
    parser.add_argument("--output-dir", default=str(ASSETS_DIR), help="Output directory")
    args = parser.parse_args()
    token = args.token or os.environ.get("FIGMA_ACCESS_TOKEN") or os.environ.get("FIGMA_TOKEN")
    if not token:
        print("Укажите FIGMA_ACCESS_TOKEN или --token")
        sys.exit(1)

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Пробуем экспортировать весь фрейм 958:444 как SVG (в нём и иконка, и текст)
    # Для только иконки нужен node id дочернего узла с иконкой
    node_id = NODE_ID
    print(f"Экспорт узла {node_id} в формате {args.format}...")
    image_url = export_image(token, node_id, args.format)
    if not image_url:
        print("Не удалось получить URL экспорта. Проверьте node-id и токен.")
        sys.exit(1)

    ext = "svg" if args.format == "svg" else "png"
    out_path = out_dir / f"payment_failed_icon.{ext}"
    print(f"Скачивание: {image_url[:80]}...")
    img_r = requests.get(image_url, timeout=30)
    img_r.raise_for_status()
    out_path.write_bytes(img_r.content)
    print(f"Сохранено: {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
