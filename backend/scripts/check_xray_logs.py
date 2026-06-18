#!/usr/bin/env python3
"""
Скрипт для анализа логов подключений Xray протоколов
"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import text
from core.database import engine
from datetime import datetime, timedelta
import json

def analyze_xray_logs(email: str):
    """Анализирует логи подключений Xray для указанного пользователя"""
    with engine.connect() as conn:
        # Находим пользователя
        user_result = conn.execute(
            text("SELECT id, email FROM users WHERE email = :email"),
            {"email": email}
        ).fetchone()
        
        if not user_result:
            print(f'❌ Пользователь не найден: {email}')
            return
        
        user_id = user_result[0]
        print(f'✅ Пользователь найден: ID={user_id}, email={user_result[1]}\n')
        
        # Получаем логи за последние 48 часов
        since = datetime.utcnow() - timedelta(hours=48)
        xray_protocols = ['xray_vless', 'xray_vmess', 'xray_reality']
        protocols_str = "', '".join(xray_protocols)
        
        logs_result = conn.execute(
            text(f"""
                SELECT id, event_type, protocol, server_id, message, error_code, 
                       error_details, created_at, client_id, connection_duration_ms,
                       bytes_sent, bytes_received
                FROM client_logs
                WHERE user_id = :user_id 
                  AND protocol IN ('{protocols_str}')
                  AND created_at >= :since
                ORDER BY created_at DESC
            """),
            {"user_id": user_id, "since": since}
        ).fetchall()
        
        if not logs_result:
            print('⚠️  Логи Xray не найдены за последние 48 часов')
            return
        
        # Преобразуем результаты в список словарей
        logs = []
        for row in logs_result:
            logs.append({
                'id': row[0],
                'event_type': row[1],
                'protocol': row[2],
                'server_id': row[3],
                'message': row[4],
                'error_code': row[5],
                'error_details': row[6],
                'created_at': row[7],
                'client_id': row[8],
                'connection_duration_ms': row[9],
                'bytes_sent': row[10],
                'bytes_received': row[11],
            })
        
        print(f'📊 Всего логов Xray: {len(logs)}\n')
        
        # Группируем по протоколам
        by_protocol = {}
        for log in logs:
            protocol = log['protocol']
            if protocol not in by_protocol:
                by_protocol[protocol] = []
            by_protocol[protocol].append(log)
        
        # Анализируем каждый протокол
        for protocol, protocol_logs in sorted(by_protocol.items()):
            print(f'\n{"="*80}')
            print(f'🔷 ПРОТОКОЛ: {protocol.upper()}')
            print(f'{"="*80}')
            print(f'Всего событий: {len(protocol_logs)}')
            
            errors = [l for l in protocol_logs if l['event_type'] == 'connection_error']
            starts = [l for l in protocol_logs if l['event_type'] == 'connection_start']
            successes = [l for l in protocol_logs if l['event_type'] == 'connection_success']
            ends = [l for l in protocol_logs if l['event_type'] == 'connection_end']
            
            print(f'  📍 Начало подключения: {len(starts)}')
            print(f'  ✅ Успешные подключения: {len(successes)}')
            print(f'  ❌ Ошибки подключения: {len(errors)}')
            print(f'  🔚 Завершения подключения: {len(ends)}')
            
            if errors:
                print(f'\n⚠️  ПОСЛЕДНИЕ ОШИБКИ ({len(errors)} всего):')
                print('-'*80)
                for i, err in enumerate(errors[:5], 1):  # Показываем последние 5 ошибок
                    print(f'\nОшибка #{i}:')
                    print(f'  Время: {err["created_at"]}')
                    print(f'  Server ID: {err["server_id"]}')
                    print(f'  Client ID: {err["client_id"]}')
                    print(f'  Error Code: {err["error_code"]}')
                    print(f'  Message: {err["message"]}')
                    if err['error_details']:
                        print(f'  Error Details:')
                        if isinstance(err['error_details'], dict):
                            details_str = json.dumps(err['error_details'], indent=4, ensure_ascii=False)
                        else:
                            details_str = str(err['error_details'])
                        print(f'    {details_str}')
                    print()
        
        # Сводка по всем ошибкам
        all_errors = [l for l in logs if l['event_type'] == 'connection_error']
        if all_errors:
            print(f'\n{"="*80}')
            print(f'📋 СВОДКА: Всего ошибок Xray: {len(all_errors)}')
            print(f'{"="*80}')
            
            # Группируем ошибки по коду
            by_error_code = {}
            for err in all_errors:
                code = err['error_code'] or 'NO_CODE'
                if code not in by_error_code:
                    by_error_code[code] = []
                by_error_code[code].append(err)
            
            for code, errs in sorted(by_error_code.items(), key=lambda x: len(x[1]), reverse=True):
                print(f'\nКод ошибки: {code} ({len(errs)} раз)')
                if errs:
                    print(f'  Пример сообщения: {errs[0]["message"]}')

if __name__ == "__main__":
    import os
    email = sys.argv[1] if len(sys.argv) > 1 else os.getenv("TEST_EMAIL")
    if not email:
        print("Укажите email: argv[1] или TEST_EMAIL")
        sys.exit(1)
    analyze_xray_logs(email)
