#!/usr/bin/env python3
"""
Проверка проблемы с маршрутизацией трафика
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import paramiko

def check_routing():
    """Проверяет настройки маршрутизации"""
    password = os.getenv("SSH_PASSWORD")
    if not password:
        print("✗ Задайте SSH_PASSWORD через переменную окружения.")
        sys.exit(1)
    host = "45.12.132.94"
    port = 22
    username = "root"

    print(f"\n{'='*60}")
    print(f"  ПРОВЕРКА ПРОБЛЕМЫ С МАРШРУТИЗАЦИЕЙ")
    print(f"{'='*60}\n")
    
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(hostname=host, port=port, username=username, password=password, timeout=10)
        print("✅ Подключение установлено\n")
        
        # 1. Проверяем iptables правила для wg0
        print("1. Проверка iptables правил для wg0...")
        stdin, stdout, stderr = client.exec_command("iptables -L FORWARD -n -v | grep wg0")
        forward_rules = stdout.read().decode('utf-8')
        print(f"   FORWARD правила для wg0:")
        if forward_rules.strip():
            print(f"   {forward_rules}")
        else:
            print("   ⚠️  Правила FORWARD для wg0 не найдены!")
        
        # 2. Проверяем MASQUERADE
        print("\n2. Проверка MASQUERADE...")
        stdin, stdout, stderr = client.exec_command("iptables -t nat -L POSTROUTING -n -v | grep -E '(MASQUERADE|ens3)'")
        masq_rules = stdout.read().decode('utf-8')
        print(f"   MASQUERADE правила:")
        if masq_rules.strip():
            print(f"   {masq_rules}")
        else:
            print("   ⚠️  Правила MASQUERADE не найдены!")
        
        # 3. Проверяем файрвол
        print("\n3. Проверка файрвола (ufw)...")
        stdin, stdout, stderr = client.exec_command("ufw status 2>&1")
        ufw_status = stdout.read().decode('utf-8')
        print(f"   Статус UFW:")
        print(f"   {ufw_status}")
        
        # 4. Проверяем, что трафик проходит через wg0
        print("\n4. Проверка интерфейса wg0...")
        stdin, stdout, stderr = client.exec_command("ip addr show wg0")
        wg_interface = stdout.read().decode('utf-8')
        print(f"   Интерфейс wg0:")
        print(f"   {wg_interface}")
        
        # 5. Проверяем маршруты
        print("\n5. Проверка маршрутов...")
        stdin, stdout, stderr = client.exec_command("ip route show")
        routes = stdout.read().decode('utf-8')
        print(f"   Маршруты:")
        print(f"   {routes}")
        
        # 6. Проверяем, что iptables правила действительно применяются
        print("\n6. Детальная проверка iptables...")
        stdin, stdout, stderr = client.exec_command("iptables -L FORWARD -n -v --line-numbers")
        forward_detailed = stdout.read().decode('utf-8')
        print(f"   Все FORWARD правила:")
        print(f"   {forward_detailed}")
        
        stdin, stdout, stderr = client.exec_command("iptables -t nat -L POSTROUTING -n -v --line-numbers")
        postrouting_detailed = stdout.read().decode('utf-8')
        print(f"\n   Все POSTROUTING правила:")
        print(f"   {postrouting_detailed}")
        
        # 7. Проверяем, есть ли блокирующие правила
        print("\n7. Проверка блокирующих правил...")
        stdin, stdout, stderr = client.exec_command("iptables -L FORWARD -n | grep -E '(DROP|REJECT)'")
        blocking = stdout.read().decode('utf-8')
        if blocking.strip():
            print(f"   ⚠️  Найдены блокирующие правила:")
            print(f"   {blocking}")
        else:
            print("   ✅ Блокирующих правил не найдено")
        
        # 8. Проверяем логи WireGuard
        print("\n8. Последние логи WireGuard...")
        stdin, stdout, stderr = client.exec_command("journalctl -u wg-quick@wg0 -n 20 --no-pager 2>&1")
        logs = stdout.read().decode('utf-8')
        print(f"   Логи:")
        print(f"   {logs}")
        
        client.close()
        
        print(f"\n{'='*60}")
        print("  РЕКОМЕНДАЦИИ")
        print(f"{'='*60}\n")
        
        # Анализ и рекомендации
        if "wg0" not in forward_rules:
            print("⚠️  ПРОБЛЕМА: Правила FORWARD для wg0 не найдены!")
            print("   Решение: Добавить правило вручную или перезапустить WireGuard")
        
        if "MASQUERADE" not in masq_rules or "ens3" not in masq_rules:
            print("⚠️  ПРОБЛЕМА: Правила MASQUERADE для ens3 не найдены!")
            print("   Решение: Добавить правило вручную")
        
        if "Status: active" in ufw_status:
            print("⚠️  ВНИМАНИЕ: UFW активен, может блокировать трафик")
            print("   Решение: Проверить правила UFW для порта 51820 и FORWARD")
        
        print(f"\n{'='*60}\n")
        
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = check_routing()
    sys.exit(0 if success else 1)

