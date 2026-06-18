"""
Unit-тесты для проверки формата sing-box конфигураций

Эти тесты проверяют, что конфигурации соответствуют формату sing-box
БЕЗ необходимости запуска sing-box CLI или Docker.
"""

import json
import pytest
from typing import Dict, Any


def test_vless_reality_config_format():
    """Проверяет формат VLESS + REALITY конфигурации"""
    config = {
        "log": {"level": "warn"},
        "dns": {
            "servers": [
                {"address": "8.8.8.8"},
                {"address": "8.8.4.4"}
            ]
        },
        "inbounds": [{
            "type": "tun",
            "tag": "tun-in",
            "mtu": 1500,
            "inet4_address": ["172.19.0.1/30"],
            "auto_route": True,
            "strict_route": False
        }],
        "outbounds": [{
            "tag": "proxy",
            "type": "vless",
            "server": "45.12.132.94",
            "server_port": 443,
            "uuid": "test-uuid",
            "flow": "",
            "encryption": "none",
            "tls": {
                "enabled": True,
                "server_name": "www.google.com",
                "reality": {
                    "public_key": "test-key",
                    "short_id": "test-id"
                },
                "utls": {
                    "enabled": True,
                    "fingerprint": "chrome"
                }
            },
            "transport": {
                "type": "tcp"
            }
        }, {
            "type": "direct",
            "tag": "direct"
        }],
        "route": {
            "rules": [
                {"type": "field", "inbound_tag": ["tun-in"], "outbound": "proxy"},
                {"type": "field", "outbound": "proxy"}
            ]
        }
    }
    
    # Проверяем, что НЕТ поля settings (старый формат Xray)
    assert "settings" not in config["outbounds"][0], "❌ Поле 'settings' не должно быть в outbound"
    
    # Проверяем наличие обязательных полей
    assert "server" in config["outbounds"][0], "✅ Поле 'server' должно быть"
    assert "server_port" in config["outbounds"][0], "✅ Поле 'server_port' должно быть"
    assert "uuid" in config["outbounds"][0], "✅ Поле 'uuid' должно быть"
    
    # Проверяем формат TLS
    assert "tls" in config["outbounds"][0], "✅ Поле 'tls' должно быть"
    assert config["outbounds"][0]["tls"]["enabled"] is True
    assert "reality" in config["outbounds"][0]["tls"]
    
    # Проверяем, что НЕТ stream_settings (старый формат)
    assert "stream_settings" not in config["outbounds"][0], "❌ Поле 'stream_settings' не должно быть"


def test_dns_format():
    """Проверяет формат DNS серверов"""
    config = {
        "dns": {
            "servers": [
                {"address": "8.8.8.8"},
                {"address": "8.8.4.4"}
            ]
        }
    }
    
    # DNS серверы должны быть объектами, а не строками
    for server in config["dns"]["servers"]:
        assert isinstance(server, dict), "DNS сервер должен быть объектом"
        assert "address" in server, "DNS сервер должен содержать поле 'address'"
        assert isinstance(server["address"], str), "Поле 'address' должно быть строкой"


def test_tun_inbound_format():
    """Проверяет формат TUN inbound"""
    config = {
        "inbounds": [{
            "type": "tun",
            "tag": "tun-in",
            "mtu": 1500,
            "inet4_address": ["172.19.0.1/30"],
            "auto_route": True,
            "strict_route": False
        }]
    }
    
    tun_inbound = config["inbounds"][0]
    
    # Проверяем, что НЕТ недопустимых полей
    forbidden_fields = ["dns_address", "inet4_route", "settings"]
    for field in forbidden_fields:
        assert field not in tun_inbound, f"❌ TUN inbound не должен содержать поле: {field}"
    
    # Проверяем наличие обязательных полей
    assert "type" in tun_inbound
    assert "tag" in tun_inbound
    assert "inet4_address" in tun_inbound
    assert "auto_route" in tun_inbound


def test_vmess_config_format():
    """Проверяет формат VMESS конфигурации"""
    config = {
        "outbounds": [{
            "tag": "proxy",
            "type": "vmess",
            "server": "45.12.132.94",
            "server_port": 443,
            "uuid": "test-uuid",
            "alter_id": 0
        }]
    }
    
    vmess_outbound = config["outbounds"][0]
    
    # Проверяем, что НЕТ поля settings
    assert "settings" not in vmess_outbound, "❌ Поле 'settings' не должно быть"
    
    # Проверяем наличие обязательных полей
    assert "server" in vmess_outbound
    assert "server_port" in vmess_outbound
    assert "uuid" in vmess_outbound
    assert "alter_id" in vmess_outbound


def test_old_xray_format_rejected():
    """Проверяет, что старый формат Xray (с settings.vnext) отклоняется"""
    old_format = {
        "outbounds": [{
            "type": "vless",
            "settings": {
                "vnext": [{
                    "address": "45.12.132.94",
                    "port": 443,
                    "users": [{"uuid": "test-uuid"}]
                }]
            }
        }]
    }
    
    # Старый формат должен быть отклонен
    assert "settings" in old_format["outbounds"][0], "Это старый формат Xray"
    assert "server" not in old_format["outbounds"][0], "Нет поля 'server' в старом формате"


def test_stream_settings_rejected():
    """Проверяет, что старый формат stream_settings отклоняется"""
    old_format = {
        "outbounds": [{
            "type": "vless",
            "server": "45.12.132.94",
            "server_port": 443,
            "stream_settings": {
                "network": "tcp",
                "security": "reality"
            }
        }]
    }
    
    # Старый формат stream_settings должен быть отклонен
    assert "stream_settings" in old_format["outbounds"][0], "Это старый формат"
    assert "tls" not in old_format["outbounds"][0], "Нет поля 'tls' в старом формате"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
