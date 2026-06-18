#!/bin/bash

# Скрипт для сборки release APK с автоматическим версионированием
# Этот скрипт создает production сборку с подписью (если настроена)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

# Используем основной скрипт сборки с очисткой
"$SCRIPT_DIR/build_apk.sh" --clean "$@"


