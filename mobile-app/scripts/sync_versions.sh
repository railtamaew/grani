#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PUBSPEC_FILE="$PROJECT_DIR/pubspec.yaml"
LOCAL_PROPERTIES="$PROJECT_DIR/android/local.properties"
VPN_SERVICE_FILE="$PROJECT_DIR/android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt"

log() {
    echo "[sync_versions] $1"
}

if [ ! -f "$PUBSPEC_FILE" ]; then
    echo "pubspec.yaml не найден: $PUBSPEC_FILE"
    exit 1
fi

VERSION_LINE=$(grep "^version:" "$PUBSPEC_FILE" | head -1 | sed -E 's/version:[[:space:]]*//')
if [ -z "$VERSION_LINE" ]; then
    echo "Не удалось прочитать версию из pubspec.yaml"
    exit 1
fi

VERSION_NAME=$(echo "$VERSION_LINE" | cut -d'+' -f1)
BUILD_NUMBER=$(echo "$VERSION_LINE" | cut -d'+' -f2)
if [ -z "$BUILD_NUMBER" ]; then
    BUILD_NUMBER="1"
fi

log "pubspec.yaml version=$VERSION_NAME build=$BUILD_NUMBER"

if [ ! -f "$LOCAL_PROPERTIES" ]; then
    log "local.properties не найден, создаю с sdk.dir/flutter.sdk"
    cat > "$LOCAL_PROPERTIES" << 'PROPS'
sdk.dir=/opt/android-sdk
flutter.sdk=/opt/flutter
PROPS
fi

if grep -q "^flutter.versionName=" "$LOCAL_PROPERTIES"; then
    sed -i "s/^flutter.versionName=.*/flutter.versionName=$VERSION_NAME/" "$LOCAL_PROPERTIES"
else
    echo "flutter.versionName=$VERSION_NAME" >> "$LOCAL_PROPERTIES"
fi

if grep -q "^flutter.versionCode=" "$LOCAL_PROPERTIES"; then
    sed -i "s/^flutter.versionCode=.*/flutter.versionCode=$BUILD_NUMBER/" "$LOCAL_PROPERTIES"
else
    echo "flutter.versionCode=$BUILD_NUMBER" >> "$LOCAL_PROPERTIES"
fi

log "local.properties обновлен: flutter.versionName=$VERSION_NAME, flutter.versionCode=$BUILD_NUMBER"

GIT_HASH=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || true)
if [ -z "$GIT_HASH" ]; then
    GIT_HASH="nogit"
fi

CODE_VERSION="$(date +%Y-%m-%d)-v${BUILD_NUMBER}-${GIT_HASH}"
if [ -f "$VPN_SERVICE_FILE" ]; then
    sed -i "s/CODE_VERSION = \"[^\"]*\"/CODE_VERSION = \"$CODE_VERSION\"/" "$VPN_SERVICE_FILE"
    log "CODE_VERSION обновлен: $CODE_VERSION"
else
    log "VpnService.kt не найден, пропускаю CODE_VERSION"
fi

exit 0
