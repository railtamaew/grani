#!/usr/bin/env python3
"""
Проверка трафика от клиента на сервере
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import paramiko
import time

def check_traffic():
    """Проверяет трафик от клиента"""
    password = os.getenv("SSH_PASSWORD")
    if not password:
        print("✗ Задайте SSH_PASSWORD через переменную окружения.")
        sys.exit(1)
    host = "45.12.132.94"
    port = 22
    username = "root"

    print(f"\n{'='*60}")
    print(f"  ПРОВЕРКА ТРАФИКА ОТ КЛИЕНТА")
    print(f"{'='*60}\n")
    print("⚠️  ВАЖНО: Убедитесь, что VPN подключен на клиенте!")
    print("   Нажмите Enter когда будете готовы начать тест...")
    input()
    
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(hostname=host, port=port, username=username, password=password, timeout=10)
        print("✅ Подключение установлено\n")
        
        # Получаем начальные счетчики
        print("1. Начальные счетчики...")
        stdin, stdout, stderr = client.exec_command("wg show wg0 | grep transfer")
        initial_transfer = stdout.read().decode('utf-8')
        print(f"   {initial_transfer.strip()}")
        
        stdin, stdout, stderr = client.exec_command("iptables -L FORWARD -n -v | grep wg0")
        initial_forward = stdout.read().decode('utf-8')
        print(f"   FORWARD: {initial_forward.strip()}")
        
        stdin, stdout, stderr = client.exec_command("iptables -t nat -L POSTROUTING -n -v | grep '10.0.0.0/24'")
        initial_masq = stdout.read().decode('utf-8')
        print(f"   MASQUERADE: {initial_masq.strip()}")
        
        print("\n2. Ожидание трафика от клиента (30 секунд)...")
        print("   💡 На клиенте попробуйте:")
        print("      - Открыть сайт в браузере")
        print("      - Выполнить: ping 8.8.8.8")
        print("      - Выполнить: curl http://8.8.8.8")
        
        time.sleep(30)
        
        # Получаем конечные счетчики
        print("\n3. Конечные счетчики...")
        stdin, stdout, stderr = client.exec_command("wg show wg0 | grep transfer")
        final_transfer = stdout.read().decode('utf-8')
        print(f"   {final_transfer.strip()}")
        
        stdin, stdout, stderr = client.exec_command("iptables -L FORWARD -n -v | grep wg0")
        final_forward = stdout.read().decode('utf-8')
        print(f"   FORWARD: {final_forward.strip()}")
        
        stdin, stdout, stderr = client.exec_command("iptables -t nat -L POSTROUTING -n -v | grep '10.0.0.0/24'")
        final_masq = stdout.read().decode('utf-8')
        print(f"   MASQUERADE: {final_masq.strip()}")
        
        # Проверяем статистику интерфейса
        print("\n4. Статистика интерфейса wg0...")
        stdin, stdout, stderr = client.exec_command("ip -s link show wg0")
        wg0_stats = stdout.read().decode('utf-8')
        print(wg0_stats)
        
        # Анализ
        print(f"\n{'='*60}")
        print("  АНАЛИЗ")
        print(f"{'='*60}\n")
        
        if initial_transfer == final_transfer:
            print("❌ ПРОБЛЕМА: Трафик от клиента НЕ поступает на сервер!")
            print("   Возможные причины:")
            print("   1. WireGuard блокируется в России (DPI)")
            print("   2. Трафик не маршрутизируется через VPN на клиенте")
            print("   3. Файрвол блокирует трафик")
            print("\n   💡 РЕШЕНИЕ: Используйте обфусцированные протоколы:")
            print("      - GRANIWG (обфусцированный WireGuard)")
            print("      - XRay Reality")
            print("      - OpenVPN Cloak")
        else:
            print("✅ Трафик от клиента поступает на сервер")
            if "0     0" in final_forward or "0     0" in final_masq:
                print("⚠️  Но трафик не проходит через iptables правила")
                print("   Возможно проблема с маршрутизацией")
            else:
                print("✅ Трафик проходит через iptables правила")
                print("   Проблема может быть в блокировке WireGuard в России")
        
        client.close()
        
        print(f"\n{'='*60}\n")
        
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = check_traffic()
    sys.exit(0 if success else 1)

