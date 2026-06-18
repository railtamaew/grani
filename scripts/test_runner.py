#!/usr/bin/env python3
"""Запуск всех тестов с гарантированным выводом"""

import sys
import traceback
from pathlib import Path

# Устанавливаем путь
sys.path.insert(0, str(Path(__file__).parent))

print("=" * 70)
print("🧪 ТЕСТИРОВАНИЕ СИСТЕМЫ")
print("=" * 70)

results = {}

# Тест 1: Sing-box
print("\n📋 1. Тест sing-box конфигураций")
print("-" * 70)
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
    print("✅ VLESS+REALITY: формат корректен")
    
    config2 = generate_vless_tls_config()
    outbound2 = config2['outbounds'][0]
    assert 'server' in outbound2, 'Нет поля server'
    assert 'settings' not in outbound2, 'Не должно быть settings'
    assert 'tls' in outbound2, 'Нет поля tls'
    print("✅ VLESS+TLS: формат корректен")
    
    config3 = generate_vmess_config()
    outbound3 = config3['outbounds'][0]
    assert 'server' in outbound3, 'Нет поля server'
    assert 'alter_id' in outbound3, 'Нет alter_id для VMESS'
    assert 'settings' not in outbound3, 'Не должно быть settings'
    print("✅ VMESS+TLS: формат корректен")
    
    print("✅ Все тесты sing-box конфигураций пройдены!")
    results['singbox'] = True
except Exception as e:
    print(f"❌ Ошибка: {e}")
    traceback.print_exc()
    results['singbox'] = False

# Тест 2: Device ID
print("\n📋 2. Тест механизма device_id")
print("-" * 70)
try:
    from test_device_id import MockAPIClient
    
    mock_api = MockAPIClient()
    device_id = "TEST_001"
    
    status, _ = mock_api.register_device(device_id, "Test Device", "android")
    assert status == 200, f"Ожидался 200, получен {status}"
    print("✅ Регистрация устройства: OK (200)")
    
    status, _ = mock_api.register_device(device_id, "Test Device", "android")
    assert status == 409, f"Ожидался 409, получен {status}"
    print("✅ Повторная регистрация: OK (409)")
    
    status, _ = mock_api.send_logs(device_id, [{"event_type": "test"}])
    assert status == 200, f"Ожидался 200, получен {status}"
    print("✅ Отправка логов: OK (200)")
    
    status, _ = mock_api.send_logs("UNREGISTERED_001", [{"event_type": "test"}])
    assert status == 404, f"Ожидался 404, получен {status}"
    print("✅ Обработка 404: OK")
    
    print("✅ Все тесты device_id пройдены!")
    results['device_id'] = True
except Exception as e:
    print(f"❌ Ошибка: {e}")
    traceback.print_exc()
    results['device_id'] = False

# Тест 3: Протоколы
print("\n📋 3. Тест протоколов VPN")
print("-" * 70)
try:
    from test_protocols import test_protocol_api_values, test_protocol_detection
    
    result, msg = test_protocol_api_values()
    if result:
        print(f"✅ API значения протоколов: {msg}")
    else:
        print(f"❌ API значения протоколов: {msg}")
    
    result2, msg2 = test_protocol_detection()
    if result2:
        print(f"✅ Определение протокола: {msg2}")
    else:
        print(f"❌ Определение протокола: {msg2}")
    
    print("✅ Тесты протоколов завершены!")
    results['protocols'] = result and result2
except Exception as e:
    print(f"❌ Ошибка: {e}")
    traceback.print_exc()
    results['protocols'] = False

# Итог
print("\n" + "=" * 70)
print("📊 ИТОГОВЫЙ РЕЗУЛЬТАТ")
print("=" * 70)

all_passed = True
for name, passed in results.items():
    status = "✅" if passed else "❌"
    print(f"{status} {name}")
    if not passed:
        all_passed = False

if all_passed:
    print("\n✅ ВСЕ ТЕСТЫ ПРОЙДЕНЫ! Можно собирать APK.")
    sys.exit(0)
else:
    print("\n❌ НЕКОТОРЫЕ ТЕСТЫ НЕ ПРОЙДЕНЫ. Исправьте ошибки.")
    sys.exit(1)
