#!/usr/bin/env python3
"""
Исправление маршрутизации трафика - детальная диагностика и исправление
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import paramiko

def fix_traffic():
    """Исправляет маршрутизацию трафика"""
    password = os.getenv("SSH_PASSWORD")
    if not password:
        print("✗ Задайте SSH_PASSWORD через переменную окружения.")
        sys.exit(1)
    host = "45.12.132.94"
    port = 22
    username = "root"

    print(f"\n{'='*60}")
    print(f"  ИСПРАВЛЕНИЕ МАРШРУТИЗАЦИИ ТРАФИКА")
    print(f"{'='*60}\n")
    
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(hostname=host, port=port, username=username, password=password, timeout=10)
        print("✅ Подключение установлено\n")
        
        # 1. Проверяем, слушает ли WireGuard порт
        print("1. Проверка порта WireGuard...")
        stdin, stdout, stderr = client.exec_command("ss -ulnp | grep 51820 || netstat -ulnp | grep 51820 || echo 'Порт не найден'")
        port_check = stdout.read().decode('utf-8')
        print(f"   {port_check.strip()}")
        
        # 2. Проверяем статус WireGuard
        print("\n2. Статус WireGuard...")
        stdin, stdout, stderr = client.exec_command("wg show")
        wg_status = stdout.read().decode('utf-8')
        print(wg_status)
        
        # 3. Проверяем, что интерфейс wg0 имеет правильный IP
        print("\n3. Проверка IP адреса интерфейса wg0...")
        stdin, stdout, stderr = client.exec_command("ip addr show wg0")
        wg0_addr = stdout.read().decode('utf-8')
        print(wg0_addr)
        
        # 4. Проверяем маршрутизацию для клиента
        print("\n4. Проверка маршрутизации...")
        # Проверяем, что трафик из 10.0.0.2 будет маршрутизироваться правильно
        stdin, stdout, stderr = client.exec_command("ip route get 8.8.8.8")
        route_out = stdout.read().decode('utf-8')
        print(f"   Маршрут к 8.8.8.8:")
        print(f"   {route_out}")
        
        # 5. Проверяем, что обратный трафик будет идти через wg0
        print("\n5. Проверка обратной маршрутизации...")
        stdin, stdout, stderr = client.exec_command("ip route get 10.0.0.2")
        route_back = stdout.read().decode('utf-8')
        print(f"   Маршрут к 10.0.0.2 (клиент):")
        print(f"   {route_back}")
        
        # 6. Проверяем политику FORWARD
        print("\n6. Проверка политики FORWARD...")
        stdin, stdout, stderr = client.exec_command("iptables -L FORWARD -n | head -1")
        forward_policy = stdout.read().decode('utf-8')
        print(f"   {forward_policy.strip()}")
        
        # 7. Убеждаемся, что правила в правильном порядке
        print("\n7. Проверка порядка правил FORWARD...")
        stdin, stdout, stderr = client.exec_command("iptables -L FORWARD -n --line-numbers | head -5")
        forward_order = stdout.read().decode('utf-8')
        print(forward_order)
        
        # 8. Проверяем, что MASQUERADE применяется для трафика из wg0
        print("\n8. Проверка правил MASQUERADE...")
        stdin, stdout, stderr = client.exec_command("iptables -t nat -L POSTROUTING -n --line-numbers | grep -E '(MASQUERADE|ens3)'")
        masq_rules = stdout.read().decode('utf-8')
        print(masq_rules if masq_rules.strip() else "   Правила не найдены")
        
        # 9. Пробуем добавить более специфичное правило MASQUERADE
        print("\n9. Добавление специфичного правила MASQUERADE для wg0...")
        # Удаляем общее правило если есть
        client.exec_command("iptables -t nat -D POSTROUTING -o ens3 -j MASQUERADE 2>/dev/null || true")
        # Добавляем правило для трафика из wg0
        stdin, stdout, stderr = client.exec_command("iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o ens3 -j MASQUERADE")
        exit_status = stdout.channel.recv_exit_status()
        if exit_status == 0:
            print("   ✅ Правило MASQUERADE для сети 10.0.0.0/24 добавлено")
        else:
            error = stderr.read().decode('utf-8')
            print(f"   ⚠️  Ошибка: {error}")
        
        # 10. Проверяем, что правила применяются
        print("\n10. Проверка правил после изменений...")
        stdin, stdout, stderr = client.exec_command("iptables -t nat -L POSTROUTING -n -v | tail -5")
        masq_check = stdout.read().decode('utf-8')
        print(masq_check)
        
        # 11. Обновляем конфигурацию WireGuard для сохранения правил
        print("\n11. Обновление конфигурации WireGuard...")
        stdin, stdout, stderr = client.exec_command("cat /etc/wireguard/private.key")
        server_private_key = stdout.read().decode('utf-8').strip()
        
        stdin, stdout, stderr = client.exec_command("ip route | grep default | awk '{print $5}' | head -n1")
        main_interface = stdout.read().decode('utf-8').strip()
        
        client_public_key = "TVg3PioAwVBCbPxC9I0vRGI8YokqnMx7NlBDoPZrgCo="
        client_ip = "10.0.0.2/32"
        
        wg_config = f"""[Interface]
PrivateKey = {server_private_key}
Address = 10.0.0.1/24
ListenPort = 51820
PostUp = iptables -I FORWARD 1 -i wg0 -j ACCEPT; iptables -I FORWARD 2 -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o {main_interface} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -o {main_interface} -j MASQUERADE

# MTU
MTU = 1420

# Сохранение конфигурации
SaveConfig = true

# Peer for client
[Peer]
PublicKey = {client_public_key}
AllowedIPs = {client_ip}
"""
        
        sftp = client.open_sftp()
        try:
            remote_file = sftp.file('/etc/wireguard/wg0.conf', 'w')
            remote_file.write(wg_config)
            remote_file.close()
            print("   ✅ Конфигурация обновлена")
        finally:
            sftp.close()
        
        client.exec_command("chmod 600 /etc/wireguard/wg0.conf")
        
        client.close()
        
        print(f"\n{'='*60}")
        print("  ИСПРАВЛЕНИЕ ЗАВЕРШЕНО")
        print(f"{'='*60}\n")
        print("💡 Изменения:")
        print("   1. Добавлено специфичное правило MASQUERADE для сети 10.0.0.0/24")
        print("   2. Обновлена конфигурация WireGuard")
        print("\n📋 Следующие шаги:")
        print("   1. Перезапустите WireGuard на сервере (или подождите автоматического применения)")
        print("   2. Переподключитесь к VPN на клиенте")
        print("   3. Попробуйте открыть сайт")
        print("   4. Проверьте передачу данных - должны появиться полученные байты")
        print(f"\n{'='*60}\n")
        
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = fix_traffic()
    sys.exit(0 if success else 1)

