#!/usr/bin/env python3
"""
Скрипт для диагностики состояния WireGuard сервера
Проверяет IP forwarding, iptables правила, конфигурацию WireGuard и сетевые интерфейсы
"""

import sys
import os
import subprocess
import re

# Добавляем путь к проекту
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from core.config import settings
from core.database import get_db
from models.server import Server
from sqlalchemy.orm import Session

def check_ip_forwarding() -> dict:
    """Проверяет состояние IP forwarding"""
    result = {
        "enabled": False,
        "value": None,
        "error": None
    }
    
    try:
        # Проверяем текущее значение
        output = subprocess.check_output(
            ["sysctl", "net.ipv4.ip_forward"],
            stderr=subprocess.PIPE,
            text=True
        ).strip()
        
        match = re.search(r'=\s*(\d+)', output)
        if match:
            value = int(match.group(1))
            result["value"] = value
            result["enabled"] = value == 1
        else:
            result["error"] = "Не удалось распарсить значение"
    except subprocess.CalledProcessError as e:
        result["error"] = f"Ошибка выполнения команды: {e.stderr}"
    except Exception as e:
        result["error"] = f"Неожиданная ошибка: {e}"
    
    return result

def check_sysctl_config() -> dict:
    """Проверяет настройки в /etc/sysctl.conf"""
    result = {
        "configured": False,
        "lines": []
    }
    
    try:
        with open("/etc/sysctl.conf", "r") as f:
            content = f.read()
            
        # Ищем строки с ip_forward
        lines = content.split('\n')
        for i, line in enumerate(lines, 1):
            if "ip_forward" in line:
                result["lines"].append({
                    "line_number": i,
                    "content": line.strip()
                })
                if "=1" in line:
                    result["configured"] = True
    except FileNotFoundError:
        result["error"] = "Файл /etc/sysctl.conf не найден"
    except Exception as e:
        result["error"] = f"Ошибка чтения файла: {e}"
    
    return result

def check_iptables_rules(interface: str = "wg0") -> dict:
    """Проверяет наличие iptables правил"""
    result = {
        "forward_rule": False,
        "masquerade_rule": False,
        "forward_details": None,
        "masquerade_details": None
    }
    
    try:
        # Проверяем правило FORWARD
        try:
            subprocess.check_output(
                ["iptables", "-C", "FORWARD", "-i", interface, "-j", "ACCEPT"],
                stderr=subprocess.PIPE
            )
            result["forward_rule"] = True
        except subprocess.CalledProcessError:
            result["forward_rule"] = False
        
        # Получаем детали правила FORWARD
        try:
            output = subprocess.check_output(
                ["iptables", "-L", "FORWARD", "-n", "-v"],
                stderr=subprocess.PIPE,
                text=True
            )
            result["forward_details"] = output
        except Exception as e:
            result["forward_details"] = f"Ошибка получения деталей: {e}"
        
        # Проверяем правило MASQUERADE
        try:
            output = subprocess.check_output(
                ["iptables", "-t", "nat", "-L", "POSTROUTING", "-n", "-v"],
                stderr=subprocess.PIPE,
                text=True
            )
            result["masquerade_details"] = output
            if "MASQUERADE" in output:
                result["masquerade_rule"] = True
        except Exception as e:
            result["masquerade_details"] = f"Ошибка получения деталей: {e}"
    except Exception as e:
        result["error"] = f"Ошибка проверки iptables: {e}"
    
    return result

def check_wireguard_config(config_path: str = "/etc/wireguard/wg0.conf") -> dict:
    """Проверяет конфигурацию WireGuard"""
    result = {
        "exists": False,
        "has_postup": False,
        "has_postdown": False,
        "has_interface": False,
        "has_listenport": False,
        "interface_name": None,
        "main_interface": None,
        "content": None,
        "error": None
    }
    
    try:
        if not os.path.exists(config_path):
            result["error"] = f"Файл {config_path} не существует"
            return result
        
        result["exists"] = True
        
        with open(config_path, "r") as f:
            content = f.read()
            result["content"] = content
        
        # Проверяем наличие ключевых элементов
        result["has_postup"] = "PostUp" in content
        result["has_postdown"] = "PostDown" in content
        result["has_interface"] = "[Interface]" in content
        result["has_listenport"] = "ListenPort" in content
        
        # Извлекаем имя интерфейса из пути
        match = re.search(r'/(\w+)\.conf$', config_path)
        if match:
            result["interface_name"] = match.group(1)
        
        # Пытаемся определить основной сетевой интерфейс
        try:
            output = subprocess.check_output(
                ["ip", "route", "show", "default"],
                stderr=subprocess.PIPE,
                text=True
            )
            match = re.search(r'dev\s+(\w+)', output)
            if match:
                result["main_interface"] = match.group(1)
        except:
            pass
        
        # Проверяем PostUp/PostDown на наличие правильного интерфейса
        if result["has_postup"]:
            if result["main_interface"]:
                if result["main_interface"] in content:
                    result["postup_interface_correct"] = True
                else:
                    result["postup_interface_correct"] = False
    except Exception as e:
        result["error"] = f"Ошибка чтения конфигурации: {e}"
    
    return result

