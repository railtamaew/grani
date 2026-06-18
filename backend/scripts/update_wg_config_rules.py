#!/usr/bin/env python3
"""
Обновление конфигурации WireGuard для правильной работы правил iptables
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import paramiko

def update_wg_config():
    """Обновляет конфигурацию WireGuard"""
    password = os.getenv("SSH_PASSWORD")
    if not password:
        print("✗ Задайте SSH_PASSWORD через переменную окружения.")
        sys.exit(1)
    host = "45.12.132.94"
    port = 22
    username = "root"

    client_public_key = "TVg3PioAwVBCbPxC9I0vRGI8YokqnMx7NlBDoPZrgCo="
    client_ip = "10.0.0.2/32"
    
    print(f"\n{'='*60}")
    print(f"  ОБНОВЛЕНИЕ КОНФИГУРАЦИИ WIREGUARD")
    print(f"{'='*60}\n")
    
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(hostname=host, port=port, username=username, password=password, timeout=10)
        print("✅ Подключение установлено\n")
        
        # Получаем приватный ключ
        stdin, stdout, stderr = client.exec_command("cat /etc/wireguard/private.key")
        server_private_key = stdout.read().decode('utf-8').strip()
        
        # Определяем интерфейс
        stdin, stdout, stderr = client.exec_command("ip route | grep default | awk '{print $5}' | head -n1")
        main_interface = stdout.read().decode('utf-8').strip()
        
        # Создаем обновленную конфигурацию с правильными правилами
        wg_config = f"""[Interface]
PrivateKey = {server_private_key}
Address = 10.0.0.1/24
ListenPort = 51820
PostUp = iptables -I FORWARD 1 -i wg0 -j ACCEPT; iptables -I FORWARD 2 -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o {main_interface} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o {main_interface} -j MASQUERADE

# MTU
MTU = 1420

# Сохранение конфигурации
SaveConfig = true

# Peer for client
[Peer]
PublicKey = {client_public_key}
AllowedIPs = {client_ip}
"""
        
        # Загружаем конфигурацию
        sftp = client.open_sftp()
        try:
            remote_file = sftp.file('/etc/wireguard/wg0.conf', 'w')
            remote_file.write(wg_config)
            remote_file.close()
            print("✅ Конфигурация обновлена")
        finally:
            sftp.close()
        
        client.exec_command("chmod 600 /etc/wireguard/wg0.conf")
        
        # Перезапускаем WireGuard
        print("\nПерезапуск WireGuard...")
        client.exec_command("wg-quick down wg0 2>/dev/null || true")
        
        stdin, stdout, stderr = client.exec_command("wg-quick up wg0")
        output = stdout.read().decode('utf-8')
        error = stderr.read().decode('utf-8')
        
        if "error" not in error.lower() and "failed" not in error.lower():
            print("✅ WireGuard перезапущен")
        else:
            print(f"⚠️  Предупреждение: {error}")
        
        # Проверяем статус
        print("\nПроверка статуса...")
        stdin, stdout, stderr = client.exec_command("wg show")
        wg_status = stdout.read().decode('utf-8')
        print(wg_status)
        
        # Проверяем правила
        print("\nПроверка правил iptables...")
        stdin, stdout, stderr = client.exec_command("iptables -L FORWARD -n --line-numbers | head -5")
        forward_rules = stdout.read().decode('utf-8')
        print(forward_rules)
        
        client.close()
        
        print(f"\n{'='*60}")
        print("  КОНФИГУРАЦИЯ ОБНОВЛЕНА")
        print(f"{'='*60}\n")
        
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = update_wg_config()
    sys.exit(0 if success else 1)

