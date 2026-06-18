#!/bin/bash
set -e

LOG_FILE="/tmp/release_apk_build_$(date +%Y%m%d_%H%M%S).log"
PID_FILE="/tmp/release_apk_build.pid"

export JAVA_HOME=/usr/lib/jvm/java-1.17.0-openjdk-amd64
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=/opt/android-sdk
export PATH=$PATH:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools

cd /opt/grani/mobile-app

echo "Starting RELEASE APK build at $(date)" | tee -a $LOG_FILE
echo "PID: $$" | tee -a $LOG_FILE
echo $$ > $PID_FILE

# Синхронизация версий (pubspec -> local.properties + CODE_VERSION)
if [ -f scripts/sync_versions.sh ]; then
    echo "Syncing versions..." | tee -a $LOG_FILE
    bash scripts/sync_versions.sh >> $LOG_FILE 2>&1
fi

# Получение зависимостей
echo "Getting dependencies..." | tee -a $LOG_FILE
/opt/flutter/bin/flutter pub get >> $LOG_FILE 2>&1

# Сборка RELEASE APK (arm64 только)
echo "Building RELEASE APK (arm64)..." | tee -a $LOG_FILE
set +e
timeout 1800 /opt/flutter/bin/flutter build apk --release --target-platform android-arm64 >> $LOG_FILE 2>&1
BUILD_EXIT_CODE=$?
set -e

# Проверка результата
APK_DIR="build/app/outputs/flutter-apk"
APK_ARM64="$APK_DIR/app-release.apk"
APK_ARM="$APK_DIR/app-armeabi-v7a-release.apk"

if [ -f "$APK_ARM64" ] || [ -f "$APK_ARM" ]; then
    if [ $BUILD_EXIT_CODE -ne 0 ]; then
        echo "⚠️ Flutter returned exit code $BUILD_EXIT_CODE, но APK найдены. Продолжаем." | tee -a $LOG_FILE
    fi
    echo "✅ RELEASE APKs successfully built in: $APK_DIR" | tee -a $LOG_FILE
    ls -lh "$APK_DIR"/*.apk | tee -a $LOG_FILE
    
    # Копирование APK в корень проекта
    if [ -f "$APK_ARM64" ]; then
        cp "$APK_ARM64" /opt/grani/granivpn-release-arm64.apk
        echo "✅ APK copied to /opt/grani/granivpn-release-arm64.apk" | tee -a $LOG_FILE
        ls -lh /opt/grani/granivpn-release-arm64.apk | tee -a $LOG_FILE
    fi
    if [ -f "$APK_ARM" ]; then
        cp "$APK_ARM" /opt/grani/granivpn-release-armeabi-v7a.apk
        echo "✅ APK copied to /opt/grani/granivpn-release-armeabi-v7a.apk" | tee -a $LOG_FILE
        ls -lh /opt/grani/granivpn-release-armeabi-v7a.apk | tee -a $LOG_FILE
    fi
    
    echo "Build completed at $(date)" | tee -a $LOG_FILE
    rm -f $PID_FILE
    exit 0
else
    echo "❌ Error: APK file not found" | tee -a $LOG_FILE
    echo "Build failed with exit code $BUILD_EXIT_CODE" | tee -a $LOG_FILE
    echo "Last 100 lines of log:" | tee -a $LOG_FILE
    tail -100 $LOG_FILE | tee -a $LOG_FILE
    rm -f $PID_FILE
    exit $BUILD_EXIT_CODE
fi

