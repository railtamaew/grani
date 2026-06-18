#!/bin/bash
# Исправление 403 Forbidden для admin.granilink.com
# Запускать на сервере: sudo bash fix-admin-403.sh

set -e
ADMIN_ROOT="/opt/grani/admin-panel"
BUILD_DIR="${ADMIN_ROOT}/build"
NGINX_USER="${NGINX_USER:-www-data}"

echo "=== Исправление доступа к админ-панели ==="

if [ ! -d "$ADMIN_ROOT" ]; then
  echo "Ошибка: каталог $ADMIN_ROOT не найден. Разверните проект на сервер."
  exit 1
fi

if [ ! -f "${BUILD_DIR}/index.html" ]; then
  echo "Ошибка: сборка не найдена (нет ${BUILD_DIR}/index.html)."
  echo "На сервере выполните:"
  echo "  cd /opt/grani/admin-panel && npm ci && npm run build"
  echo "или скопируйте каталог build с локальной машины в $BUILD_DIR"
  exit 1
fi

# Права: nginx должен читать каталоги и файлы
echo "Устанавливаю владельца $NGINX_USER для $BUILD_DIR..."
chown -R "$NGINX_USER:$NGINX_USER" "$BUILD_DIR"
chmod -R 755 "$BUILD_DIR"
find "$BUILD_DIR" -type f -exec chmod 644 {} \;

# Чтобы nginx дошел до build, родительские каталоги должны быть доступны на выполнение
for d in /opt /opt/grani "$ADMIN_ROOT"; do
  if [ -d "$d" ]; then
    chmod 755 "$d"
    echo "  chmod 755 $d"
  fi
done

echo "Перезагрузка nginx..."
nginx -t && systemctl reload nginx

echo "Готово. Откройте https://admin.granilink.com"
