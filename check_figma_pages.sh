#!/bin/bash
# Скрипт для проверки доступа к страницам Figma

echo "=========================================="
echo "  Проверка доступа к страницам Figma"
echo "=========================================="
echo ""

FILE_KEY="TZYqJZyQtl31Zao6JC8GSl"

echo "File Key: $FILE_KEY"
echo ""

# Известные страницы из скриншота
declare -A PAGES=(
    ["Auth Flow"]="515:201"
    ["VPN Flow"]="unknown"
    ["Profile"]="unknown"
    ["grani cist"]="unknown"
)

echo "Известные страницы:"
for page in "${!PAGES[@]}"; do
    echo "  - $page: ${PAGES[$page]}"
done
echo ""

echo "Попытка найти node ID для неизвестных страниц..."
echo ""

# Попробуем стандартные варианты для страниц
# Обычно страницы имеют ID вида page_id:0 или можно найти через структуру

echo "Рекомендации по настройке доступа:"
echo ""
echo "1. Откройте Figma файл в браузере"
echo "2. Выберите нужную страницу (например, VPN Flow)"
echo "3. Скопируйте URL - он будет содержать node-id"
echo "4. Формат URL: https://figma.com/design/FILE_KEY/PageName?node-id=XXX-YYY"
echo "5. Node ID из URL нужно преобразовать: XXX-YYY -> XXX:YYY"
echo ""

echo "Альтернативный способ:"
echo "1. В Figma выберите любой элемент на странице"
echo "2. Скопируйте ссылку (Share > Copy link)"
echo "3. Извлеките node-id из URL"
echo ""





