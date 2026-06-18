#!/usr/bin/env python3
"""
Диагностика проблемы с трафиком
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import paramiko
import time

def debug_traffic():
    """Диагностирует проблему с трафиком"""
    password = os.getenv("SSH_PASSWORD")
    if not password:
        print("✗ Задайте SSH_PASSWORD через переменную окружения.")
        sys.exit(1)
    host = "45.12.132.94"
    port = 22
    username = "root"

    print(f"\n{'='*60}")
    print(f"  ДИАГНОСТИКА ПРОБЛЕМЫ С ТРАФИКОМ")
    print(f"{'='*60}\n")
    
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(hostname=host, port=port, username=username, password=password, timeout=10)
        print("✅ Подключение установлено\n")
        
        # 1. Проверяем счетчики пакетов в iptables
        print("1. Проверка счетчиков пакетов в iptables...")
        stdin, stdout, stderr = client.exec_command("iptables -L FORWARD -n -v | grep wg0")
        forward_stats = stdout.read().decode('utf-8')
        print(f"   FORWARD для wg0:")
        if forward_stats.strip():
            for line in forward_stats.strip().split('\n'):
                print(f"      {line}")
        else:
            print("   ⚠️  Правила не найдены!")
        
        # 2. Проверяем MASQUERADE
        print("\n2. Проверка MASQUERADE...")
        stdin, stdout, stderr = client.exec_command("iptables -t nat -L POSTROUTING -n -v | grep ens3")
        masq_stats = stdout.read().decode('utf-8')
        print(f"   MASQUERADE для ens3:")
        if masq_stats.strip():
            for line in masq_stats.strip().split('\n'):
                print(f"      {line}")
        else:
            print("   ⚠️  Правила не найдены!")
        
        # 3. Проверяем, что трафик проходит через интерфейс
        print("\n3. Проверка трафика на интерфейсе wg0...")
        stdin, stdout, stderr = client.exec_command("ip -s link show wg0")
        wg0_stats = stdout.read().decode('utf-8')
        print(f"   Статистика wg0:")
        print(f"   {wg0_stats}")
        
        # 4. Проверяем маршруты
        print("\n4. Проверка маршрутов...")
        stdin, stdout, stderr = client.exec_command("ip route show")
        routes = stdout.read().decode('utf-8')
        print(f"   Маршруты:")
        print(f"   {routes}")
        
        # 5. Проверяем, может ли сервер выходить в интернет
        print("\n5. Проверка выхода в интернет с сервера...")
        stdin, stdout, stderr = client.exec_command("curl -s --max-time 5 ifconfig.me 2>&1 || echo 'Ошибка'")
        server_ip = stdout.read().decode('utf-8').strip()
        if server_ip and "Ошибка" not in server_ip:
            print(f"   ✅ Сервер может выходить в интернет: {server_ip}")
        else:
            print(f"   ⚠️  Сервер не может выйти в интернет")
        
        # 6. Проверяем, что трафик из сети 10.0.0.0/24 может выходить
        print("\n6. Проверка маршрутизации для сети 10.0.0.0/24...")
        stdin, stdout, stderr = client.exec_command("ip route get 8.8.8.8 from 10.0.0.2")
        route_test = stdout.read().decode('utf-8')
        print(f"   Маршрут для трафика из 10.0.0.2:")
        print(f"   {route_test}")
        
        # 7. Проверяем файрвол
        print("\n7. Проверка файрвола...")
        stdin, stdout, stderr = client.exec_command("ufw status 2>&1")
        ufw_status = stdout.read().decode('utf-8')
        print(f"   UFW: {ufw_status.strip()}")
        
        # 8. Проверяем, не блокирует ли что-то порт 51820
        print("\n8. Проверка порта 51820...")
        stdin, stdout, stderr = client.exec_command("netstat -tuln | grep 51820")
        port_check = stdout.read().decode('utf-8')
        if port_check.strip():
            print(f"   ✅ Порт 51820 слушается:")
            print(f"   {port_check}")
        else:
            print("   ⚠️  Порт 51820 не найден")
        
        # 9. Проверяем логи ядра (может быть проблема с форвардингом)
        print("\n9. Проверка последних логов ядра...")
        stdin, stdout, stderr = client.exec_command("dmesg | tail -20 | grep -i -E '(forward|drop|reject|wg0)' || echo 'Нет релевантных логов'")
        kernel_logs = stdout.read().decode('utf-8')
        print(f"   Логи ядра:")
        print(f"   {kernel_logs}")
        
        # 10. Тест: пробуем пинг из сети wg0
        print("\n10. Тест маршрутизации...")
        print("   (Этот тест требует активного подключения клиента)")
        
        # 11. Проверяем, есть ли обратный маршрут
        print("\n11. Проверка обратного маршрута...")
        stdin, stdout, stderr = client.exec_command("ip route get 10.0.0.2 from 8.8.8.8 2>&1 || echo 'Маршрут не найден (это нормально)'")
        reverse_route = stdout.read().decode('utf-8')
        print(f"   Обратный маршрут:")
        print(f"   {reverse_route}")
        
        client.close()
        
        print(f"\n{'='*60}")
        print("  АНАЛИЗ И РЕКОМЕНДАЦИИ")
        print(f"{'='*60}\n")
        
        # Анализ
        if "0     0" in forward_stats:
            print("⚠️  ПРОБЛЕМА: Счетчики пакетов в FORWARD равны 0!")
            print("   Это означает, что трафик не проходит через правила FORWARD")
            print("   Возможные причины:")
            print("   1. Трафик блокируется до попадания в FORWARD")
            print("   2. Проблема с маршрутизацией")
            print("   3. Трафик идет другим путем")
        
        if "0     0" in masq_stats:
            print("\n⚠️  ПРОБЛЕМА: Счетчики пакетов в MASQUERADE равны 0!")
            print("   Это означает, что NAT не применяется")
        
        print("\n💡 РЕКОМЕНДАЦИИ:")
        print("   1. Убедитесь, что клиент действительно подключен")
        print("   2. Попробуйте ping 8.8.8.8 с клиента через VPN")
        print("   3. Проверьте, не блокирует ли файрвол Windows трафик")
        print("   4. Проверьте DNS на клиенте - возможно проблема с DNS")
        
        print(f"\n{'='*60}\n")
        
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = debug_traffic()
    sys.exit(0 if success else 1)

