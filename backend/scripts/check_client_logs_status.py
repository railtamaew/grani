#!/usr/bin/env python3
"""
Скрипт для проверки статуса системы логирования клиентов
Проверяет:
- Зарегистрировано ли устройство
- Есть ли логи в базе данных
- Работает ли endpoint /api/vpn/logs/send
"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import text
from core.database import engine
from datetime import datetime, timedelta

def check_logging_system(email: str, device_id: str = None):
    """Проверяет статус системы логирования для пользователя"""
    with engine.connect() as conn:
        # 1. Находим пользователя
        user_result = conn.execute(
            text("SELECT id, email FROM users WHERE email = :email"),
            {"email": email}
        ).fetchone()
        
        if not user_result:
            print(f'❌ Пользователь не найден: {email}')
            return
        
        user_id = user_result[0]
        print(f'✅ Пользователь найден: ID={user_id}, email={user_result[1]}\n')
        
        # 2. Проверяем устройства пользователя
        devices_result = conn.execute(
            text("""
                SELECT id, device_id, platform, created_at, device_name, device_type, 
                       current_server_id, last_connected
                FROM devices
                WHERE user_id = :user_id
                ORDER BY created_at DESC
            """),
            {"user_id": user_id}
        ).fetchall()
        
        if not devices_result:
            print('⚠️  У пользователя нет зарегистрированных устройств')
            print('   Это может быть причиной ошибки 404 при отправке логов\n')
            return
        
        print(f'📱 Найдено устройств: {len(devices_result)}\n')
        
        # Показываем все устройства
        device_found = False
        for device in devices_result:
            device_db_id = device[0]
            device_string_id = device[1]
            platform = device[2]
            created_at = device[3]
            device_name = device[4]
            device_type = device[5]
            current_server_id = device[6]
            last_connected = device[7]
            
            print(f'  Устройство ID={device_db_id}:')
            print(f'    device_id (строка): {device_string_id}')
            print(f'    platform: {platform}')
            print(f'    device_name: {device_name}')
            print(f'    device_type: {device_type}')
            print(f'    создано: {created_at}')
            if current_server_id:
                print(f'    Текущий сервер ID: {current_server_id}')
            if last_connected:
                print(f'    Последнее подключение: {last_connected}')
            print()
            
            # Если указан device_id, проверяем совпадение
            if device_id and device_string_id == device_id:
                print(f'  ✅ Устройство {device_id} найдено в базе данных!')
                print(f'     DB ID: {device_db_id}\n')
                device_found = True
        
        if device_id and not device_found:
            print(f'  ❌ Устройство {device_id} НЕ найдено в базе данных!')
            print(f'     Это причина ошибки 404 при отправке логов\n')
        
        # 3. Проверяем логи за последние 24 часа (включая error_details для network_type и connection_duration_ms)
        since = datetime.utcnow() - timedelta(hours=24)
        logs_result = conn.execute(
            text("""
                SELECT cl.id, cl.event_type, cl.protocol, cl.server_id, cl.message, cl.error_code,
                       cl.created_at, cl.device_id, cl.client_id, cl.connection_duration_ms, cl.error_details
                FROM client_logs cl
                WHERE cl.user_id = :user_id
                  AND cl.created_at >= :since
                ORDER BY cl.created_at DESC
                LIMIT 50
            """),
            {"user_id": user_id, "since": since}
        ).fetchall()
        
        if not logs_result:
            print('⚠️  Логи не найдены за последние 24 часа')
            print('   Это означает, что логи не доходят до сервера\n')
            return
        
        print(f'📊 Найдено логов за последние 24 часа: {len(logs_result)}\n')
        
        # Группируем по типам событий
        by_event_type = {}
        for log in logs_result:
            event_type = log[1]
            if event_type not in by_event_type:
                by_event_type[event_type] = []
            by_event_type[event_type].append(log)
        
        print('📋 Сводка по типам событий:')
        for event_type, events in sorted(by_event_type.items()):
            print(f'  {event_type}: {len(events)}')
        print()
        
        # Показываем последние 10 логов (включая network_type из error_details и длительность)
        print('📝 Последние 10 логов:')
        print('-' * 80)
        for i, log in enumerate(logs_result[:10], 1):
            log_id = log[0]
            event_type = log[1]
            protocol = log[2]
            server_id = log[3]
            message = log[4]
            error_code = log[5]
            created_at = log[6]
            device_db_id = log[7]
            client_id = log[8]
            duration_ms = log[9] if len(log) > 9 else None
            error_details = log[10] if len(log) > 10 else None

            print(f'\nЛог #{i} (ID={log_id}):')
            print(f'  Время: {created_at}')
            print(f'  Тип события: {event_type}')
            if protocol:
                print(f'  Протокол: {protocol}')
            if server_id:
                print(f'  Server ID: {server_id}')
            if device_db_id:
                print(f'  Device DB ID: {device_db_id}')
            if client_id:
                print(f'  Client ID: {client_id}')
            if duration_ms is not None:
                print(f'  Длительность: {duration_ms} мс')
            if error_details:
                net = error_details.get('network_type') if isinstance(error_details, dict) else None
                if net:
                    print(f'  Сеть (network_type): {net}')
                if isinstance(error_details, dict) and len(error_details) > 1:
                    print(f'  error_details: {error_details}')
            if message:
                print(f'  Сообщение: {message}')
            if error_code:
                print(f'  Код ошибки: {error_code}')
        
        print('\n' + '=' * 80)
        print('✅ Система логирования работает!')
        print('=' * 80)

if __name__ == "__main__":
    import os
    email = sys.argv[1] if len(sys.argv) > 1 else os.getenv("TEST_EMAIL")
    device_id = sys.argv[2] if len(sys.argv) > 2 else None
    if not email:
        print("Укажите email: argv[1] или TEST_EMAIL")
        sys.exit(1)
    check_logging_system(email, device_id)
