#!/usr/bin/env python3
"""
Исправление конфигурации WireGuard (убираем DNS, чтобы избежать ошибки resolvconf)
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import paramiko

def fix_wireguard_config():
    """Исправляет конфигурацию WireGuard"""
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
    print(f"  ИСПРАВЛЕНИЕ КОНФИГУРАЦИИ WIREGUARD")
    print(f"{'='*60}\n")
    
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(hostname=host, port=port, username=username, password=password, timeout=10)
        print("✅ Подключение установлено\n")
        
        # Получаем приватный ключ сервера
        stdin, stdout, stderr = client.exec_command("cat /etc/wireguard/private.key")
        server_private_key = stdout.read().decode('utf-8').strip()
        
        # Определяем интерфейс
        stdin, stdout, stderr = client.exec_command("ip route | grep default | awk '{print $5}' | head -n1")
        main_interface = stdout.read().decode('utf-8').strip()
        
        # Создаем конфигурацию БЕЗ DNS (чтобы избежать ошибки resolvconf)
        wg_config = f"""[Interface]
PrivateKey = {server_private_key}
Address = 10.0.0.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o {main_interface} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o {main_interface} -j MASQUERADE

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
            print("✅ Конфигурация обновлена (DNS удален)")
        finally:
            sftp.close()
        
        client.exec_command("chmod 600 /etc/wireguard/wg0.conf")
        
        # Останавливаем и запускаем заново
        print("\nПерезапуск WireGuard...")
        client.exec_command("wg-quick down wg0 2>/dev/null || true")
        
        stdin, stdout, stderr = client.exec_command("wg-quick up wg0")
        output = stdout.read().decode('utf-8')
        error = stderr.read().decode('utf-8')
        
        if "error" not in error.lower() and "failed" not in error.lower():
            print("✅ WireGuard запущен успешно")
        else:
            print(f"⚠️  Ошибка: {error}")
            print(f"   Вывод: {output}")
        
        # Проверяем статус
        print("\nПроверка статуса...")
        stdin, stdout, stderr = client.exec_command("wg show")
        wg_status = stdout.read().decode('utf-8')
        
        if wg_status.strip():
            print("✅ Статус WireGuard:")
            print(wg_status)
            
            if client_public_key[:20] in wg_status:
                print(f"\n✅ Пир клиента найден!")
            else:
                print(f"\n⚠️  Пир клиента не найден в статусе")
        else:
            print("⚠️  WireGuard не запущен")
        
        client.close()
        print(f"\n{'='*60}\n")
        
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = fix_wireguard_config()
    sys.exit(0 if success else 1)