def check_network_interfaces() -> dict:
    """Проверяет сетевые интерфейсы"""
    result = {
        "interfaces": [],
        "default_interface": None,
        "wireguard_interfaces": []
    }
    
    try:
        # Получаем список интерфейсов
        output = subprocess.check_output(
            ["ip", "link", "show"],
            stderr=subprocess.PIPE,
            text=True
        )
        
        # Парсим интерфейсы
        interface_pattern = r'^\d+:\s+(\w+):'
        for line in output.split('\n'):
            match = re.match(interface_pattern, line)
            if match:
                iface = match.group(1)
                if iface != "lo":  # Пропускаем loopback
                    result["interfaces"].append(iface)
        
        # Определяем интерфейс по умолчанию
        try:
            route_output = subprocess.check_output(
                ["ip", "route", "show", "default"],
                stderr=subprocess.PIPE,
                text=True
            )
            match = re.search(r'dev\s+(\w+)', route_output)
            if match:
                result["default_interface"] = match.group(1)
        except:
            pass
        
        # Ищем WireGuard интерфейсы
        try:
            wg_output = subprocess.check_output(
                ["wg", "show"],
                stderr=subprocess.PIPE,
                text=True
            )
            for line in wg_output.split('\n'):
                if line.startswith('interface:'):
                    match = re.search(r'interface:\s*(\w+)', line)
                    if match:
                        result["wireguard_interfaces"].append(match.group(1))
        except:
            pass
    except Exception as e:
        result["error"] = f"Ошибка проверки интерфейсов: {e}"
    
    return result

def check_wireguard_status(interface: str = "wg0") -> dict:
    """Проверяет статус WireGuard"""
    result = {
        "running": False,
        "peers": [],
        "error": None
    }
    
    try:
        output = subprocess.check_output(
            ["wg", "show", interface],
            stderr=subprocess.PIPE,
            text=True
        )
        
        result["running"] = True
        
        # Парсим пиры
        current_peer = {}
        for line in output.split('\n'):
            if line.startswith('peer:'):
                if current_peer:
                    result["peers"].append(current_peer)
                current_peer = {"public_key": line.split(':')[1].strip()}
            elif line.startswith('  allowed ips:'):
                current_peer["allowed_ips"] = line.split(':')[1].strip()
            elif line.startswith('  endpoint:'):
                current_peer["endpoint"] = line.split(':')[1].strip()
        
        if current_peer:
            result["peers"].append(current_peer)
    except subprocess.CalledProcessError as e:
        if "No such device" in e.stderr.decode():
            result["error"] = f"Интерфейс {interface} не существует или не запущен"
        else:
            result["error"] = f"Ошибка выполнения команды: {e.stderr.decode()}"
    except Exception as e:
        result["error"] = f"Неожиданная ошибка: {e}"
    
    return result

def print_section(title: str):
    """Печатает заголовок секции"""
    print("\n" + "=" * 60)
    print(f"  {title}")
    print("=" * 60)

