#!/usr/bin/env bash
# Шаг матрицы плана: вытащить из сохранённого logcat строки по PID, протоколу, probe, кэшу Xray.
#
# Использование:
#   ./logcat_protocol_matrix.sh /path/to/logcat_threadtime.txt
#
set -euo pipefail

FILE="${1:-}"
if [[ -z "$FILE" || ! -f "$FILE" ]]; then
  echo "Укажите путь к файлу logcat: $0 /path/to/logcat.txt" >&2
  exit 1
fi

section() { echo ""; echo "=== $1 ==="; }

section "Process death / crash (FATAL, AndroidRuntime)"
grep -E 'FATAL|AndroidRuntime|tombstone|libc\)' "$FILE" | tail -80 || true

section "OOM / kill"
grep -iE 'lowmemorykiller|am_kill|ActivityManager.*died|:Died' "$FILE" | tail -80 || true

section "App / Flutter / VPN service"
grep -E 'com\.granivpn\.mobile|flutter|VpnService|GraniVpnService' "$FILE" | tail -120 || true

section "Protocol restore / persist (матрица §8)"
grep -E 'restore_selection|persist_ui_selection|selectProtocol|selectServer' "$FILE" | tail -120 || true

section "Xray / prepare / cache"
grep -E 'session_prepare_trace|xray_|xray_cache_hit|GoLog|libXray' "$FILE" | tail -120 || true

section "Connectivity probe"
grep -E 'CONNECTIVITY_PROBE|\[CONNECTIVITY_PROBE\]' "$FILE" | tail -80 || true

section "FlutterEngine (второй движок)"
grep -E 'FlutterEngine|FlutterJNI' "$FILE" | tail -40 || true

section "Device id load (дубликаты UUID)"
grep -E '_loadDeviceId|loadDeviceId|device_id' "$FILE" | tail -60 || true
