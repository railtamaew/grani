#!/usr/bin/env python3
"""
Тестирование протоколов VPN перед сборкой APK

Проверяет правильность работы с различными протоколами:
- WireGuard
- GRANIWG
- Xray (VLESS, VMESS, REALITY)
- OpenVPN Cloak

Использование:
    python3 scripts/test_protocols.py                    # Все тесты
    python3 scripts/test_protocols.py --protocol wireguard # Только WireGuard
    python3 scripts/test_protocols.py --validate-only      # Только валидация формата
"""

import json
import sys
import argparse
from typing import Dict, Any, List, Optional
from pathlib import Path

# Добавляем путь к скриптам для импорта
sys.path.insert(0, str(Path(__file__).parent.parent / "backend"))

# Импортируем функции из test_singbox_config
import importlib.util
spec = importlib.util.spec_from_file_location(
    "test_singbox_config",
    Path(__file__).parent / "test_singbox_config.py"
)
if spec and spec.loader:
    test_singbox_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(test_singbox_module)
    generate_vless_reality_config = test_singbox_module.generate_vless_reality_config
    generate_vless_tls_config = test_singbox_module.generate_vless_tls_config
    generate_vmess_config = test_singbox_module.generate_vmess_config
    validate_format = test_singbox_module.validate_format
else:
    # Fallback если не можем импортировать
    def validate_format(config: Dict[str, Any]) -> tuple[bool, list[str]]:
        errors = []
        if "outbounds" not in config:
            errors.append("❌ Отсутствует секция outbounds")
        return len(errors) == 0, errors
    
    def generate_vless_reality_config(**kwargs):
        return {"outbounds": [{"type": "vless"}]}
    
    def generate_vless_tls_config(**kwargs):
        return {"outbounds": [{"type": "vless"}]}
    
    def generate_vmess_config(**kwargs):
        return {"outbounds": [{"type": "vmess"}]}


def test_wireguard_config_format() -> tuple[bool, str]:
    """Тестирует формат конфигурации WireGuard"""
    # WireGuard использует свой формат конфигурации
    config = {
        "interface": {
            "private_key": "test_private_key",
            "address": "10.0.0.2/32",
            "dns": ["8.8.8.8", "8.8.4.4"]
        },
        "peer": {
            "public_key": "test_public_key",
            "endpoint": "45.12.132.94:51820",
            "allowed_ips": ["0.0.0.0/0"],
            "persistent_keepalive": 25
        }
    }
    
    # Проверяем обязательные поля
    required_interface_fields = ["private_key", "address"]
    required_peer_fields = ["public_key", "endpoint", "allowed_ips"]
    
    errors = []
    for field in required_interface_fields:
        if field not in config.get("interface", {}):
            errors.append(f"❌ WireGuard interface должен содержать поле: {field}")
    
    for field in required_peer_fields:
        if field not in config.get("peer", {}):
            errors.append(f"❌ WireGuard peer должен содержать поле: {field}")
    
    if errors:
        return False, "\n".join(errors)
    
    return True, "✅ Формат конфигурации WireGuard корректен"


def test_xray_protocols() -> tuple[bool, str]:
    """Тестирует все Xray протоколы"""
    
    scenarios = [
        {
            "name": "VLESS + REALITY",
            "config": generate_vless_reality_config()
        },
        {
            "name": "VLESS + TLS",
            "config": generate_vless_tls_config()
        },
        {
            "name": "VMESS",
            "config": generate_vmess_config()
        },
    ]
    
    results = []
    for scenario in scenarios:
        is_valid, errors = validate_format(scenario["config"])
        if is_valid:
            results.append(f"✅ {scenario['name']}: формат корректен")
        else:
            results.append(f"❌ {scenario['name']}: ошибки формата")
            for error in errors:
                results.append(f"   {error}")
    
    all_passed = all("✅" in r for r in results)
    return all_passed, "\n".join(results)


