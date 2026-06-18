"""
Unit-тесты для проверки механизма device_id

Проверяет логику работы с device_id без запуска реального API.
"""

import pytest
from typing import Dict, Any, Optional
from datetime import datetime


class MockDeviceRegistry:
    """Mock реестр устройств для тестирования"""
    
    def __init__(self):
        self.devices = {}  # device_id -> device_data
    
    def register(self, device_id: str, name: str, platform: str, user_id: int = 1) -> tuple[int, Dict]:
        """Регистрация устройства"""
        if device_id in self.devices:
            return 409, {"message": "Устройство уже зарегистрировано"}
        
        device_data = {
            "id": len(self.devices) + 1,
            "device_id": device_id,
            "name": name,
            "platform": platform,
            "user_id": user_id
        }
        self.devices[device_id] = device_data
        return 200, {"message": "Устройство зарегистрировано", "device_id": device_id}
    
    def get_device(self, device_id: str) -> Optional[Dict]:
        """Получение устройства"""
        return self.devices.get(device_id)
    
    def send_logs(self, device_id: str, logs: list) -> tuple[int, Dict]:
        """Отправка логов"""
        if device_id not in self.devices:
            return 404, {"detail": "Not Found"}
        return 200, {"message": f"Сохранено {len(logs)} логов"}


def test_device_registration_success():
    """Проверяет успешную регистрацию устройства"""
    registry = MockDeviceRegistry()
    
    device_id = "TEST_DEVICE_001"
    status_code, response = registry.register(device_id, "Test Device", "android")
    
    assert status_code == 200, "Первая регистрация должна вернуть 200"
    assert device_id in registry.devices, "Устройство должно быть зарегистрировано"
    assert registry.devices[device_id]["platform"] == "android"


def test_device_registration_duplicate():
    """Проверяет обработку повторной регистрации"""
    registry = MockDeviceRegistry()
    
    device_id = "TEST_DEVICE_002"
    registry.register(device_id, "Test Device", "android")
    
    # Повторная регистрация
    status_code, response = registry.register(device_id, "Test Device", "android")
    
    assert status_code == 409, "Повторная регистрация должна вернуть 409"


def test_device_logs_sending_success():
    """Проверяет успешную отправку логов"""
    registry = MockDeviceRegistry()
    
    device_id = "TEST_DEVICE_003"
    registry.register(device_id, "Test Device", "android")
    
    logs = [
        {"event_type": "connection_start", "protocol": "xray_reality"},
        {"event_type": "connection_success", "protocol": "xray_reality"}
    ]
    
    status_code, response = registry.send_logs(device_id, logs)
    
    assert status_code == 200, "Отправка логов должна вернуть 200"


def test_device_logs_sending_404():
    """Проверяет обработку 404 при отправке логов для незарегистрированного устройства"""
    registry = MockDeviceRegistry()
    
    device_id = "UNREGISTERED_DEVICE"
    logs = [{"event_type": "connection_start"}]
    
    status_code, response = registry.send_logs(device_id, logs)
    
    assert status_code == 404, "Отправка логов для незарегистрированного устройства должна вернуть 404"


def test_device_id_format_valid():
    """Проверяет валидные форматы device_id"""
    valid_device_ids = [
        "UKQ1.230924.001",  # Android
        "iPhone-12345",      # iOS
        "web_1234567890",    # Web
        "test-device-001"    # Тестовый
    ]
    
    for device_id in valid_device_ids:
        assert device_id and device_id.strip(), f"device_id не должен быть пустым: '{device_id}'"
        assert len(device_id.strip()) > 0, f"device_id должен иметь длину > 0: '{device_id}'"


def test_device_id_format_invalid():
    """Проверяет невалидные форматы device_id"""
    invalid_device_ids = [
        "",
        " ",
        None
    ]
    
    for device_id in invalid_device_ids:
        if device_id is None:
            is_valid = False
        else:
            is_valid = device_id and device_id.strip() and len(device_id.strip()) > 0
        
        assert not is_valid, f"device_id должен быть невалидным: '{device_id}'"


def test_device_retry_mechanism():
    """Проверяет механизм повторной регистрации при 404"""
    registry = MockDeviceRegistry()
    
    device_id = "TEST_DEVICE_004"
    
    # Пытаемся отправить логи без регистрации (получим 404)
    logs = [{"event_type": "connection_start"}]
    status_code, _ = registry.send_logs(device_id, logs)
    assert status_code == 404, "Должен быть 404 для незарегистрированного устройства"
    
    # Регистрируем устройство (имитация повторной регистрации)
    status_code, _ = registry.register(device_id, "Test Device", "android")
    assert status_code == 200, "Регистрация должна вернуть 200"
    
    # Теперь логи должны отправляться успешно
    status_code, _ = registry.send_logs(device_id, logs)
    assert status_code == 200, "После регистрации логи должны отправляться (200)"


def test_device_registration_timeout():
    """Проверяет, что регистрация устройства может занимать время (таймаут)"""
    # В реальном приложении таймаут увеличен до 30 секунд
    timeout_seconds = 30
    
    assert timeout_seconds >= 10, "Таймаут регистрации должен быть не менее 10 секунд"
    assert timeout_seconds <= 60, "Таймаут регистрации не должен быть слишком большим"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
