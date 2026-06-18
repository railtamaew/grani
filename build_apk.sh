#!/bin/bash
set -e
cd /opt/grani/mobile-app
if [ -f scripts/sync_versions.sh ]; then
  bash scripts/sync_versions.sh
fi
echo "Starting Flutter build..."
flutter build apk --debug 2>&1 | tee /tmp/flutter_build_$(date +%s).log
echo "Build completed. APK location:"
ls -lh build/app/outputs/flutter-apk/*.apk 2>/dev/null | tail -1