def main():
    """Основная функция"""
    print("\n" + "=" * 60)
    print("  ДИАГНОСТИКА WIREGUARD СЕРВЕРА")
    print("=" * 60)
    
    # 1. Проверка IP forwarding
    print_section("1. IP Forwarding")
    ip_forward = check_ip_forwarding()
    if ip_forward.get("error"):
        print(f"❌ Ошибка: {ip_forward['error']}")
    else:
        status = "✅ Включен" if ip_forward["enabled"] else "❌ Отключен"
        print(f"{status} (значение: {ip_forward['value']})")
    
    sysctl_config = check_sysctl_config()
    if sysctl_config.get("error"):
        print(f"⚠️  {sysctl_config['error']}")
    else:
        if sysctl_config["configured"]:
            print("✅ Настроен в /etc/sysctl.conf")
            for line_info in sysctl_config["lines"]:
                print(f"   Строка {line_info['line_number']}: {line_info['content']}")
        else:
            print("⚠️  Не настроен в /etc/sysctl.conf")
    
    # 2. Проверка iptables правил
    print_section("2. iptables Правила")
    iptables = check_iptables_rules()
    forward_status = "✅ Настроено" if iptables["forward_rule"] else "❌ Отсутствует"
    print(f"FORWARD правило: {forward_status}")
    if iptables.get("forward_details"):
        print("   Детали:")
        for line in iptables["forward_details"].split('\n')[:5]:
            if line.strip():
                print(f"   {line}")
    
    masq_status = "✅ Настроено" if iptables["masquerade_rule"] else "❌ Отсутствует"
    print(f"\nMASQUERADE правило: {masq_status}")
    if iptables.get("masquerade_details"):
        print("   Детали:")
        for line in iptables["masquerade_details"].split('\n')[:5]:
            if line.strip():
                print(f"   {line}")
    
    # 3. Проверка конфигурации WireGuard
    print_section("3. Конфигурация WireGuard")
    wg_config = check_wireguard_config()
    if wg_config.get("error"):
        print(f"❌ {wg_config['error']}")
    else:
        if wg_config["exists"]:
            print(f"✅ Файл существует: /etc/wireguard/wg0.conf")
            print(f"   PostUp: {'✅' if wg_config['has_postup'] else '❌'}")
            print(f"   PostDown: {'✅' if wg_config['has_postdown'] else '❌'}")
            print(f"   [Interface]: {'✅' if wg_config['has_interface'] else '❌'}")
            print(f"   ListenPort: {'✅' if wg_config['has_listenport'] else '❌'}")
            if wg_config.get("main_interface"):
                print(f"   Основной интерфейс: {wg_config['main_interface']}")
                if wg_config.get("postup_interface_correct"):
                    print(f"   ✅ PostUp использует правильный интерфейс")
                else:
                    print(f"   ⚠️  PostUp может использовать неправильный интерфейс")
        else:
            print("❌ Конфигурация не найдена")
    
    # 4. Проверка сетевых интерфейсов
    print_section("4. Сетевые Интерфейсы")
    interfaces = check_network_interfaces()
    if interfaces.get("error"):
        print(f"❌ {interfaces['error']}")
    else:
        print(f"Найдено интерфейсов: {len(interfaces['interfaces'])}")
        for iface in interfaces["interfaces"]:
            marker = " (по умолчанию)" if iface == interfaces.get("default_interface") else ""
            print(f"   - {iface}{marker}")
        
        if interfaces.get("wireguard_interfaces"):
            print(f"\nWireGuard интерфейсы:")
            for wg_iface in interfaces["wireguard_interfaces"]:
                print(f"   - {wg_iface}")
    
    # 5. Проверка статуса WireGuard
    print_section("5. Статус WireGuard")
    wg_status = check_wireguard_status()
    if wg_status.get("error"):
        print(f"❌ {wg_status['error']}")
    else:
        if wg_status["running"]:
            print("✅ WireGuard запущен")
            print(f"   Найдено пиров: {len(wg_status['peers'])}")
            for i, peer in enumerate(wg_status["peers"], 1):
                print(f"   Пир {i}:")
                if peer.get("public_key"):
                    print(f"      Публичный ключ: {peer['public_key'][:20]}...")
                if peer.get("allowed_ips"):
                    print(f"      Allowed IPs: {peer['allowed_ips']}")
                if peer.get("endpoint"):
                    print(f"      Endpoint: {peer['endpoint']}")
        else:
            print("❌ WireGuard не запущен")
    
    # Итоговые рекомендации
    print_section("РЕКОМЕНДАЦИИ")
    issues = []
    
    if not ip_forward["enabled"]:
        issues.append("Включить IP forwarding: sysctl -w net.ipv4.ip_forward=1")
        issues.append("Добавить в /etc/sysctl.conf: net.ipv4.ip_forward=1")
    
    if not iptables["forward_rule"]:
        issues.append(f"Добавить правило FORWARD: iptables -A FORWARD -i wg0 -j ACCEPT")
    
    if not iptables["masquerade_rule"]:
        main_iface = wg_config.get("main_interface") or "eth0"
        issues.append(f"Добавить правило MASQUERADE: iptables -t nat -A POSTROUTING -o {main_iface} -j MASQUERADE")
    
    if not wg_config.get("has_postup") or not wg_config.get("has_postdown"):
        issues.append("Добавить PostUp и PostDown в конфигурацию WireGuard")
    
    if issues:
        print("⚠️  Найдены проблемы:")
        for i, issue in enumerate(issues, 1):
            print(f"   {i}. {issue}")
    else:
        print("✅ Все проверки пройдены успешно!")
    
    print("\n" + "=" * 60 + "\n")

if __name__ == "__main__":
    main()

