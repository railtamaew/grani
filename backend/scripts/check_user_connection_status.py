#!/usr/bin/env python3
"""
Проверка статуса подключения пользователя
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy.orm import Session
from sqlalchemy import text
from core.database import SessionLocal
from datetime import datetime

def print_status(message: str, status: str = "INFO"):
    color_map = {
        "INFO": "\033[0;34m",    # Blue
        "SUCCESS": "\033[0;32m", # Green
        "WARNING": "\033[1;33m", # Yellow
        "ERROR": "\033[0;31m",   # Red
        "NC": "\033[0m"          # No Color
    }
    print(f"{color_map.get(status, 'INFO')}[{status}]{color_map['NC']} {message}")

def check_user_connection_status(email: str = None, user_id: int = None):
    """Проверяет статус подключения пользователя"""
    db: Session = SessionLocal()
    
    try:
        print("\n" + "=" * 80)
        print("  ПРОВЕРКА СТАТУСА ПОДКЛЮЧЕНИЯ ПОЛЬЗОВАТЕЛЯ")
        print("=" * 80 + "\n")
        
        # Получаем пользователя через прямой SQL
        if email:
            result = db.execute(text("SELECT id, email, created_at, last_login_at, last_seen_at FROM users WHERE email = :email"), {"email": email})
            user_row = result.fetchone()
            if not user_row:
                print_status(f"Пользователь с email {email} не найден", "ERROR")
                return
            user_id = user_row[0]
            user_email = user_row[1]
            user_created = user_row[2]
            user_last_login = user_row[3]
            user_last_seen = user_row[4]
        elif user_id:
            result = db.execute(text("SELECT id, email, created_at, last_login_at, last_seen_at FROM users WHERE id = :user_id"), {"user_id": user_id})
            user_row = result.fetchone()
            if not user_row:
                print_status(f"Пользователь с ID {user_id} не найден", "ERROR")
                return
            user_id = user_row[0]
            user_email = user_row[1]
            user_created = user_row[2]
            user_last_login = user_row[3]
            user_last_seen = user_row[4]
        else:
            print_status("Укажите email или user_id", "ERROR")
            return
        
        print_status(f"Пользователь: {user_email} (ID: {user_id})", "SUCCESS")
        print(f"   Создан: {user_created}")
        print(f"   Последний вход: {user_last_login or 'Никогда'}")
        print(f"   Последний раз онлайн: {user_last_seen or 'Никогда'}")
        
        # Получаем устройства пользователя через прямой SQL
        devices_result = db.execute(text("""
            SELECT id, device_id, device_name, device_type, platform, 
                   is_active, current_server_id, ip_address, last_connected, created_at
            FROM devices 
            WHERE user_id = :user_id
        """), {"user_id": user_id})
        devices = devices_result.fetchall()
        print(f"\n📱 Устройств: {len(devices)}")
        
        if not devices:
            print_status("У пользователя нет зарегистрированных устройств", "WARNING")
            return
        
        # Проверяем каждое устройство
        for i, device in enumerate(devices, 1):
            device_id_db = device[0]
            device_id = device[1]
            device_name = device[2]
            device_type = device[3]
            platform = device[4]
            is_active = device[5]
            current_server_id = device[6]
            ip_address = device[7]
            last_connected = device[8]
            created_at = device[9]
            
            print(f"\n{'─' * 80}")
            print(f"Устройство #{i}: {device_name or device_id}")
            print(f"   Device ID: {device_id}")
            print(f"   Тип: {device_type or platform or 'Неизвестно'}")
            print(f"   IP в VPN: {ip_address or 'Не назначен'}")
            print(f"   Создано: {created_at}")
            
            # Статус подключения
            is_connected = is_active and current_server_id is not None
            
            if is_connected:
                print_status("   Статус: ПОДКЛЮЧЕНО", "SUCCESS")
                print(f"   Последнее подключение: {last_connected or 'Неизвестно'}")
                
                # Получаем информацию о сервере через прямой SQL
                server_result = db.execute(text("SELECT id, name, country, city, ip_address FROM servers WHERE id = :server_id"), {"server_id": current_server_id})
                server_row = server_result.fetchone()
                if server_row:
                    print(f"   Сервер: {server_row[1]} ({server_row[2]})")
                    print(f"   IP сервера: {server_row[4]}")
                else:
                    print_status("   Сервер не найден в БД", "WARNING")
            else:
                print_status("   Статус: НЕ ПОДКЛЮЧЕНО", "WARNING")
                if last_connected:
                    print(f"   Последнее подключение: {last_connected}")
        
        # Получаем последние логи подключений через прямой SQL
        print(f"\n{'─' * 80}")
        print("📊 Последние подключения (логи):")
        
        # Получаем последние 10 подключений
        recent_logs_result = db.execute(text("""
            SELECT cl.id, cl.server_id, cl.connection_type, cl.connected_at, cl.disconnected_at,
                   s.name, s.country
            FROM connection_logs cl
            LEFT JOIN servers s ON cl.server_id = s.id
            WHERE cl.user_id = :user_id
            ORDER BY cl.connected_at DESC
            LIMIT 10
        """), {"user_id": user_id})
        recent_logs = recent_logs_result.fetchall()
        
        if recent_logs:
            for log in recent_logs:
                server_name = log[5] if log[5] else f"Server {log[1]}"
                status_icon = "🔌" if log[2] == "connect" else "🔌❌"
                connected_at = log[3]
                disconnected_at = log[4]
                
                print(f"   {status_icon} {connected_at.strftime('%Y-%m-%d %H:%M:%S')} - {server_name}")
                if disconnected_at:
                    duration = (disconnected_at - connected_at).total_seconds()
                    print(f"      Отключено: {disconnected_at.strftime('%Y-%m-%d %H:%M:%S')} (длительность: {int(duration)} сек)")
        else:
            print_status("   Нет записей о подключениях", "WARNING")
        
        # Статистика
        print(f"\n{'─' * 80}")
        print("📈 Статистика:")
        
        # Подсчитываем активные подключения
        active_devices = [d for d in devices if d[5] and d[6] is not None]  # is_active and current_server_id
        print(f"   Активных подключений: {len(active_devices)}")
        
        # Подсчитываем общее количество подключений
        total_connections_result = db.execute(text("""
            SELECT COUNT(*) FROM connection_logs 
            WHERE user_id = :user_id AND connection_type = 'connect'
        """), {"user_id": user_id})
        total_connections = total_connections_result.scalar()
        print(f"   Всего подключений: {total_connections}")
        
        # Первое подключение
        first_connection_result = db.execute(text("""
            SELECT connected_at FROM connection_logs 
            WHERE user_id = :user_id 
            ORDER BY connected_at ASC 
            LIMIT 1
        """), {"user_id": user_id})
        first_connection = first_connection_result.fetchone()
        
        if first_connection:
            print(f"   Первое подключение: {first_connection[0].strftime('%Y-%m-%d %H:%M:%S')}")
        
        print("\n" + "=" * 80)
        
    except Exception as e:
        print_status(f"Ошибка: {e}", "ERROR")
        import traceback
        traceback.print_exc()
    finally:
        db.close()

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="Проверка статуса подключения пользователя")
    parser.add_argument("--email", type=str, help="Email пользователя")
    parser.add_argument("--user-id", type=int, help="ID пользователя")
    
    args = parser.parse_args()
    
    if not args.email and not args.user_id:
        email = os.getenv("TEST_EMAIL")
        if not email:
            print("Укажите --email, --user-id или TEST_EMAIL")
            sys.exit(1)
        check_user_connection_status(email=email)
    else:
        check_user_connection_status(email=args.email, user_id=args.user_id)

