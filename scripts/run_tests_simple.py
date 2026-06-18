#!/usr/bin/env python3
"""Упрощенный запуск тестов с гарантированным выводом"""

import sys
import json
from pathlib import Path

# Отключаем буферизацию
sys.stdout = sys.__stdout__
sys.stderr = sys.__stderr__

sys.path.insert(0, str(Path(__file__).parent))

print("=" * 70, flush=True)
print("🧪 ТЕСТИРОВАНИЕ СИСТЕМЫ", flush=True)
print("=" * 70, flush=True)

results = []

# Тест 1: Sing-box
print("\n📋 1. Тест sing-box конфигураций", flush=True)
print("-" * 70, flush=True)
try:
    from test_singbox_config import generate_vless_reality_config, generate_vless_tls_config, generate_vmess_config
    
    config1 = generate_vless_reality_config()
    outbound1 = config1['outbounds'][0]
    assert 'server' in outbound1, 'Нет поля server'
    assert 'server_port' in outbound1, 'Нет поля server_port'
    assert 'settings' not in outbound1, 'Не должно быть settings'
    assert 'stream_settings' not in outbound1, 'Не должно быть stream_settings'
    assert 'tls' in outbound1, 'Нет поля tls'
    assert 'reality' in outbound1['tls'], 'Нет reality в tls'
    print("✅ VLESS+REALITY: формат корректен", flush=True)
    
    config2 = generate_vless_tls_config()
    outbound2 = config2['outbounds'][0]
    assert 'server' in outbound2, 'Нет поля server'
    assert 'settings' not in outbound2, 'Не должно быть settings'
    assert 'tls' in outbound2, 'Нет поля tls'
    print("✅ VLESS+TLS: формат корректен", flush=True)
    
    config3 = generate_vmess_config()
    outbound3 = config3['outbounds'][0]
    assert 'server' in outbound3, 'Нет поля server'
    assert 'alter_id' in outbound3, 'Нет alter_id для VMESS'
    assert 'settings' not in outbound3, 'Не должно быть settings'
    print("✅ VMESS+TLS: формат корректен", flush=True)
    
    print("✅ Все тесты sing-box конфигураций пройдены!", flush=True)
    results.append(("sing-box", True))
except Exception as e:
    print(f"❌ Ошибка: {e}", flush=True)
    import traceback
    traceback.print_exc()
    results.append(("sing-box", False))

# Тест 2: Device ID
print("\n📋 2. Тест механизма device_id", flush=True)
print("-" * 70, flush=True)
try:
    from test_device_id import MockAPIClient
    
    mock_api = MockAPIClient()
    device_id = "TEST_001"
    
    status, _ = mock_api.register_device(device_id, "Test Device", "android")
    assert status == 200, f"Ожидался 200, получен {status}"
    print("✅ Регистрация устройства: OK (200)", flush=True)
    
    status, _ = mock_api.register_device(device_id, "Test Device", "android")
    assert status == 409, f"Ожидался 409, получен {status}"
    print("✅ Повторная регистрация: OK (409)", flush=True)
    
    status, _ = mock_api.send_logs(device_id, [{"event_type": "test"}])
    assert status == 200, f"Ожидался 200, получен {status}"
    print("✅ Отправка логов: OK (200)", flush=True)
    
    status, _ = mock_api.send_logs("UNREGISTERED_001", [{"event_type": "test"}])
    assert status == 404, f"Ожидался 404, получен {status}"
    print("✅ Обработка 404: OK", flush=True)
    
    print("✅ Все тесты device_id пройдены!", flush=True)
    results.append(("device_id", True))
except Exception as e:
    print(f"❌ Ошибка: {e}", flush=True)
    import traceback
    traceback.print_exc()
    results.append(("device_id", False))

# Тест 3: Протоколы
print("\n📋 3. Тест протоколов VPN", flush=True)
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
    
    print("✅ Тесты протоколов завершены!", flush=True)
    results.append(("протоколы", result and result2))
except Exception as e:
    print(f"❌ Ошибка: {e}", flush=True)
    import traceback
    traceback.print_exc()
    results.append(("протоколы", False))

# Итог
print("\n" + "=" * 70, flush=True)
print("📊 ИТОГОВЫЙ РЕЗУЛЬТАТ", flush=True)
print("=" * 70, flush=True)

all_passed = True
for name, passed in results:
    status = "✅" if passed else "❌"
    print(f"{status} {name}", flush=True)
    if not passed:
        all_passed = False

if all_passed:
    print("\n✅ ВСЕ ТЕСТЫ ПРОЙДЕНЫ! Можно собирать APK.", flush=True)
    sys.exit(0)
else:
    print("\n❌ НЕКОТОРЫЕ ТЕСТЫ НЕ ПРОЙДЕНЫ. Исправьте ошибки.", flush=True)
    sys.exit(1)
