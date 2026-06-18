#!/usr/bin/env python3
"""Простой тест для проверки работы системы"""

print("🧪 Тест 1: Проверка импортов...")
try:
    import json
    import sys
    from pathlib import Path
    print("✅ Импорты работают")
except Exception as e:
    print(f"❌ Ошибка импорта: {e}")
    sys.exit(1)

print("\n🧪 Тест 2: Генерация sing-box конфигурации...")
try:
    sys.path.insert(0, str(Path(__file__).parent))
    from test_singbox_config import generate_vless_reality_config
    
    config = generate_vless_reality_config()
    
    # Проверяем формат
    assert "outbounds" in config, "Должна быть секция outbounds"
    outbound = config["outbounds"][0]
    assert "server" in outbound, "Должно быть поле server"
    assert "server_port" in outbound, "Должно быть поле server_port"
    assert "settings" not in outbound, "НЕ должно быть поле settings"
    assert "stream_settings" not in outbound, "НЕ должно быть поле stream_settings"
    
    print("✅ Конфигурация сгенерирована правильно")
    print(f"   - server: {outbound.get('server')}")
    print(f"   - server_port: {outbound.get('server_port')}")
    print(f"   - type: {outbound.get('type')}")
except Exception as e:
    print(f"❌ Ошибка генерации: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)

print("\n🧪 Тест 3: Проверка device_id...")
try:
    from test_device_id import MockAPIClient
    
    mock_api = MockAPIClient()
    device_id = "TEST_001"
    
    # Регистрация
    status, _ = mock_api.register_device(device_id, "Test", "android")
    assert status == 200, f"Регистрация должна вернуть 200, получен {status}"
    
    # Повторная регистрация
    status, _ = mock_api.register_device(device_id, "Test", "android")
    assert status == 409, f"Повторная регистрация должна вернуть 409, получен {status}"
    
    # Отправка логов
    status, _ = mock_api.send_logs(device_id, [{"event_type": "test"}])
    assert status == 200, f"Отправка логов должна вернуть 200, получен {status}"
    
    print("✅ Device ID механизм работает правильно")
except Exception as e:
    print(f"❌ Ошибка device_id: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)

print("\n✅ Все простые тесты пройдены!")
print("\n📋 Следующий шаг: запустите полные тесты")
print("   python3 scripts/test_all.py")
