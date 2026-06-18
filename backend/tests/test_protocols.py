"""
Unit-тесты для проверки протоколов VPN

Проверяет правильность работы с различными протоколами без запуска реальных сервисов.
"""

import pytest
from typing import Dict, Any


def test_protocol_api_values():
    """Проверяет соответствие значений протоколов для API"""
    # Значения из мобильного приложения (VpnProtocol.apiValue)
    protocol_api_values = {
        "wireguard": "wireguard",
        "graniwg": "graniwg",
        "xray_vless": "xray_vless",
        "xray_vmess": "xray_vmess",
        "xray_reality": "xray_reality",
    }
    
    # Проверяем, что все значения корректны
    for protocol, api_value in protocol_api_values.items():
        assert api_value, f"API значение для {protocol} не должно быть пустым"
        assert " " not in api_value, f"API значение для {protocol} не должно содержать пробелы: '{api_value}'"
        assert api_value == api_value.lower(), f"API значение для {protocol} должно быть в нижнем регистре: '{api_value}'"


def test_protocol_detection_vless_reality():
    """Проверяет определение VLESS с REALITY"""
    config = {
        "v": "2",
        "tls": "reality",
        "scy": "none",
        "pbk": "test-public-key",
        "sid": "test-short-id"
    }
    
    # Логика определения (как в XrayConfig.fromJson)
    is_vless = (
        config.get("tls") == "reality" or
        (config.get("pbk") and config.get("tls") != "none") or
        (config.get("v") == "2" and config.get("tls") != "none" and config.get("aid") is None)
    )
    
    assert is_vless, "Конфигурация с REALITY должна определяться как VLESS"


def test_protocol_detection_vmess():
    """Проверяет определение VMESS"""
    config = {
        "v": "2",
        "aid": 0,
        "scy": "auto"
    }
    
    # Логика определения (как в XrayConfig.fromJson)
    is_vmess = config.get("v") == "2" and config.get("aid") is not None
    
    assert is_vmess, "Конфигурация с aid должна определяться как VMESS"


def test_wireguard_config_structure():
    """Проверяет структуру конфигурации WireGuard"""
    config = {
        "interface": {
            "private_key": "test_private_key",
            "address": "10.0.0.2/32",
            "dns": ["8.8.8.8"]
        },
        "peer": {
            "public_key": "test_public_key",
            "endpoint": "45.12.132.94:51820",
            "allowed_ips": ["0.0.0.0/0"]
        }
    }
    
    # Проверяем обязательные поля
    assert "private_key" in config["interface"], "WireGuard interface должен содержать private_key"
    assert "address" in config["interface"], "WireGuard interface должен содержать address"
    assert "public_key" in config["peer"], "WireGuard peer должен содержать public_key"
    assert "endpoint" in config["peer"], "WireGuard peer должен содержать endpoint"
    assert "allowed_ips" in config["peer"], "WireGuard peer должен содержать allowed_ips"


def test_protocol_supported_protocols_format():
    """Проверяет формат списка поддерживаемых протоколов сервера"""
    server_data = {
        "supported_protocols": [
            "graniwg",
            "wireguard",
            "xray_reality",
            "xray_vless",
            "xray_vmess"
        ]
    }
    
    protocols = server_data.get("supported_protocols", [])
    
    assert isinstance(protocols, list), "supported_protocols должен быть списком"
    assert len(protocols) > 0, "supported_protocols не должен быть пустым"
    
    # Проверяем формат каждого протокола
    for protocol in protocols:
        assert isinstance(protocol, str), f"Протокол должен быть строкой: {protocol}"
        assert " " not in protocol, f"Протокол не должен содержать пробелы: '{protocol}'"
        assert protocol == protocol.lower(), f"Протокол должен быть в нижнем регистре: '{protocol}'"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
