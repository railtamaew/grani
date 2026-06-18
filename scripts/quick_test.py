#!/usr/bin/env python3
"""Быстрый тест всех компонентов"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

print("=" * 70)
print("🧪 БЫСТРЫЙ ТЕСТ ВСЕХ КОМПОНЕНТОВ")
print("=" * 70)

results = {}

# 1. Sing-box
print("\n📋 1. Sing-box конфигурации")
print("-" * 70)
try:
    from test_singbox_config import generate_vless_reality_config, generate_vless_tls_config, generate_vmess_config
    
    # VLESS+REALITY
    config1 = generate_vless_reality_config()
    outbound1 = config1['outbounds'][0]
    assert 'server' in outbound1
    assert 'server_port' in outbound1
    assert 'settings' not in outbound1
    assert 'stream_settings' not in outbound1
    assert 'tls' in outbound1
    assert 'reality' in outbound1['tls']
    print("✅ VLESS+REALITY: OK")
    
    # VLESS+TLS
    config2 = generate_vless_tls_config()
    outbound2 = config2['outbounds'][0]
    assert 'server' in outbound2
    assert 'settings' not in outbound2
    assert 'tls' in outbound2
    print("✅ VLESS+TLS: OK")
    
    # VMESS+TLS
    config3 = generate_vmess_config()
    outbound3 = config3['outbounds'][0]
    assert 'server' in outbound3
    assert 'alter_id' in outbound3
    assert 'settings' not in outbound3
    print("✅ VMESS+TLS: OK")
    
    results['singbox'] = True
    print("✅ Все тесты sing-box пройдены!")
except Exception as e:
    print(f"❌ Ошибка: {e}")
    import traceback
    traceback.print_exc()
    results['singbox'] = False

# 2. Device ID
print("\n📋 2. Device ID")
print("-" * 70)
try:
    from test_device_id import MockAPIClient
    
    api = MockAPIClient()
    device_id = "TEST_001"
    
    status, _ = api.register_device(device_id, "Test", "android")
    assert status == 200
    print("✅ Регистрация (200): OK")
    
    status, _ = api.register_device(device_id, "Test", "android")
    assert status == 409
    print("✅ Повторная регистрация (409): OK")
    
    status, _ = api.send_logs(device_id, [{"event_type": "test"}])
    assert status == 200
    print("✅ Отправка логов (200): OK")
    
    status, _ = api.send_logs("UNREG", [{"event_type": "test"}])
    assert status == 404
    print("✅ Обработка 404: OK")
    
    results['device_id'] = True
    print("✅ Все тесты device_id пройдены!")
except Exception as e:
    print(f"❌ Ошибка: {e}")
    import traceback
    traceback.print_exc()
    results['device_id'] = False

# 3. Протоколы
print("\n📋 3. Протоколы VPN")
print("-" * 70)
try:
    from test_protocols import test_protocol_api_values, test_protocol_detection
    
    result1, msg1 = test_protocol_api_values()
    if result1:
        print(f"✅ API значения: OK")
    else:
        print(f"❌ API значения: {msg1}")
    
    result2, msg2 = test_protocol_detection()
    if result2:
        print(f"✅ Определение протокола: OK")
    else:
        print(f"❌ Определение протокола: {msg2}")
    
    results['protocols'] = result1 and result2
except Exception as e:
    print(f"❌ Ошибка: {e}")
    import traceback
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
    print("\n❌ НЕКОТОРЫЕ ТЕСТЫ НЕ ПРОЙДЕНЫ.")
    sys.exit(1)
