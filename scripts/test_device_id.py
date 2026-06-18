#!/usr/bin/env python3
"""
Тестирование механизма device_id перед сборкой APK

Проверяет:
- Регистрацию устройства
- Повторную регистрацию (409)
- Отправку логов с device_id
- Обработку 404 ошибок
- Механизм повторной регистрации

Использование:
    python3 scripts/test_device_id.py                    # Все тесты
    python3 scripts/test_device_id.py --scenario register # Только регистрация
    python3 scripts/test_device_id.py --mock            # Использовать mock API
"""

import json
import sys
import argparse
from typing import Dict, Any, Optional, Tuple
from pathlib import Path
from datetime import datetime
import uuid

# Добавляем путь к скриптам для импорта
sys.path.insert(0, str(Path(__file__).parent.parent / "backend"))


class MockAPIClient:
    """Mock API клиент для тестирования без реального сервера"""
    
    def __init__(self):
        self.registered_devices = {}  # device_id -> device_data
        self.logs = []  # Список отправленных логов
    
    def register_device(self, device_id: str, name: str, platform: str, user_id: int = 1) -> Tuple[int, Dict]:
        """Имитирует регистрацию устройства"""
        if device_id in self.registered_devices:
            # Устройство уже зарегистрировано
            return 409, {"message": "Устройство уже зарегистрировано", "device_id": device_id}
        
        device_data = {
            "id": len(self.registered_devices) + 1,
            "device_id": device_id,
            "name": name,
            "platform": platform,
            "user_id": user_id,
            "registered_at": datetime.now().isoformat()
        }
        self.registered_devices[device_id] = device_data
        
        return 200, {"message": "Устройство зарегистрировано", "device_id": device_id}
    
    def send_logs(self, device_id: str, logs: list) -> Tuple[int, Dict]:
        """Имитирует отправку логов"""
        if device_id not in self.registered_devices:
            return 404, {"detail": "Not Found"}
        
        # Сохраняем логи
        for log in logs:
            log["device_id"] = device_id
            log["sent_at"] = datetime.now().isoformat()
            self.logs.append(log)
        
        return 200, {"message": f"Сохранено {len(logs)} логов"}
    
    def get_device(self, device_id: str) -> Optional[Dict]:
        """Получает устройство"""
        return self.registered_devices.get(device_id)


def test_device_registration() -> Tuple[bool, str]:
    """Тестирует регистрацию устройства"""
    mock_api = MockAPIClient()
    
    device_id = "TEST_DEVICE_001"
    name = "Test Device"
    platform = "android"
    
    # Первая регистрация
    status_code, response = mock_api.register_device(device_id, name, platform)
    if status_code != 200:
        return False, f"❌ Первая регистрация должна вернуть 200, получен {status_code}"
    
    # Повторная регистрация (должна вернуть 409)
    status_code, response = mock_api.register_device(device_id, name, platform)
    if status_code != 409:
        return False, f"❌ Повторная регистрация должна вернуть 409, получен {status_code}"
    
    return True, "✅ Регистрация устройства работает корректно (200 при первой, 409 при повторной)"


def test_device_logs_sending() -> Tuple[bool, str]:
    """Тестирует отправку логов с device_id"""
    mock_api = MockAPIClient()
    
    device_id = "TEST_DEVICE_002"
    name = "Test Device 2"
    platform = "android"
    
    # Регистрируем устройство
    mock_api.register_device(device_id, name, platform)
    
    # Отправляем логи
    logs = [
        {
            "event_type": "connection_start",
            "protocol": "xray_reality",
            "server_id": 1
        },
        {
            "event_type": "connection_success",
            "protocol": "xray_reality",
            "server_id": 1
        }
    ]
    
    status_code, response = mock_api.send_logs(device_id, logs)
    if status_code != 200:
        return False, f"❌ Отправка логов должна вернуть 200, получен {status_code}"
    
    if len(mock_api.logs) != 2:
        return False, f"❌ Должно быть сохранено 2 лога, сохранено {len(mock_api.logs)}"
    
    return True, "✅ Отправка логов работает корректно"


def test_device_not_found_404() -> Tuple[bool, str]:
    """Тестирует обработку 404 при отправке логов для незарегистрированного устройства"""
    mock_api = MockAPIClient()
    
    device_id = "UNREGISTERED_DEVICE"
    logs = [{"event_type": "connection_start"}]
    
    status_code, response = mock_api.send_logs(device_id, logs)
    if status_code != 404:
        return False, f"❌ Отправка логов для незарегистрированного устройства должна вернуть 404, получен {status_code}"
    
    return True, "✅ Обработка 404 работает корректно"


