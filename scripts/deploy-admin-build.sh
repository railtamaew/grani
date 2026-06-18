#!/bin/bash
# Деплой админ-панели на сервер
# Использование: ./deploy-admin-build.sh [user@server]
# Или скопируйте build вручную: scp -r admin-panel/build user@server:/opt/grani/admin-panel/

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/admin-panel/build"
REMOTE_PATH="/opt/grani/admin-panel"

if [ ! -f "$BUILD_DIR/index.html" ]; then
  echo "Ошибка: Сначала соберите админку: cd admin-panel && npm run build"
  exit 1
fi

if ! grep -Rq '/observability' "$BUILD_DIR/static/js/" 2>/dev/null; then
  echo "Предупреждение: в $BUILD_DIR/static/js не найдена строка /observability."
  echo "  После деплоя маршрут может редиректить на /dashboard (старый catch-all в App.tsx)."
fi

SERVER="${1:-}"
if [ -z "$SERVER" ]; then
  echo "Сборка готова: $BUILD_DIR"
  echo ""
  echo "Для деплоя на сервер выполните:"
  echo "  scp -r $BUILD_DIR/* $USER@your-server:$REMOTE_PATH/build/"
  echo "  # или"
  echo "  rsync -avz --delete $BUILD_DIR/ $USER@your-server:$REMOTE_PATH/build/"
  echo ""
  echo "После копирования на сервере: sudo bash server-config/fix-admin-403.sh"
  exit 0
fi

echo "Копирование build на $SERVER..."
rsync -avz --delete "$BUILD_DIR/" "$SERVER:$REMOTE_PATH/build/"
echo "Готово. Проверьте: https://admin.granilink.com"
