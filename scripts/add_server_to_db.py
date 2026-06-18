#!/usr/bin/env python3
"""
Скрипт для добавления VPN сервера в базу данных через API
Использование: python add_server_to_db.py [--server-id SERVER_ID]
"""

import os
import requests
import json
import sys
import argparse
from typing import Optional

# Конфигурация: API_URL или --api-url.
# SSH пароль НЕ хранить в репозитории: используйте --ssh-password или env SSH_PASSWORD.
API_BASE_URL = os.getenv("API_URL", "https://api.granilink.com")
ADMIN_TOKEN = ""  # Получите токен через /api/auth/login

def get_auth_token(email: str, password: str) -> str:
    """Получение токена авторизации"""
    response = requests.post(
        f"{API_BASE_URL}/api/auth/login",
        json={"email": email, "password": password}
    )
    if response.status_code == 200:
        return response.json().get("access_token")
    else:
        raise Exception(f"Ошибка авторизации: {response.text}")

def create_server(token: str, server_data: dict) -> dict:
    """Создание сервера через API"""
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }
    
    response = requests.post(
        f"{API_BASE_URL}/api/servers/",
        headers=headers,
        json=server_data
    )
    
    if response.status_code == 200 or response.status_code == 201:
        return response.json()
    else:
        raise Exception(f"Ошибка создания сервера: {response.status_code} - {response.text}")

def test_connection(token: str, server_id: int) -> dict:
    """Тестирование SSH подключения к серверу"""
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }
    
    response = requests.post(
        f"{API_BASE_URL}/api/servers/{server_id}/test-connection",
        headers=headers
    )
    
    if response.status_code == 200:
        return response.json()
    else:
        raise Exception(f"Ошибка тестирования подключения: {response.status_code} - {response.text}")

def install_wireguard(token: str, server_id: int) -> dict:
    """Установка WireGuard на сервере"""
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }
    
    response = requests.post(
        f"{API_BASE_URL}/api/servers/{server_id}/install-wireguard",
        headers=headers
    )
    
    if response.status_code == 200:
        return response.json()
    else:
        raise Exception(f"Ошибка установки WireGuard: {response.status_code} - {response.text}")

def main():
    parser = argparse.ArgumentParser(description="Добавление VPN сервера в БД")
    parser.add_argument("--email", help="Email администратора", default="admin@example.com")
    parser.add_argument("--password", help="Пароль администратора", default="")
    parser.add_argument("--token", help="Токен авторизации (если уже есть)")
    parser.add_argument("--api-url", help="URL API", default=API_BASE_URL)
    parser.add_argument("--ssh-password", help="SSH пароль (или env SSH_PASSWORD)", default=os.getenv("SSH_PASSWORD", ""))
    parser.add_argument("--test-connection", action="store_true", help="Протестировать подключение после создания")
    parser.add_argument("--install-wg", action="store_true", help="Установить WireGuard после создания")
    
    args = parser.parse_args()
    global API_BASE_URL
    API_BASE_URL = args.api_url
    
    # Данные сервера для добавления
    server_data = {
        "name": "HU-BUD-01",
        "ip_address": "45.12.132.94",
        "country": "HU",
        "city": "Budapest",
        "ssh_host": "45.12.132.94",
        "ssh_port": 22,
        "ssh_user": "root",
        "wireguard_port": 51820,
        "supported_protocols": ["wireguard"],
        "is_local": False
    }
    if args.ssh_password:
        server_data["ssh_password"] = args.ssh_password
    
    print("=" * 50)
    print("Добавление VPN сервера в базу данных")
    print("=" * 50)
    print(f"Сервер: {server_data['name']}")
    print(f"IP: {server_data['ip_address']}")
    print(f"Страна: {server_data['country']}")
    print()
    
    # Получение токена
    if args.token:
        token = args.token
        print("✅ Использован предоставленный токен")
    else:
        print("Получение токена авторизации...")
        if not args.password:
            print("❌ Ошибка: требуется пароль или токен")
            print("Использование: python add_server_to_db.py --email admin@example.com --password PASSWORD")
            sys.exit(1)
        try:
            token = get_auth_token(args.email, args.password)
            print("✅ Токен получен")
        except Exception as e:
            print(f"❌ Ошибка получения токена: {e}")
            sys.exit(1)
    
    # Создание сервера
    print()
    print("Создание сервера в БД...")
    try:
        result = create_server(token, server_data)
        server_id = result.get("server_id")
        print(f"✅ Сервер создан с ID: {server_id}")
        print(f"   Название: {result.get('server', {}).get('name')}")
        print(f"   IP: {result.get('server', {}).get('ip_address')}")
    except Exception as e:
        print(f"❌ Ошибка создания сервера: {e}")
        sys.exit(1)
    
    # Тестирование подключения
    if args.test_connection:
        print()
        print("Тестирование SSH подключения...")
        try:
            test_result = test_connection(token, server_id)
            if test_result.get("connected"):
                print("✅ SSH подключение работает")
            else:
                print("⚠️  SSH подключение не работает")
                print(f"   Сообщение: {test_result.get('message')}")
            # Повторный вызов намеренно убран: достаточно одного теста.
        except Exception as e:
            print(f"⚠️  Ошибка тестирования подключения: {e}")
    
    # Установка WireGuard
    if args.install_wg:
        print()
        print("Установка WireGuard на сервере...")
        try:
            install_result = install_wireguard(token, server_id)
            if install_result.get("installed"):
                print("✅ WireGuard установлен")
                if install_result.get("public_key"):
                    print(f"   Public Key: {install_result.get('public_key')}")
            else:
                print("⚠️  WireGuard не установлен")
        except Exception as e:
            print(f"⚠️  Ошибка установки WireGuard: {e}")
    
    print()
    print("=" * 50)
    print("Готово!")
    print("=" * 50)
    print(f"Server ID: {server_id}")
    print(f"API URL: {API_BASE_URL}")

if __name__ == "__main__":
    main()

