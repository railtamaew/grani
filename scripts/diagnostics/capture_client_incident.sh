#!/usr/bin/env bash
# Шаг 1 плана VPN lifecycle: зафиксировать окно инцидента и снять logcat/dumpsys.
#
# Переменные окружения (опционально):
#   USER_EMAIL          — email пользователя
#   INCIDENT_START_UTC  — начало окна, напр. 2026-04-24T12:20:00Z
#   INCIDENT_END_UTC    — конец окна
#   OUT_DIR             — каталог вывода (по умолчанию ./vpn_incident_capture_<UTC>)
#
# Использование:
#   USER_EMAIL='user@example.com' INCIDENT_START_UTC='2026-04-24T12:20:00Z' \
#     ./capture_client_incident.sh
#   ./capture_client_incident.sh --dumpsys
#
set -euo pipefail

DUMPSYS=0
for arg in "$@"; do
  case "$arg" in
    --dumpsys) DUMPSYS=1 ;;
  esac
done

ROOT="${OUT_DIR:-./vpn_incident_capture_$(date -u +%Y%m%d_%H%M%S)utc}"
mkdir -p "$ROOT"

{
  echo "# incident_manifest (UTC)"
  echo "captured_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "user_email=${USER_EMAIL:-}"
  echo "incident_window_start_utc=${INCIDENT_START_UTC:-}"
  echo "incident_window_end_utc=${INCIDENT_END_UTC:-}"
  echo "host=$(hostname 2>/dev/null || true)"
} >"$ROOT/incident_manifest.txt"

if command -v adb >/dev/null 2>&1; then
  if adb devices 2>/dev/null | grep -qE 'device$'; then
    echo "Снимаю logcat → $ROOT/logcat_threadtime.txt"
    adb logcat -d -v threadtime >"$ROOT/logcat_threadtime.txt" 2>&1 || true
    adb get-serialno >"$ROOT/adb_serial.txt" 2>&1 || true
  else
    echo "adb: нет подключённого устройства (пропуск logcat)" | tee "$ROOT/adb_skip.txt"
  fi
else
  echo "adb не в PATH (пропуск logcat)" | tee "$ROOT/adb_skip.txt"
fi

if [[ "$DUMPSYS" -eq 1 ]] && command -v adb >/dev/null 2>&1 && adb devices 2>/dev/null | grep -qE 'device$'; then
  echo "Снимаю dumpsys activity → $ROOT/dumpsys_activity_head.txt"
  adb shell dumpsys activity activities 2>/dev/null | head -200 >"$ROOT/dumpsys_activity_head.txt" || true
fi

echo "Готово: $ROOT"
ls -la "$ROOT"
