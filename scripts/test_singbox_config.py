#!/usr/bin/env python3
"""
Скрипт для тестирования sing-box конфигураций перед сборкой APK

Генерирует конфигурации в том же формате, что и мобильное приложение,
и валидирует их через sing-box CLI или Docker.

Использование:
    python3 scripts/test_singbox_config.py                    # Все тесты
    python3 scripts/test_singbox_config.py --scenario vless   # Только VLESS
    python3 scripts/test_singbox_config.py --validate-only     # Только валидация существующей конфигурации
    python3 scripts/test_singbox_config.py --generate          # Только генерация без валидации
"""

import json
import subprocess
import sys
import argparse
from pathlib import Path
from typing import Dict, Any, Tuple, Optional

# Путь к sing-box (если установлен) или используем Docker
SINGBOX_CMD = "sing-box"  # или "docker run --rm -i ghcr.io/sagernet/sing-box:latest"
USE_DOCKER = False


def generate_vless_reality_config(
    server: str = "45.12.132.94",
    port: int = 443,
    uuid: str = "caa49393-5291-4534-aa6e-a0f63098224e",
    sni: str = "www.google.com",
    public_key: str = "Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY",
    short_id: str = "822c3e48",
    fingerprint: str = "chrome",
) -> Dict[str, Any]:
    """
    Генерирует sing-box конфигурацию в ПРАВИЛЬНОМ формате для sing-box.
    
    ВАЖНО: sing-box НЕ использует формат Xray с settings.vnext!
    Вместо этого параметры должны быть на верхнем уровне outbound.
    """
    
    config = {
        "log": {
            "level": "warn"
        },
        "dns": {
            "servers": [
                {"address": "8.8.8.8"},
                {"address": "8.8.4.4"},
                {"address": "1.1.1.1"}
            ]
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "mtu": 1500,
                "inet4_address": ["172.19.0.1/30"],
                "auto_route": True,
                "strict_route": False
                # ВАЖНО: НЕТ поля dns_address - DNS указывается только в секции dns
                # ВАЖНО: НЕТ поля inet4_route - используем auto_route
            }
        ],
        "outbounds": [
            {
                "tag": "proxy",
                "type": "vless",
                # ✅ ПРАВИЛЬНЫЙ формат для sing-box (БЕЗ settings.vnext)
                "server": server,
                "server_port": port,
                "uuid": uuid,
                "flow": "",
                "encryption": "none",
                "tls": {
                    "enabled": True,
                    "server_name": sni,
                    "reality": {
                        "public_key": public_key,
                        "short_id": short_id
                    },
                    "utls": {
                        "enabled": True,
                        "fingerprint": fingerprint
                    }
                },
                "transport": {
                    "type": "tcp"
                }
            },
            {
                "type": "direct",
                "tag": "direct"
            }
        ],
        "route": {
            "rules": [
                {
                    "type": "field",
                    "inbound_tag": ["tun-in"],
                    "outbound": "proxy"
                },
                {
                    "type": "field",
                    "outbound": "proxy"
                }
            ]
        }
    }
    
    return config


def generate_vless_tls_config(
    server: str = "45.12.132.94",
    port: int = 443,
    uuid: str = "test-uuid-1234",
    sni: str = "example.com",
) -> Dict[str, Any]:
    """Генерирует VLESS + TLS конфигурацию"""
    
    config = {
        "log": {"level": "warn"},
        "dns": {
            "servers": [
                {"address": "8.8.8.8"},
                {"address": "8.8.4.4"}
            ]
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "mtu": 1500,
                "inet4_address": ["172.19.0.1/30"],
                "auto_route": True,
                "strict_route": False
            }
        ],
        "outbounds": [
            {
                "tag": "proxy",
                "type": "vless",
                "server": server,
                "server_port": port,
                "uuid": uuid,
                "flow": "",
                "encryption": "none",
                "tls": {
                    "enabled": True,
                    "server_name": sni,
                    "insecure": False
                },
                "transport": {
                    "type": "tcp"
                }
            },
            {
                "type": "direct",
                "tag": "direct"
            }
        ],
        "route": {
            "rules": [
                {"type": "field", "inbound_tag": ["tun-in"], "outbound": "proxy"},
                {"type": "field", "outbound": "proxy"}
            ]
        }
    }
    
    return config


