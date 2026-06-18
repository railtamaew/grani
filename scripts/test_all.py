#!/usr/bin/env python3
"""
Запуск актуальных тестов проекта (без устаревших singbox и device_id).

Сейчас запускает только тесты протоколов VPN.
Остальные проверки: backend pytest, admin-panel lint/test, mobile-app flutter test — см. docs/TEST_PLAN_CURRENT.md.
"""

import sys
import subprocess
import argparse
from pathlib import Path


def run_test_script(script_path: str, args: list = None) -> tuple[bool, str]:
    """Запускает тестовый скрипт и возвращает результат"""
    try:
        cmd = [sys.executable, script_path]
        if args:
            cmd.extend(args)
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=60,
        )
        output = result.stdout + result.stderr
        return (result.returncode == 0, output)
    except subprocess.TimeoutExpired:
        return False, f"Таймаут выполнения {script_path}"
    except Exception as e:
        return False, f"Ошибка выполнения {script_path}: {e}"


def main():
    parser = argparse.ArgumentParser(
        description="Запуск актуальных тестов (только протоколы VPN)"
    )
    parser.add_argument(
        "--skip-protocols",
        action="store_true",
        help="Пропустить тесты протоколов (тогда скрипт только выведет подсказку)",
    )
    args = parser.parse_args()

    script_dir = Path(__file__).parent

    print("🧪 Запуск актуальных тестов проекта\n")
    print("=" * 70)

    all_passed = True
    results = []

    if not args.skip_protocols:
        print("\n📋 Тестирование протоколов VPN")
        print("-" * 70)
        passed, output = run_test_script(str(script_dir / "test_protocols.py"))
        print(output)
        if passed:
            results.append("✅ протоколы VPN")
        else:
            results.append("❌ протоколы VPN")
            all_passed = False
    else:
        print("\n(Тесты протоколов пропущены по флагу --skip-protocols)")
        print("Полный план проверок: docs/TEST_PLAN_CURRENT.md")

    print("\n" + "=" * 70)
    print("📊 ИТОГ:")
    print("-" * 70)
    for r in results:
        print(f"   {r}")

    if all_passed and results:
        print("\n✅ Тесты пройдены.")
        return 0
    if all_passed and not results:
        print("\nЗапустите без --skip-protocols или смотрите docs/TEST_PLAN_CURRENT.md")
        return 0
    print("\n❌ Есть неуспешные проверки.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
