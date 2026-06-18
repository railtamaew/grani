#!/usr/bin/env python3
"""
Скрипт для получения координат элементов из Figma по REST API и вычисления
отступов (например, logoToTitleGap) для обновления констант в mobile-app/lib/theme.dart.

Вариант 1: вызов Figma API и вывод absoluteBoundingBox для нужных узлов.
Вариант 2: вычисление отступов и вывод значений для вставки в тему.

Использование:
  export FIGMA_ACCESS_TOKEN="figd_..."   # предпочтительно, токен не в репозитории
  # или скрипт прочитает docs/figma_auth_data.json (figma_token)
  python3 scripts/figma_fetch_layout.py

Требования: requests (pip install requests)
"""

import json
import os
import sys
from pathlib import Path
from urllib.parse import quote

# Базовый путь проекта (скрипт в scripts/, данные в docs/)
REPO_ROOT = Path(__file__).resolve().parent.parent
DOCS_DIR = REPO_ROOT / "docs"
FIGMA_AUTH_PATH = DOCS_DIR / "figma_auth_data.json"

FILE_KEY = "TZYqJZyQtl31Zao6JC8GSl"
# Node IDs в Figma (в URL передаём с дефисом: 516-295)
NODE_IDS = ["516:295", "516:206", "516:223", "562:732", "958:337", "562:488", "1143:193"]
# Имена узлов для поиска (по макету: как названы слои в Figma)
# Точные имена + по подстроке (case-insensitive)
LOGO_NAMES = ("logoGrani", "logo_grani_new 1", "logo_grani_new", "Logo", "logo")
TITLE_BLOCK_NAMES = ("textBlock", "title_block", "Title", "title", "TitleBlock", "text")


def get_token():
    token = os.environ.get("FIGMA_ACCESS_TOKEN")
    if token:
        return token
    if FIGMA_AUTH_PATH.exists():
        with open(FIGMA_AUTH_PATH, encoding="utf-8") as f:
            data = json.load(f)
        return data.get("figma_token")
    return None


def find_node_by_name(node, names, path=""):
    """Рекурсивно ищет узел по имени. Возвращает (node, bounds) или None."""
    name = node.get("name") or ""
    bounds = node.get("absoluteBoundingBox")
    if name in names and bounds:
        return {"name": name, "bounds": bounds, "path": path}
    for i, child in enumerate(node.get("children") or []):
        found = find_node_by_name(child, names, f"{path}/{child.get('name', i)}")
        if found:
            return found
    return None


def name_matches(name, allowed_names):
    """Проверяет совпадение по точному имени или по подстроке (case-insensitive)."""
    if not name:
        return False
    name_lower = name.lower()
    for n in allowed_names:
        if name == n or (n.lower() in name_lower) or (name_lower in n.lower()):
            return True
    return False


def collect_nodes_by_name(node, names, out_list, path=""):
    """Собирает все узлы с заданными именами (для логотипа и title_block)."""
    name = node.get("name") or ""
    bounds = node.get("absoluteBoundingBox")
    if bounds and name_matches(name, names):
        out_list.append({"name": name, "bounds": bounds, "path": path})
    for i, child in enumerate(node.get("children") or []):
        collect_nodes_by_name(child, names, out_list, f"{path}/{child.get('name', i)}")


def list_all_nodes_with_bounds(node, out_list, depth=0, max_depth=4):
    """Список всех узлов с absoluteBoundingBox (имя и bounds) для отладки по макету."""
    if depth > max_depth:
        return
    name = node.get("name") or ""
    bounds = node.get("absoluteBoundingBox")
    if bounds:
        out_list.append({"depth": depth, "name": name, "bounds": bounds})
    for child in node.get("children") or []:
        list_all_nodes_with_bounds(child, out_list, depth + 1, max_depth)


def fetch_nodes(token, file_key, node_ids):
    """Запрашивает узлы файла через Figma REST API."""
    try:
        import requests
    except ImportError:
        print("Ошибка: нужен модуль requests. Выполните: pip install requests", file=sys.stderr)
        sys.exit(1)

    # В API node id передаётся с двоеточием (516:295), в URL кодируем
    ids_param = ",".join(quote(nid) for nid in node_ids)
    url = f"https://api.figma.com/v1/files/{file_key}/nodes?ids={ids_param}&depth=8"
    headers = {"X-Figma-Token": token}

    resp = requests.get(url, headers=headers, timeout=15)
    if resp.status_code != 200:
        try:
            err = resp.json()
            msg = err.get("message", resp.text)
        except Exception:
            msg = resp.text
        print(
            f"Ошибка Figma API: {resp.status_code}. {msg}\n"
            "Проверьте: 1) токен действителен; 2) доступ к файлу есть.",
            file=sys.stderr,
        )
        sys.exit(1)
    return resp.json()


def main():
    token = get_token()
    if not token:
        print("Ошибка: не задан FIGMA_ACCESS_TOKEN и не найден docs/figma_auth_data.json с figma_token", file=sys.stderr)
        sys.exit(1)

    data = fetch_nodes(token, FILE_KEY, NODE_IDS)
    nodes = data.get("nodes") or {}

    results = {}
    theme_suggestions = {}

    for node_id, wrap in nodes.items():
        doc = wrap.get("document")
        if not doc:
            continue
        name = doc.get("name", "")
        bounds = doc.get("absoluteBoundingBox")
        results[node_id] = {"frameName": name, "absoluteBoundingBox": bounds, "children": []}

        logo_list = []
        title_list = []
        collect_nodes_by_name(doc, LOGO_NAMES, logo_list)
        collect_nodes_by_name(doc, TITLE_BLOCK_NAMES, title_list)

        # Берём первый найденный логотип и первый блок заголовка
        logo = logo_list[0] if logo_list else None
        title = title_list[0] if title_list else None

        if logo and title:
            lb = logo["bounds"]
            tb = title["bounds"]
            logo_bottom = lb["y"] + lb.get("height", 0)
            gap = round(tb["y"] - logo_bottom)
            results[node_id]["logoToTitleGap"] = gap
            results[node_id]["logo"] = lb
            results[node_id]["titleBlock"] = tb
            theme_suggestions[name] = gap
        else:
            # По макету: вывести все узлы с bounds, чтобы ориентироваться на реальные имена
            all_with_bounds = []
            list_all_nodes_with_bounds(doc, all_with_bounds, max_depth=5)
            results[node_id]["_allNodesWithBounds"] = [
                {"name": n["name"], "y": n["bounds"].get("y"), "height": n["bounds"].get("height")}
                for n in all_with_bounds[:30]
            ]

    # Вывод 1: сырые данные (вариант 1)
    print("=== Figma nodes (absoluteBoundingBox) ===\n")
    print(json.dumps(results, indent=2, ensure_ascii=False))

    # Вывод 2: рекомендуемые значения для темы (вариант 2)
    if theme_suggestions:
        print("\n=== Рекомендуемые отступы для theme.dart (logoToTitleGap) ===\n")
        for screen_name, gap in theme_suggestions.items():
            print(f"  {screen_name}: {gap} px")
        suggested = max(theme_suggestions.values()) if theme_suggestions else 24
        print(f"\n  Использовать одно значение для всех экранов: {suggested} px")
        print(f"  В lib/theme.dart замените logoToTitleGap на: {suggested}.0")

    return 0


if __name__ == "__main__":
    sys.exit(main())
