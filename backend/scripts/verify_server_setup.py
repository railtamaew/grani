#!/usr/bin/env python3
"""
Проверка финального состояния сервера
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import paramiko

def verify_setup():
    """Проверяет настройки сервера"""
    password = os.getenv("SSH_PASSWORD")
    if not password:
        print("✗ Задайте SSH_PASSWORD через переменную окружения.")
        sys.exit(1)
    host = "45.12.132.94"
    port = 22
    username = "root"

    print(f"\n{'='*60}")
    print(f"  ПРОВЕРКА НАСТРОЙКИ СЕРВЕРА")
    print(f"{'='*60}\n")
    
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(hostname=host, port=port, username=username, password=password, timeout=10)
        
        checks = []
        
        # 1. IP forwarding
        stdin, stdout, stderr = client.exec_command("sysctl net.ipv4.ip_forward | awk '{print $3}'")
        ip_forward = stdout.read().decode('utf-8').strip()
        checks.append(("IP Forwarding", ip_forward == "1", ip_forward))
        
        # 2. WireGuard статус
        stdin, stdout, stderr = client.exec_command("wg show wg0 2>&1")
        wg_status = stdout.read().decode('utf-8')
        wg_running = "interface: wg0" in wg_status
        checks.append(("WireGuard запущен", wg_running, "Да" if wg_running else "Нет"))
        
        # 3. Пир клиента
        peer_exists = "TVg3PioAwVBCbPxC9I0vRGI8YokqnMx7NlBDoPZrgCo=" in wg_status
        checks.append(("Пир клиента добавлен", peer_exists, "Да" if peer_exists else "Нет"))
        
        # 4. iptables FORWARD
        stdin, stdout, stderr = client.exec_command("iptables -C FORWARD -i wg0 -j ACCEPT 2>&1")
        forward_rule = stdout.read().decode('utf-8').strip() == ""
        checks.append(("iptables FORWARD", forward_rule, "Настроено" if forward_rule else "Отсутствует"))
        
        # 5. iptables MASQUERADE
        stdin, stdout, stderr = client.exec_command("iptables -t nat -L POSTROUTING -n -v | grep -q MASQUERADE && echo 'OK' || echo 'MISSING'")
        masq_rule = "OK" in stdout.read().decode('utf-8')
        checks.append(("iptables MASQUERADE", masq_rule, "Настроено" if masq_rule else "Отсутствует"))
        
        # 6. Интерфейс wg0
        stdin, stdout, stderr = client.exec_command("ip addr show wg0 2>&1")
        wg_interface = "wg0" in stdout.read().decode('utf-8')
        checks.append(("Интерфейс wg0", wg_interface, "Активен" if wg_interface else "Неактивен"))
        
        # Выводим результаты
        print("Результаты проверки:\n")
        all_ok = True
        for name, status, value in checks:
            icon = "✅" if status else "❌"
            print(f"{icon} {name}: {value}")
            if not status:
                all_ok = False
        
        # Детали iptables
        print("\nДетали iptables правил:")
        stdin, stdout, stderr = client.exec_command("iptables -L FORWARD -n -v | head -5")
        print(stdout.read().decode('utf-8'))
        
        stdin, stdout, stderr = client.exec_command("iptables -t nat -L POSTROUTING -n -v | head -5")
        print(stdout.read().decode('utf-8'))
        
        # Статус WireGuard
        print("\nСтатус WireGuard:")
        print(wg_status)
        
        client.close()
        
        print(f"\n{'='*60}")
        if all_ok:
            print("  ✅ ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ УСПЕШНО!")
        else:
            print("  ⚠️  НАЙДЕНЫ ПРОБЛЕМЫ")
        print(f"{'='*60}\n")
        
        return all_ok
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = verify_setup()
    sys.exit(0 if success else 1)

