#!/usr/bin/env python3
"""Выполнение актуальных тестов (без устаревших singbox и device_id)."""

import sys
import os
from pathlib import Path

os.environ['PYTHONUNBUFFERED'] = '1'
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(line_buffering=True)
if hasattr(sys.stderr, 'reconfigure'):
    sys.stderr.reconfigure(line_buffering=True)

sys.path.insert(0, str(Path(__file__).parent))

print("=" * 70, flush=True)
print("🧪 АКТУАЛЬНЫЕ ТЕСТЫ ПРОЕКТА", flush=True)
print("=" * 70, flush=True)

results = {}
errors = []

# Тест: Протоколы VPN
print("\n📋 Тест протоколов VPN", flush=True)
print("-" * 70, flush=True)
try:
    from test_protocols import test_protocol_api_values, test_protocol_detection

    result, msg = test_protocol_api_values()
    if result:
        print(f"✅ API значения протоколов: {msg}", flush=True)
    else:
        print(f"❌ API значения протоколов: {msg}", flush=True)

    result2, msg2 = test_protocol_detection()
    if result2:
        print(f"✅ Определение протокола: {msg2}", flush=True)
    else:
        print(f"❌ Определение протокола: {msg2}", flush=True)

    results['protocols'] = result and result2
    if not results['protocols']:
        errors.append(("protocols", f"{msg}\n{msg2}"))
except Exception as e:
    print(f"❌ Ошибка: {e}", flush=True)
    import traceback
    traceback.print_exc()
    results['protocols'] = False
    errors.append(("protocols", str(e)))

# Итог
print("\n" + "=" * 70, flush=True)
print("📊 ИТОГОВЫЙ РЕЗУЛЬТАТ", flush=True)
print("=" * 70, flush=True)

all_passed = results.get('protocols', False)
print("✅ protocols" if all_passed else "❌ protocols", flush=True)

if errors:
    print("\n❌ ОШИБКИ:", flush=True)
    for name, error in errors:
        print(f"  {name}: {error}", flush=True)

print("\nПолный план проверок: docs/TEST_PLAN_CURRENT.md", flush=True)

if all_passed:
    print("\n✅ Тесты пройдены.", flush=True)
    sys.exit(0)
else:
    print("\n❌ Тесты не пройдены.", flush=True)
    sys.exit(1)
