#!/bin/bash
set -euo pipefail

# Установка AmneziaWG (AWG) на сервере.
# ВНИМАНИЕ: скрипт не запускается автоматически. Запускайте вручную на целевом сервере.

BUILD_DIR="/opt/amneziawg-build"

echo "[INFO] Installing build deps..."
apt-get update -y
apt-get install -y git build-essential pkg-config libmnl-dev libelf-dev \
  linux-headers-$(uname -r) software-properties-common python3-launchpadlib gnupg2

echo "[INFO] Trying PPA install..."
if ! add-apt-repository -y ppa:amnezia/ppa; then
  echo "[WARN] Failed to add PPA, fallback to manual build"
fi
apt-get update -y || true
if apt-get install -y amneziawg; then
  echo "[INFO] amneziawg installed via PPA"
else
  echo "[WARN] PPA install failed, fallback to manual build"

  echo "[INFO] Cloning AmneziaWG kernel module..."
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  if [ ! -d amneziawg-linux-kernel-module ]; then
    git clone https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git
  fi

  cd amneziawg-linux-kernel-module/src
  echo "[INFO] Building kernel module..."
  make
  echo "[INFO] Installing kernel module..."
  make install
  depmod -a

  echo "[INFO] Cloning AmneziaWG tools..."
  cd "$BUILD_DIR"
  if [ ! -d amneziawg-go ]; then
    git clone https://github.com/amnezia-vpn/amneziawg-go.git
  fi

  echo "[INFO] Building amneziawg-go..."
  cd amneziawg-go
  make
  make install
fi

echo "[INFO] Verifying module and tools..."
modprobe amneziawg || true
if command -v awg >/dev/null 2>&1; then
  awg --version || true
fi

echo "[INFO] Done."