def generate_vmess_config(
    server: str = "45.12.132.94",
    port: int = 443,
    uuid: str = "test-uuid-5678",
) -> Dict[str, Any]:
    """Генерирует VMESS конфигурацию"""
    
    config = {
        "log": {"level": "warn"},
        "dns": {
            "servers": [
                {"address": "8.8.8.8"}
            ]
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "mtu": 1500,
                "inet4_address": ["172.19.0.1/30"],
                "auto_route": True,
                "strict_route": False
            }
        ],
        "outbounds": [
            {
                "tag": "proxy",
                "type": "vmess",
                "server": server,
                "server_port": port,
                "uuid": uuid,
                "alter_id": 0
            },
            {
                "type": "direct",
                "tag": "direct"
            }
        ],
        "route": {
            "rules": [
                {"type": "field", "inbound_tag": ["tun-in"], "outbound": "proxy"},
                {"type": "field", "outbound": "proxy"}
            ]
        }
    }
    
    return config


def validate_config(config: Dict[str, Any], use_docker: bool = False) -> Tuple[bool, str]:
    """
    Валидирует конфигурацию через sing-box check
    
    Returns:
        (is_valid, message)
    """
    try:
        # Преобразуем в JSON
        config_json = json.dumps(config, indent=2)
        
        if use_docker:
            # Используем Docker
            cmd = [
                "docker", "run", "--rm", "-i",
                "ghcr.io/sagernet/sing-box:latest",
                "sing-box", "check", "-c", "-"
            ]
        else:
            # Используем локальный sing-box
            cmd = [SINGBOX_CMD, "check", "-c", "-"]
        
        # Запускаем sing-box check
        result = subprocess.run(
            cmd,
            input=config_json.encode('utf-8'),
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode == 0:
            return True, "✅ Конфигурация валидна"
        else:
            error_msg = result.stderr.strip() or result.stdout.strip()
            return False, f"❌ Ошибка валидации:\n{error_msg}"
            
    except FileNotFoundError:
        if use_docker:
            return False, "❌ Docker не найден. Установите Docker или sing-box CLI"
        return False, "❌ sing-box не найден. Установите sing-box или используйте --docker"
    except subprocess.TimeoutExpired:
        return False, "❌ Таймаут валидации (более 10 секунд)"
    except Exception as e:
        return False, f"❌ Ошибка: {e}"


def validate_format(config: Dict[str, Any]) -> Tuple[bool, list[str]]:
    """
    Валидирует формат конфигурации без запуска sing-box.
    Проверяет, что формат соответствует требованиям sing-box.
    
    Returns:
        (is_valid, list_of_errors)
    """
    errors = []
    
    # Проверяем наличие обязательных секций
    required_sections = ["log", "dns", "inbounds", "outbounds", "route"]
    for section in required_sections:
        if section not in config:
            errors.append(f"❌ Отсутствует обязательная секция: {section}")
    
    # Проверяем формат DNS
    if "dns" in config:
        dns_servers = config["dns"].get("servers", [])
        for i, server in enumerate(dns_servers):
            if isinstance(server, str):
                errors.append(f"❌ DNS сервер {i} должен быть объектом {{'address': '...'}}, а не строкой")
            elif not isinstance(server, dict) or "address" not in server:
                errors.append(f"❌ DNS сервер {i} должен иметь формат {{'address': '...'}}")
    
    # Проверяем формат inbounds (TUN)
    if "inbounds" in config and len(config["inbounds"]) > 0:
        tun_inbound = config["inbounds"][0]
        if tun_inbound.get("type") == "tun":
            # Проверяем, что НЕТ недопустимых полей
            forbidden_fields = ["dns_address", "inet4_route", "settings"]
            for field in forbidden_fields:
                if field in tun_inbound:
                    errors.append(f"❌ TUN inbound содержит недопустимое поле: {field}")
    
    # Проверяем формат outbounds
    if "outbounds" in config and len(config["outbounds"]) > 0:
        proxy_outbound = config["outbounds"][0]
        
        # Проверяем, что НЕТ поля settings (старый формат Xray)
        if "settings" in proxy_outbound:
            errors.append("❌ Outbound содержит поле 'settings' (старый формат Xray). "
                        "Используйте 'server', 'server_port', 'uuid' напрямую")
        
        # Проверяем наличие обязательных полей для VLESS
        if proxy_outbound.get("type") == "vless":
            required_fields = ["server", "server_port", "uuid"]
            for field in required_fields:
                if field not in proxy_outbound:
                    errors.append(f"❌ VLESS outbound должен содержать поле: {field}")
        
        # Проверяем формат TLS
        if "tls" in proxy_outbound:
            tls = proxy_outbound["tls"]
            if not isinstance(tls, dict):
                errors.append("❌ Поле 'tls' должно быть объектом")
            elif "enabled" not in tls:
                errors.append("❌ Поле 'tls' должно содержать 'enabled'")
            
            # Проверяем формат REALITY
            if "reality" in tls:
                reality = tls["reality"]
                if not isinstance(reality, dict):
                    errors.append("❌ Поле 'tls.reality' должно быть объектом")
                else:
                    if "public_key" not in reality:
                        errors.append("❌ Поле 'tls.reality' должно содержать 'public_key'")
                    if "short_id" not in reality:
                        errors.append("❌ Поле 'tls.reality' должно содержать 'short_id'")
        
        # Проверяем, что НЕТ stream_settings (старый формат)
        if "stream_settings" in proxy_outbound:
            errors.append("❌ Outbound содержит поле 'stream_settings' (старый формат). "
                        "Используйте 'tls' и 'transport' напрямую")
    
    return len(errors) == 0, errors


def test_scenarios(scenario_filter: Optional[str] = None, validate_only: bool = False, 
                   use_docker: bool = False) -> bool:
    """Тестирует различные сценарии"""
    
    scenarios = [
        {
            "name": "VLESS + REALITY (TCP)",
            "config": generate_vless_reality_config()
        },
        {
            "name": "VLESS + TLS (TCP)",
            "config": generate_vless_tls_config()
        },
        {
            "name": "VMESS",
            "config": generate_vmess_config()
        },
    ]
    
    # Фильтруем сценарии, если указан фильтр
    if scenario_filter:
        scenarios = [s for s in scenarios if scenario_filter.lower() in s["name"].lower()]
        if not scenarios:
            print(f"❌ Сценарий '{scenario_filter}' не найден")
            return False
    
    print("🧪 Тестирование sing-box конфигураций...\n")
    
    all_passed = True
    
    for scenario in scenarios:
        print(f"📋 Тест: {scenario['name']}")
        print("-" * 60)
        
        config = scenario['config']
        
        # 1. Проверка формата (быстрая проверка без sing-box)
        is_format_valid, format_errors = validate_format(config)
        if not is_format_valid:
            print("   ❌ Ошибки формата:")
            for error in format_errors:
                print(f"      {error}")
            all_passed = False
        else:
            print("   ✅ Формат конфигурации корректен")
        
        # 2. Валидация через sing-box (если не только проверка формата)
        if not validate_only:
            is_valid, message = validate_config(config, use_docker=use_docker)
            print(f"   {message}")
            
            if not is_valid:
                all_passed = False
                # Показываем конфигурацию при ошибке
                print(f"\n   Конфигурация:\n{json.dumps(config, indent=2)}\n")
        
        print()
    
    return all_passed


def main():
    parser = argparse.ArgumentParser(
        description="Тестирование sing-box конфигураций перед сборкой APK"
    )
    parser.add_argument(
        "--scenario",
        type=str,
        help="Тестировать только указанный сценарий (vless, vmess, reality, tls)"
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Только проверка формата без запуска sing-box"
    )
    parser.add_argument(
        "--docker",
        action="store_true",
        help="Использовать Docker для валидации (если sing-box не установлен)"
    )
    parser.add_argument(
        "--generate",
        action="store_true",
        help="Только генерация конфигураций без валидации"
    )
    parser.add_argument(
        "--output",
        type=str,
        help="Сохранить конфигурацию в файл (JSON)"
    )
    
    args = parser.parse_args()
    
    # Если только генерация
    if args.generate:
        config = generate_vless_reality_config()
        config_json = json.dumps(config, indent=2)
        
        if args.output:
            with open(args.output, 'w') as f:
                f.write(config_json)
            print(f"✅ Конфигурация сохранена в {args.output}")
        else:
            print(config_json)
        return 0
    
    # Запускаем тесты
    success = test_scenarios(
        scenario_filter=args.scenario,
        validate_only=args.validate_only,
        use_docker=args.docker
    )
    
    if success:
        print("✅ Все тесты пройдены!")
        return 0
    else:
        print("❌ Некоторые тесты не пройдены")
        return 1


if __name__ == "__main__":
    sys.exit(main())
