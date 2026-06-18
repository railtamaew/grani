#!/usr/bin/env python3
"""
Скрипт для экспорта иконки приложения из Figma.

Использование:
    python scripts/export_app_icon.py --file-key FILE_KEY --node-id NODE_ID [--output OUTPUT_PATH] [--token FIGMA_TOKEN]

Пример:
    python scripts/export_app_icon.py --file-key TZYqJZyQtl31Zao6JC8GSl --node-id 720:422

Если токен не указан, скрипт покажет инструкции по экспорту вручную.
"""

import argparse
import requests
import sys
import os
from pathlib import Path


def export_from_figma_api(file_key: str, node_id: str, output_path: str, token: str = None):
    """Экспортирует изображение из Figma через API."""
    if not token:
        print("❌ Figma API токен не указан.")
        print("\nДля экспорта через API необходим Figma Personal Access Token.")
        print("Получить токен можно здесь: https://www.figma.com/developers/api#access-tokens")
        print("\nАльтернативный способ - экспорт вручную из Figma:")
        print_manual_export_instructions(file_key, node_id)
        return False

    # Форматируем node_id для API (заменяем : на -)
    api_node_id = node_id.replace(":", "-")
    
    # URL для экспорта
    export_url = f"https://api.figma.com/v1/images/{file_key}"
    headers = {"X-Figma-Token": token}
    params = {
        "ids": api_node_id,
        "format": "png",
        "scale": "1"
    }

    try:
        print(f"📥 Запрос к Figma API для узла {node_id}...")
        response = requests.get(export_url, headers=headers, params=params)
        response.raise_for_status()
        
        data = response.json()
        if "images" not in data or api_node_id not in data["images"]:
            print(f"❌ Ошибка: изображение не найдено в ответе API")
            return False
        
        image_url = data["images"][api_node_id]
        print(f"📥 Скачивание изображения из {image_url}...")
        
        image_response = requests.get(image_url)
        image_response.raise_for_status()
        
        # Создаем директорию если нужно
        output_file = Path(output_path)
        output_file.parent.mkdir(parents=True, exist_ok=True)
        
        # Сохраняем изображение
        with open(output_file, "wb") as f:
            f.write(image_response.content)
        
        print(f"✅ Иконка успешно сохранена: {output_path}")
        print(f"📏 Размер файла: {os.path.getsize(output_path) / 1024:.2f} KB")
        return True
        
    except requests.exceptions.RequestException as e:
        print(f"❌ Ошибка при запросе к Figma API: {e}")
        print("\nПопробуйте экспортировать вручную из Figma:")
        print_manual_export_instructions(file_key, node_id)
        return False


def print_manual_export_instructions(file_key: str, node_id: str):
    """Показывает инструкции по ручному экспорту из Figma."""
    figma_url = f"https://www.figma.com/design/{file_key}/GRANI?node-id={node_id.replace(':', '-')}"
    
    print("\n" + "="*60)
    print("📋 ИНСТРУКЦИИ ПО ЭКСПОРТУ ИКОНКИ ИЗ FIGMA")
    print("="*60)
    print(f"\n1. Откройте файл в Figma:")
    print(f"   {figma_url}")
    print("\n2. Выделите фрейм с иконкой (node-id: {node_id})")
    print("\n3. В правой панели найдите раздел 'Export'")
    print("\n4. Нажмите '+' для добавления параметров экспорта")
    print("\n5. Установите параметры:")
    print("   - Format: PNG")
    print("   - Size: 1024×1024 px (или 2x для 2048×2048)")
    print("\n6. Нажмите 'Export' и сохраните файл как:")
    print("   mobile-app/assets/icons/icon_01.png")
    print("\n7. После сохранения запустите генерацию иконок:")
    print("   flutter pub run flutter_launcher_icons")
    print("="*60 + "\n")


def main():
    parser = argparse.ArgumentParser(description="Экспорт иконки приложения из Figma")
    parser.add_argument("--file-key", required=True, help="Figma file key")
    parser.add_argument("--node-id", required=True, help="Figma node ID (формат: 720:422)")
    parser.add_argument("--output", default="assets/icons/icon_01.png", 
                       help="Путь для сохранения иконки (по умолчанию: assets/icons/icon_01.png)")
    parser.add_argument("--token", help="Figma Personal Access Token (опционально)")
    
    args = parser.parse_args()
    
    # Проверяем наличие токена в переменных окружения, если не указан явно
    token = args.token or os.getenv("FIGMA_TOKEN")
    
    # Попытка экспорта через API
    if token:
        success = export_from_figma_api(args.file_key, args.node_id, args.output, token)
        if success:
            sys.exit(0)
    
    # Если API не работает, показываем инструкции
    export_from_figma_api(args.file_key, args.node_id, args.output, None)
    sys.exit(1)


if __name__ == "__main__":
    main()



