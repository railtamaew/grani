#!/bin/bash
set -e

# Unified build script for consistent APK versioning
# Usage: ./scripts/build_unified.sh [--clean] [--release|--debug] [--version X.Y.Z] [--build N] [--no-increment]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PUBSPEC_FILE="$PROJECT_DIR/pubspec.yaml"
LOCAL_PROPERTIES="$PROJECT_DIR/android/local.properties"
VPN_SERVICE_FILE="$PROJECT_DIR/android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt"
BUILD_LOG="$PROJECT_DIR/build_info.log"

cd "$PROJECT_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$BUILD_LOG"
}

get_current_version() {
    local version_line
    version_line=$(grep "^version:" "$PUBSPEC_FILE" | head -1)
    echo "$version_line" | sed -E 's/version:[[:space:]]*//'
}

get_version_name() {
    local full_version="$1"
    echo "$full_version" | cut -d'+' -f1
}

get_build_number() {
    local full_version="$1"
    if [[ "$full_version" == *"+"* ]]; then
        echo "$full_version" | cut -d'+' -f2
    else
        echo "1"
    fi
}

update_pubspec_version() {
    local version_name="$1"
    local build_number="$2"
    local new_version="${version_name}+${build_number}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/^version:.*/version: $new_version/" "$PUBSPEC_FILE"
    else
        sed -i "s/^version:.*/version: $new_version/" "$PUBSPEC_FILE"
    fi
    log "Updated pubspec.yaml version: $new_version"
}

update_local_properties_version() {
    local version_name="$1"
    local build_number="$2"
    if [ ! -f "$LOCAL_PROPERTIES" ]; then
        touch "$LOCAL_PROPERTIES"
    fi
    if grep -q "^flutter.versionName=" "$LOCAL_PROPERTIES"; then
        sed -i "s/^flutter.versionName=.*/flutter.versionName=$version_name/" "$LOCAL_PROPERTIES"
    else
        echo "flutter.versionName=$version_name" >> "$LOCAL_PROPERTIES"
    fi
    if grep -q "^flutter.versionCode=" "$LOCAL_PROPERTIES"; then
        sed -i "s/^flutter.versionCode=.*/flutter.versionCode=$build_number/" "$LOCAL_PROPERTIES"
    else
        echo "flutter.versionCode=$build_number" >> "$LOCAL_PROPERTIES"
    fi
    log "Updated local.properties: versionName=$version_name, versionCode=$build_number"
}

update_code_version() {
    local build_number="$1"
    local git_hash
    git_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")
    local date_str
    date_str=$(date '+%Y-%m-%d')
    local new_code_version="${date_str}-v${build_number}-${git_hash}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/CODE_VERSION = \".*\"/CODE_VERSION = \"${new_code_version}\"/" "$VPN_SERVICE_FILE"
    else
        sed -i "s/CODE_VERSION = \".*\"/CODE_VERSION = \"${new_code_version}\"/" "$VPN_SERVICE_FILE"
    fi
    log "Updated CODE_VERSION: $new_code_version"
}

CLEAN_BUILD=false
BUILD_MODE="release"
CUSTOM_VERSION=""
CUSTOM_BUILD=""
NO_INCREMENT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)
            CLEAN_BUILD=true
            shift
            ;;
        --release)
            BUILD_MODE="release"
            shift
            ;;
        --debug)
            BUILD_MODE="debug"
            shift
            ;;
        --version)
            CUSTOM_VERSION="$2"
            shift 2
            ;;
        --build)
            CUSTOM_BUILD="$2"
            shift 2
            ;;
        --no-increment)
            NO_INCREMENT=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--clean] [--release|--debug] [--version X.Y.Z] [--build N] [--no-increment]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

log "=========================================="
log "Start unified APK build"
log "=========================================="

CURRENT_VERSION="$(get_current_version)"
VERSION_NAME="$(get_version_name "$CURRENT_VERSION")"
BUILD_NUMBER="$(get_build_number "$CURRENT_VERSION")"

if [ -n "$CUSTOM_VERSION" ]; then
    VERSION_NAME="$CUSTOM_VERSION"
fi

if [ -n "$CUSTOM_BUILD" ]; then
    BUILD_NUMBER="$CUSTOM_BUILD"
elif [ "$NO_INCREMENT" = false ]; then
    BUILD_NUMBER=$((BUILD_NUMBER + 1))
fi

update_pubspec_version "$VERSION_NAME" "$BUILD_NUMBER"
update_local_properties_version "$VERSION_NAME" "$BUILD_NUMBER"
update_code_version "$BUILD_NUMBER"

if [ "$CLEAN_BUILD" = true ]; then
    log "Running flutter clean..."
    flutter clean
fi

log "Running flutter pub get..."
flutter pub get

log "Building APK ($BUILD_MODE)..."
BUILD_START=$(date +%s)

if [ "$BUILD_MODE" = "release" ]; then
    flutter build apk --release --split-per-abi --target-platform android-arm64 --no-tree-shake-icons
    APK_PATH="$PROJECT_DIR/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
else
    flutter build apk --debug --no-tree-shake-icons
    APK_PATH="$PROJECT_DIR/build/app/outputs/flutter-apk/app-debug.apk"
fi

BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))

if [ ! -f "$APK_PATH" ]; then
    log "ERROR: APK not found: $APK_PATH"
    exit 1
fi

APK_SIZE=$(du -h "$APK_PATH" | cut -f1)
OUTPUT_NAME="/opt/grani/granivpn-${BUILD_MODE}-${VERSION_NAME}+${BUILD_NUMBER}.apk"
cp "$APK_PATH" "$OUTPUT_NAME"
chmod 644 "$OUTPUT_NAME"

log "Build completed in ${BUILD_DURATION}s"
log "APK: $APK_PATH ($APK_SIZE)"
log "Copied to: $OUTPUT_NAME"