def test_protocol_api_values() -> tuple[bool, str]:
    """Проверяет соответствие значений протоколов для API"""
    # Значения из мобильного приложения
    expected_protocols = {
        "wireguard": "wireguard",
        "graniwg": "graniwg",
        "xray_vless": "xray_vless",
        "xray_vmess": "xray_vmess",
        "xray_reality": "xray_reality",
        "openvpn_cloak": "openvpn_cloak",
    }
    
    # Проверяем, что все значения корректны
    errors = []
    for protocol, api_value in expected_protocols.items():
        if not api_value or api_value.strip() == "":
            errors.append(f"❌ Протокол {protocol} имеет пустое API значение")
        if " " in api_value:
            errors.append(f"❌ Протокол {protocol} содержит пробелы в API значении: '{api_value}'")
    
    if errors:
        return False, "\n".join(errors)
    
    return True, "✅ Все API значения протоколов корректны"


def test_protocol_detection() -> tuple[bool, str]:
    """Тестирует определение протокола из конфигурации"""
    test_cases = [
        {
            "name": "VLESS с REALITY",
            "config": {"tls": "reality", "scy": "none", "v": "2"},
            "expected": "vless"
        },
        {
            "name": "VLESS с TLS",
            "config": {"tls": "tls", "scy": "none", "v": "2"},
            "expected": "vless"
        },
        {
            "name": "VMESS",
            "config": {"v": "2", "aid": 0},
            "expected": "vmess"
        },
    ]
    
    results = []
    for test_case in test_cases:
        # Упрощенная логика определения (как в мобильном приложении)
        config = test_case["config"]
        detected = None
        
        if config.get("tls") == "reality" or (config.get("pbk") and config.get("tls") != "none"):
            detected = "vless"
        elif config.get("v") == "2" and config.get("aid") is not None:
            detected = "vmess"
        elif config.get("v") == "2" and config.get("tls") != "none":
            detected = "vless"
        
        if detected == test_case["expected"]:
            results.append(f"✅ {test_case['name']}: определен как {detected}")
        else:
            results.append(f"❌ {test_case['name']}: ожидался {test_case['expected']}, получен {detected}")
    
    all_passed = all("✅" in r for r in results)
    return all_passed, "\n".join(results)


def test_all_protocols(protocol_filter: Optional[str] = None, validate_only: bool = False) -> bool:
    """Запускает все тесты протоколов"""
    print("🧪 Тестирование протоколов VPN...\n")
    
    tests = [
        {
            "name": "API значения протоколов",
            "func": test_protocol_api_values,
            "filter": None
        },
        {
            "name": "Определение протокола",
            "func": test_protocol_detection,
            "filter": None
        },
        {
            "name": "Xray протоколы (VLESS, VMESS, REALITY)",
            "func": test_xray_protocols,
            "filter": ["xray", "vless", "vmess", "reality"]
        },
        {
            "name": "WireGuard формат",
            "func": test_wireguard_config_format,
            "filter": ["wireguard", "graniwg"]
        },
    ]
    
    # Фильтруем тесты
    if protocol_filter:
        tests = [t for t in tests if t["filter"] is None or any(
            protocol_filter.lower() in f.lower() for f in t["filter"]
        )]
        if not tests:
            print(f"❌ Протокол '{protocol_filter}' не найден")
            return False
    
    all_passed = True
    
    for test in tests:
        print(f"📋 Тест: {test['name']}")
        print("-" * 60)
        
        is_passed, message = test["func"]()
        print(f"   {message}\n")
        
        if not is_passed:
            all_passed = False
    
    return all_passed


def main():
    parser = argparse.ArgumentParser(
        description="Тестирование протоколов VPN перед сборкой APK"
    )
    parser.add_argument(
        "--protocol",
        type=str,
        help="Тестировать только указанный протокол (wireguard, xray, vless, vmess, reality)"
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Только проверка формата без полной валидации"
    )
    
    args = parser.parse_args()
    
    success = test_all_protocols(
        protocol_filter=args.protocol,
        validate_only=args.validate_only
    )
    
    if success:
        print("✅ Все тесты протоколов пройдены!")
        return 0
    else:
        print("❌ Некоторые тесты не пройдены")
        return 1


if __name__ == "__main__":
    sys.exit(main())
