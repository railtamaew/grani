#!/usr/bin/env python3
"""
Исправление маршрутизации трафика через WireGuard
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import paramiko

def fix_routing():
    """Исправляет маршрутизацию"""
    password = os.getenv("SSH_PASSWORD")
    if not password:
        print("✗ Задайте SSH_PASSWORD через переменную окружения.")
        sys.exit(1)
    host = "45.12.132.94"
    port = 22
    username = "root"

    print(f"\n{'='*60}")
    print(f"  ИСПРАВЛЕНИЕ МАРШРУТИЗАЦИИ")
    print(f"{'='*60}\n")
    
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(hostname=host, port=port, username=username, password=password, timeout=10)
        print("✅ Подключение установлено\n")
        
        # 1. Удаляем дублирующие правила FORWARD для wg0
        print("1. Очистка старых правил FORWARD для wg0...")
        client.exec_command("iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true")
        client.exec_command("iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true")
        print("   ✅ Старые правила удалены")
        
        # 2. Добавляем правила FORWARD в начало цепочки (перед Docker)
        print("\n2. Добавление правил FORWARD для wg0...")
        
        # Правило для трафика ИЗ wg0
        stdin, stdout, stderr = client.exec_command("iptables -I FORWARD 1 -i wg0 -j ACCEPT")
        exit_status = stdout.channel.recv_exit_status()
        if exit_status == 0:
            print("   ✅ Правило FORWARD для трафика ИЗ wg0 добавлено")
        else:
            error = stderr.read().decode('utf-8')
            print(f"   ⚠️  Ошибка: {error}")
        
        # Правило для трафика В wg0 (обратный трафик)
        stdin, stdout, stderr = client.exec_command("iptables -I FORWARD 2 -o wg0 -j ACCEPT")
        exit_status = stdout.channel.recv_exit_status()
        if exit_status == 0:
            print("   ✅ Правило FORWARD для трафика В wg0 добавлено")
        else:
            error = stderr.read().decode('utf-8')
            print(f"   ⚠️  Ошибка: {error}")
        
        # 3. Проверяем и добавляем MASQUERADE если нужно
        print("\n3. Проверка MASQUERADE...")
        stdin, stdout, stderr = client.exec_command("iptables -t nat -L POSTROUTING -n | grep -E 'MASQUERADE.*ens3'")
        masq_check = stdout.read().decode('utf-8')
        
        if "MASQUERADE" in masq_check and "ens3" in masq_check:
            print("   ✅ Правило MASQUERADE для ens3 уже существует")
        else:
            print("   Добавление правила MASQUERADE...")
            stdin, stdout, stderr = client.exec_command("iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE")
            exit_status = stdout.channel.recv_exit_status()
            if exit_status == 0:
                print("   ✅ Правило MASQUERADE добавлено")
            else:
                error = stderr.read().decode('utf-8')
                print(f"   ⚠️  Ошибка: {error}")
        
        # 4. Проверяем результат
        print("\n4. Проверка правил...")
        stdin, stdout, stderr = client.exec_command("iptables -L FORWARD -n -v --line-numbers | head -15")
        forward_rules = stdout.read().decode('utf-8')
        print("   FORWARD правила (первые 15):")
        print(f"   {forward_rules}")
        
        # 5. Проверяем, что правила применяются
        print("\n5. Проверка применения правил...")
        stdin, stdout, stderr = client.exec_command("iptables -L FORWARD -n | grep wg0")
        wg0_rules = stdout.read().decode('utf-8')
        if wg0_rules.strip():
            print("   ✅ Правила для wg0 найдены:")
            for line in wg0_rules.strip().split('\n'):
                print(f"      {line}")
        else:
            print("   ⚠️  Правила для wg0 не найдены!")
        
        # 6. Сохраняем правила (если установлен iptables-persistent)
        print("\n6. Сохранение правил...")
        stdin, stdout, stderr = client.exec_command("which iptables-save")
        if stdout.read().decode('utf-8').strip():
            # Пробуем сохранить через netfilter-persistent
            client.exec_command("netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true")
            print("   ✅ Правила сохранены (если доступно)")
        else:
            print("   ⚠️  iptables-save не найден, правила не сохранены")
        
        client.close()
        
        print(f"\n{'='*60}")
        print("  ИСПРАВЛЕНИЕ ЗАВЕРШЕНО")
        print(f"{'='*60}\n")
        print("💡 Теперь попробуйте:")
        print("   1. Переподключитесь к VPN на клиенте")
        print("   2. Проверьте передачу данных - должны появиться полученные байты")
        print("   3. Попробуйте открыть сайт в браузере")
        print(f"\n{'='*60}\n")
        
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = fix_routing()
    sys.exit(0 if success else 1)

