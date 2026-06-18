#!/usr/bin/env python3
"""
Инициация подключений к протоколам на сервере для тестирования

Используется для проверки работы всех протоколов после исправлений.
"""
import sys
import os
import time
from pathlib import Path

# Добавляем путь к backend
sys.path.insert(0, str(Path(__file__).parent.parent / "backend"))

from scripts.vpn_tester import VPNTester

def main():
    """Инициирует подключения ко всем протоколам на первом доступном сервере"""
    print("🚀 Инициация подключений к протоколам на сервере...")
    print("=" * 70)
    
    # Создаем тестер
    tester = VPNTester(
        email="rail.tamaew@gmail.com",
        api_base_url=os.getenv("API_URL", "https://api.granilink.com")
    )
    
    # Получаем токен
    print("\n📋 1. Получение токена...")
    if not tester.get_token():
        print("❌ Не удалось получить токен")
        return 1
    print("✅ Токен получен")
    
    # Получаем список серверов
    print("\n📋 2. Получение списка серверов...")
    servers = tester.get_servers()
    if not servers:
        print("❌ Не удалось получить список серверов")
        return 1
    
    print(f"✅ Найдено серверов: {len(servers)}")
    for server in servers:
        print(f"   - Сервер {server['id']}: {server['name']} ({server['country']})")
        print(f"     Протоколы: {', '.join(server.get('supported_protocols', []))}")
    
    # Выбираем первый активный сервер
    active_server = next((s for s in servers if s.get('is_active', False)), servers[0])
    server_id = active_server['id']
    
    print(f"\n📋 3. Тестирование протоколов на сервере {active_server['name']} (ID: {server_id})")
    print("=" * 70)
    
    # Получаем поддерживаемые протоколы
    protocols = active_server.get('supported_protocols', [])
    if not protocols:
        print("⚠️  Сервер не поддерживает протоколы")
        return 1
    
    print(f"   Поддерживаемые протоколы: {', '.join(protocols)}")
    print()
    
    results = []
    
    # Тестируем каждый протокол
    for protocol in protocols:
        print(f"   🔌 Тестирование {protocol}...")
        try:
            # Подключаемся
            if tester.connect(server_id, protocol):
                print(f"      ✅ Подключение установлено")
                
                # Ждем установки подключения
                time.sleep(2)
                
                # Проверяем статус
                status = tester.get_status()
                if status:
                    connected = status.get('connected', False)
                    print(f"      📊 Статус: {'подключено' if connected else 'не подключено'}")
                
                # Отключаемся
                if tester.disconnect():
                    print(f"      ✅ Отключение выполнено")
                else:
                    print(f"      ⚠️  Проблема с отключением")
                
                results.append((protocol, True))
            else:
                print(f"      ❌ Не удалось подключиться")
                results.append((protocol, False))
        except Exception as e:
            print(f"      ❌ Ошибка: {e}")
            results.append((protocol, False))
        
        # Пауза между тестами
        time.sleep(1)
        print()
    
    # Итоговый отчет
    print("=" * 70)
    print("📊 ИТОГОВЫЙ РЕЗУЛЬТАТ:")
    print("-" * 70)
    
    successful = sum(1 for _, success in results if success)
    total = len(results)
    
    for protocol, success in results:
        status = "✅" if success else "❌"
        print(f"   {status} {protocol}")
    
    print(f"\n   Успешно: {successful}/{total}")
    
    if successful == total:
        print("\n✅ Все протоколы работают корректно!")
        return 0
    else:
        print(f"\n⚠️  {total - successful} протоколов не удалось подключить")
        return 1

if __name__ == "__main__":
    sys.exit(main())
