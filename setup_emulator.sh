#!/usr/bin/env bash
set -euo pipefail

ANDROID_SDK_ROOT="/opt/android-sdk"
CMDLINE_TOOLS_ZIP="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
AVD_NAME="grani_emulator"
SYSTEM_IMAGE="system-images;android-30;default;x86_64"
DEVICE_PROFILE="pixel"

echo "== Install dependencies =="
apt-get update -y
apt-get install -y openjdk-17-jdk unzip wget libgl1-mesa-dev libpulse0

echo "== Install Android SDK cmdline tools =="
mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools"
cd "${ANDROID_SDK_ROOT}/cmdline-tools"
if [ ! -d "latest" ]; then
  wget -q "${CMDLINE_TOOLS_ZIP}" -O cmdline-tools.zip
  unzip -q cmdline-tools.zip
  rm cmdline-tools.zip
  mv cmdline-tools latest
fi

export ANDROID_SDK_ROOT
export PATH="${PATH}:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator"

echo "== Accept licenses =="
yes | sdkmanager --licenses >/dev/null

echo "== Install SDK components =="
sdkmanager "platform-tools" "emulator" "platforms;android-30" "${SYSTEM_IMAGE}"

echo "== Create AVD =="
echo "no" | avdmanager create avd -n "${AVD_NAME}" -k "${SYSTEM_IMAGE}" -d "${DEVICE_PROFILE}" --force

echo "== Start emulator headless (low resource) =="
nohup emulator -avd "${AVD_NAME}" \
  -no-window -no-audio \
  -gpu swiftshader_indirect \
  -no-snapshot -no-boot-anim \
  -netdelay none -netspeed full \
  -no-accel \
  -memory 1024 -cores 2 \
  -partition-size 2048 \
  >/opt/android-sdk/emulator.log 2>&1 &

echo "== Wait for boot =="
adb wait-for-device
adb shell getprop sys.boot_completed
adb devices
echo "Emulator ready."