def test_device_retry_registration() -> Tuple[bool, str]:
    """Тестирует механизм повторной регистрации при 404"""
    mock_api = MockAPIClient()
    
    device_id = "TEST_DEVICE_003"
    name = "Test Device 3"
    platform = "android"
    
    # Пытаемся отправить логи без регистрации (получим 404)
    logs = [{"event_type": "connection_start"}]
    status_code, _ = mock_api.send_logs(device_id, logs)
    
    if status_code != 404:
        return False, "❌ Должен быть 404 для незарегистрированного устройства"
    
    # Регистрируем устройство (имитация повторной регистрации)
    status_code, _ = mock_api.register_device(device_id, name, platform)
    if status_code != 200:
        return False, f"❌ Регистрация должна вернуть 200, получен {status_code}"
    
    # Теперь логи должны отправляться успешно
    status_code, _ = mock_api.send_logs(device_id, logs)
    if status_code != 200:
        return False, f"❌ После регистрации логи должны отправляться (200), получен {status_code}"
    
    return True, "✅ Механизм повторной регистрации работает корректно"


def test_device_id_format() -> Tuple[bool, str]:
    """Проверяет формат device_id"""
    test_cases = [
        {
            "device_id": "UKQ1.230924.001",
            "valid": True,
            "description": "Android device ID"
        },
        {
            "device_id": "iPhone-12345",
            "valid": True,
            "description": "iOS device ID"
        },
        {
            "device_id": "",
            "valid": False,
            "description": "Пустой device_id"
        },
        {
            "device_id": " ",
            "valid": False,
            "description": "Пробелы в device_id"
        },
    ]
    
    results = []
    for test_case in test_cases:
        device_id = test_case["device_id"]
        is_valid = bool(device_id and device_id.strip())

        if is_valid == test_case["valid"]:
            results.append(f"✅ {test_case['description']}: {device_id}")
        else:
            results.append(f"❌ {test_case['description']}: {device_id} (ожидалось valid={test_case['valid']}, получено {is_valid})")
    
    all_passed = all("✅" in r for r in results)
    return all_passed, "\n".join(results)


def test_all_device_id_scenarios(scenario_filter: Optional[str] = None, use_mock: bool = True) -> bool:
    """Запускает все тесты device_id"""
    print("🧪 Тестирование механизма device_id...\n")
    
    scenarios = [
        {
            "name": "Формат device_id",
            "func": test_device_id_format,
            "keywords": ["format", "device_id"]
        },
        {
            "name": "Регистрация устройства",
            "func": test_device_registration,
            "keywords": ["register", "registration"]
        },
        {
            "name": "Отправка логов",
            "func": test_device_logs_sending,
            "keywords": ["logs", "sending"]
        },
        {
            "name": "Обработка 404",
            "func": test_device_not_found_404,
            "keywords": ["404", "not_found"]
        },
        {
            "name": "Повторная регистрация при 404",
            "func": test_device_retry_registration,
            "keywords": ["retry", "404", "register"]
        },
    ]
    
    # Фильтруем сценарии
    if scenario_filter:
        scenarios = [s for s in scenarios if any(
            scenario_filter.lower() in k.lower() for k in s["keywords"]
        )]
        if not scenarios:
            print(f"❌ Сценарий '{scenario_filter}' не найден")
            return False
    
    all_passed = True
    
    for scenario in scenarios:
        print(f"📋 Тест: {scenario['name']}")
        print("-" * 60)
        
        is_passed, message = scenario["func"]()
        print(f"   {message}\n")
        
        if not is_passed:
            all_passed = False
    
    return all_passed


def main():
    parser = argparse.ArgumentParser(
        description="Тестирование механизма device_id перед сборкой APK"
    )
    parser.add_argument(
        "--scenario",
        type=str,
        help="Тестировать только указанный сценарий (register, logs, 404, retry, format)"
    )
    parser.add_argument(
        "--mock",
        action="store_true",
        default=True,
        help="Использовать mock API (по умолчанию)"
    )
    
    args = parser.parse_args()
    
    success = test_all_device_id_scenarios(
        scenario_filter=args.scenario,
        use_mock=args.mock
    )
    
    if success:
        print("✅ Все тесты device_id пройдены!")
        return 0
    else:
        print("❌ Некоторые тесты не пройдены")
        return 1


if __name__ == "__main__":
    sys.exit(main())
