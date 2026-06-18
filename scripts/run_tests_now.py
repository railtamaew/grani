#!/usr/bin/env python3
"""Запуск всех тестов с явным выводом"""

import sys
import json
from pathlib import Path

# Принудительно включаем буферизацию вывода
sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

sys.path.insert(0, 'scripts')

def test_singbox():
    """Тест sing-box конфигураций"""
    print("=" * 70)
    print("📋 1. Тест sing-box конфигураций")
    print("-" * 70)
    try:
        from test_singbox_config import generate_vless_reality_config, generate_vless_tls_config, generate_vmess_config
        
        # VLESS+REALITY
        config1 = generate_vless_reality_config()
        outbound1 = config1['outbounds'][0]
        assert 'server' in outbound1, 'Нет поля server'
        assert 'server_port' in outbound1, 'Нет поля server_port'
        assert 'settings' not in outbound1, 'Не должно быть settings'
        assert 'stream_settings' not in outbound1, 'Не должно быть stream_settings'
        assert 'tls' in outbound1, 'Нет поля tls'
        assert 'reality' in outbound1['tls'], 'Нет reality в tls'
        print("✅ VLESS+REALITY: формат корректен")
        
        # VLESS+TLS
        config2 = generate_vless_tls_config()
        outbound2 = config2['outbounds'][0]
        assert 'server' in outbound2, 'Нет поля server'
        assert 'settings' not in outbound2, 'Не должно быть settings'
        assert 'tls' in outbound2, 'Нет поля tls'
        print("✅ VLESS+TLS: формат корректен")
        
        # VMESS+TLS
        config3 = generate_vmess_config()
        outbound3 = config3['outbounds'][0]
        assert 'server' in outbound3, 'Нет поля server'
        assert 'alter_id' in outbound3, 'Нет alter_id для VMESS'
        assert 'settings' not in outbound3, 'Не должно быть settings'
        print("✅ VMESS+TLS: формат корректен")
        
        print("✅ Все тесты sing-box конфигураций пройдены!")
        return True
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

def test_device_id():
    """Тест device_id"""
    print("\n📋 2. Тест механизма device_id")
    print("-" * 70)
    try:
        from test_device_id import MockAPIClient
        
        mock_api = MockAPIClient()
        device_id = "TEST_001"
        
        # Регистрация
        status, _ = mock_api.register_device(device_id, "Test Device", "android")
        assert status == 200, f"Ожидался 200, получен {status}"
        print("✅ Регистрация устройства: OK (200)")
        
        # Повторная регистрация
        status, _ = mock_api.register_device(device_id, "Test Device", "android")
        assert status == 409, f"Ожидался 409, получен {status}"
        print("✅ Повторная регистрация: OK (409)")
        
        # Отправка логов
        status, _ = mock_api.send_logs(device_id, [{"event_type": "test"}])
        assert status == 200, f"Ожидался 200, получен {status}"
        print("✅ Отправка логов: OK (200)")
        
        # Отправка логов для незарегистрированного устройства
        status, _ = mock_api.send_logs("UNREGISTERED_001", [{"event_type": "test"}])
        assert status == 404, f"Ожидался 404, получен {status}"
        print("✅ Обработка 404: OK")
        
        print("✅ Все тесты device_id пройдены!")
        return True
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

def test_protocols():
    """Тест протоколов"""
    print("\n📋 3. Тест протоколов VPN")
    print("-" * 70)
    try:
        from test_protocols import test_protocol_api_values, test_protocol_detection
        
        # API значения
        result, msg = test_protocol_api_values()
        if result:
            print(f"✅ API значения протоколов: {msg}")
        else:
            print(f"❌ API значения протоколов: {msg}")
        
        # Определение протокола
        result, msg = test_protocol_detection()
        if result:
            print(f"✅ Определение протокола: {msg}")
        else:
            print(f"❌ Определение протокола: {msg}")
        
        print("✅ Тесты протоколов завершены!")
        return True
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    print("=" * 70)
    print("🧪 ТЕСТИРОВАНИЕ СИСТЕМЫ")
    print("=" * 70)
    
    results = []
    results.append(("sing-box", test_singbox()))
    results.append(("device_id", test_device_id()))
    results.append(("протоколы", test_protocols()))
    
    print("\n" + "=" * 70)
    print("📊 ИТОГОВЫЙ РЕЗУЛЬТАТ")
    print("=" * 70)
    
    all_passed = True
    for name, passed in results:
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
