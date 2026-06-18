#!/usr/bin/env python3
"""
Скрипт для установки и запуска APK на Android устройстве
Сохраняет результаты в файл для чтения AI ассистентом
"""

import subprocess
import os
import sys
from datetime import datetime
from pathlib import Path

# Конфигурация
ANDROID_SDK = "/opt/android-sdk"
PROJECT_DIR = "/opt/grani"
APK_PATH = f"{PROJECT_DIR}/mobile-app/build/app/outputs/flutter-apk/app-debug.apk"
PACKAGE_NAME = "com.granivpn.mobile.debug"
OUTPUT_FILE = f"{PROJECT_DIR}/install_result_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"

# Настройка окружения
os.environ["PATH"] = f"{ANDROID_SDK}/platform-tools:{ANDROID_SDK}/cmdline-tools/latest/bin:{os.environ.get('PATH', '')}"
os.environ["ANDROID_HOME"] = ANDROID_SDK
os.environ["ANDROID_SDK_ROOT"] = ANDROID_SDK

def run_cmd(cmd, check=True, capture_output=True):
    """Выполнить команду и вернуть результат"""
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            check=check,
            capture_output=capture_output,
            text=True,
            timeout=300
        )
        return result.stdout if capture_output else None, result.returncode
    except subprocess.TimeoutExpired:
        return "TIMEOUT", 1
    except subprocess.CalledProcessError as e:
        return e.stdout if capture_output else None, e.returncode

def log(message, file=None):
    """Вывести сообщение и записать в файл"""
    msg = f"[{datetime.now().strftime('%H:%M:%S')}] {message}"
    print(msg)
    if file:
        file.write(msg + "\n")
        file.flush()

def main():
    output_lines = []
    
    with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
        log("=" * 50, f)
        log("Установка и запуск APK", f)
        log(f"Время начала: {datetime.now()}", f)
        log("=" * 50, f)
        log("", f)
        
        # Шаг 1: Проверка устройств
        log("[1/5] Проверка подключенных устройств...", f)
        stdout, code = run_cmd("adb start-server", check=False)
        stdout, code = run_cmd("adb devices")
        
        if code != 0:
            log("❌ ОШИБКА: Не удалось запустить adb", f)
            return 1
        
        # Парсим устройства
        devices = [line.split()[0] for line in stdout.split('\n') 
                  if line.strip() and 'device' in line and 'List' not in line]
        
        if not devices:
            log("❌ ОШИБКА: Не найдено подключенных устройств", f)
            log("", f)
            log("Доступные устройства:", f)
            log(stdout, f)
            return 1
        
        device = devices[0]
        stdout, _ = run_cmd(f"adb -s {device} shell getprop ro.product.model", check=False)
        device_model = stdout.strip() if stdout else "Unknown"
        log(f"✅ Найдено устройство: {device} ({device_model})", f)
        log("", f)
        
        # Шаг 2: Проверка APK
        log("[2/5] Проверка APK...", f)
        if not os.path.exists(APK_PATH):
            log("⚠️  APK не найден, запускаю сборку...", f)
            log("    (это может занять 5-10 минут)", f)
            log("", f)
            
            os.chdir(f"{PROJECT_DIR}/mobile-app")
            stdout, code = run_cmd("/opt/flutter/bin/flutter build apk --debug", check=False)
            
            if code != 0 or not os.path.exists(APK_PATH):
                log("❌ ОШИБКА: Не удалось собрать APK", f)
                log(stdout, f)
                return 1
            
            os.chdir(PROJECT_DIR)
        
        apk_size = os.path.getsize(APK_PATH) / (1024 * 1024)  # MB
        log(f"✅ APK найден: {APK_PATH} ({apk_size:.1f} MB)", f)
        log("", f)
        
        # Шаг 3: Установка
        log("[3/5] Установка APK на устройство...", f)
        run_cmd(f"adb -s {device} uninstall {PACKAGE_NAME}", check=False)
        
        stdout, code = run_cmd(f"adb -s {device} install -r {APK_PATH}", check=False)
        
        if code != 0:
            log("❌ ОШИБКА: Не удалось установить APK", f)
            log(stdout, f)
            return 1
        
        log("✅ APK успешно установлен", f)
        log("", f)
        
        # Шаг 4: Логирование (запускаем в фоне)
        log("[4/5] Настройка логирования...", f)
        log_dir = f"{PROJECT_DIR}/logs"
        Path(log_dir).mkdir(parents=True, exist_ok=True)
        log_file = f"{log_dir}/app_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
        
        # Останавливаем старые процессы
        run_cmd("pkill -f 'adb.*logcat.*com.granivpn.mobile.debug'", check=False)
        
        # Запускаем logcat в фоне
        subprocess.Popen(
            f"adb -s {device} logcat | grep --line-buffered -E '(com.granivpn.mobile.debug|flutter|AndroidRuntime)' | tee {log_file} > /dev/null",
            shell=True
        )
        
        log(f"✅ Логирование запущено: {log_file}", f)
        log("", f)
        
        # Шаг 5: Запуск приложения
        log("[5/5] Запуск приложения...", f)
        run_cmd(f"adb -s {device} shell am force-stop {PACKAGE_NAME}", check=False)
        
        stdout, code = run_cmd(
            f"adb -s {device} shell am start -n {PACKAGE_NAME}/.MainActivity",
            check=False
        )
        
        if code != 0:
            log("⚠️  Попытка альтернативного запуска...", f)
            run_cmd(
                f"adb -s {device} shell monkey -p {PACKAGE_NAME} -c android.intent.category.LAUNCHER 1",
                check=False
            )
        
        log("✅ Приложение запущено", f)
        log("", f)
        
        log("=" * 50, f)
        log("✅ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!", f)
        log("=" * 50, f)
        log("", f)
        log(f"Устройство: {device} ({device_model})", f)
        log(f"Приложение: {PACKAGE_NAME}", f)
        log(f"Логи: {log_file}", f)
        log(f"Время завершения: {datetime.now()}", f)
        log("", f)
        log(f"Результаты сохранены в: {OUTPUT_FILE}", f)
    
    print(f"\n✅ Установка завершена! Результаты в: {OUTPUT_FILE}")
    return 0

if __name__ == "__main__":
    sys.exit(main())






