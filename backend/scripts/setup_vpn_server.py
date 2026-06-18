#!/usr/bin/env python3
"""
Настройка VPN сервера через SSH
Создает конфигурацию WireGuard, добавляет пир, настраивает iptables
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import paramiko
from core.database import SessionLocal
from sqlalchemy import text

def setup_vpn_server():
    """Настраивает VPN сервер"""
    password = os.getenv("SSH_PASSWORD")
    if not password:
        print("✗ Задайте SSH_PASSWORD через переменную окружения.")
        sys.exit(1)
    host = "45.12.132.94"
    port = 22
    username = "root"

    # Данные клиента из wg0.conf
    client_public_key = "TVg3PioAwVBCbPxC9I0vRGI8YokqnMx7NlBDoPZrgCo="
    client_ip = "10.0.0.2/32"
    
    print(f"\n{'='*60}")
    print(f"  НАСТРОЙКА VPN СЕРВЕРА")
    print(f"{'='*60}\n")
    print(f"Сервер: {username}@{host}:{port}")
    
    try:
        # Подключаемся к серверу
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(hostname=host, port=port, username=username, password=password, timeout=10)
        print("✅ Подключение установлено\n")
        
        # 1. Получаем ключи сервера
        print("1. Получение ключей сервера...")
        stdin, stdout, stderr = client.exec_command("cat /etc/wireguard/private.key")
        server_private_key = stdout.read().decode('utf-8').strip()
        
        stdin, stdout, stderr = client.exec_command("cat /etc/wireguard/public.key")
        server_public_key = stdout.read().decode('utf-8').strip()
        
        if not server_private_key or not server_public_key:
            print("❌ Ключи сервера не найдены. Генерируем новые...")
            client.exec_command("wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key")
            client.exec_command("chmod 600 /etc/wireguard/private.key")
            client.exec_command("chmod 644 /etc/wireguard/public.key")
            
            stdin, stdout, stderr = client.exec_command("cat /etc/wireguard/private.key")
            server_private_key = stdout.read().decode('utf-8').strip()
            
            stdin, stdout, stderr = client.exec_command("cat /etc/wireguard/public.key")
            server_public_key = stdout.read().decode('utf-8').strip()
        
        print(f"   ✅ Приватный ключ: {server_private_key[:20]}...")
        print(f"   ✅ Публичный ключ: {server_public_key[:20]}...")
        
        # 2. Определяем основной интерфейс
        print("\n2. Определение сетевого интерфейса...")
        stdin, stdout, stderr = client.exec_command("ip route | grep default | awk '{print $5}' | head -n1")
        main_interface = stdout.read().decode('utf-8').strip()
        print(f"   ✅ Основной интерфейс: {main_interface}")
        
        # 3. Создаем конфигурацию WireGuard
        print("\n3. Создание конфигурации WireGuard...")
        wg_config = f"""[Interface]
PrivateKey = {server_private_key}
Address = 10.0.0.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o {main_interface} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o {main_interface} -j MASQUERADE

# DNS
DNS = 8.8.8.8, 8.8.4.4

# MTU
MTU = 1420

# Сохранение конфигурации
SaveConfig = true

# Peer for client
[Peer]
PublicKey = {client_public_key}
AllowedIPs = {client_ip}
"""
        
        # Загружаем конфигурацию на сервер
        sftp = client.open_sftp()
        try:
            remote_file = sftp.file('/etc/wireguard/wg0.conf', 'w')
            remote_file.write(wg_config)
            remote_file.close()
            print("   ✅ Конфигурация создана")
        finally:
            sftp.close()
        
        # Устанавливаем права
        client.exec_command("chmod 600 /etc/wireguard/wg0.conf")
        print("   ✅ Права доступа установлены")
        
        # 4. Включаем IP forwarding (если еще не включен)
        print("\n4. Проверка IP forwarding...")
        stdin, stdout, stderr = client.exec_command("sysctl net.ipv4.ip_forward | awk '{print $3}'")
        ip_forward = stdout.read().decode('utf-8').strip()
        
        if ip_forward != "1":
            print("   ⚠️  IP forwarding отключен, включаем...")
            client.exec_command("sysctl -w net.ipv4.ip_forward=1")
            client.exec_command("echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf")
            print("   ✅ IP forwarding включен")
        else:
            print("   ✅ IP forwarding уже включен")
        
        # 5. Настраиваем iptables правила
        print("\n5. Настройка iptables правил...")
        
        # Проверяем существующие правила
        stdin, stdout, stderr = client.exec_command("iptables -C FORWARD -i wg0 -j ACCEPT 2>&1")
        forward_exists = stdout.read().decode('utf-8').strip() == ""
        
        stdin, stdout, stderr = client.exec_command(f"iptables -t nat -L POSTROUTING -n -v | grep -q MASQUERADE && echo 'OK' || echo 'MISSING'")
        masq_exists = "OK" in stdout.read().decode('utf-8')
        
        if not forward_exists:
            print("   Добавление правила FORWARD...")
            client.exec_command("iptables -A FORWARD -i wg0 -j ACCEPT")
            print("   ✅ Правило FORWARD добавлено")
        else:
            print("   ✅ Правило FORWARD уже существует")
        
        if not masq_exists:
            print(f"   Добавление правила MASQUERADE для {main_interface}...")
            client.exec_command(f"iptables -t nat -A POSTROUTING -o {main_interface} -j MASQUERADE")
            print("   ✅ Правило MASQUERADE добавлено")
        else:
            print("   ✅ Правило MASQUERADE уже существует")
        
        # 6. Запускаем WireGuard
        print("\n6. Запуск WireGuard...")
        
        # Останавливаем если запущен
        client.exec_command("wg-quick down wg0 2>/dev/null || true")
        
        # Запускаем
        stdin, stdout, stderr = client.exec_command("wg-quick up wg0")
        exit_status = stdout.channel.recv_exit_status()
        
        if exit_status == 0:
            print("   ✅ WireGuard запущен")
        else:
            error = stderr.read().decode('utf-8')
            print(f"   ⚠️  Ошибка запуска: {error}")
        
        # Включаем автозапуск
        client.exec_command("systemctl enable wg-quick@wg0 2>/dev/null || true")
        print("   ✅ Автозапуск настроен")
        
        # 7. Проверяем статус
        print("\n7. Проверка статуса...")
        stdin, stdout, stderr = client.exec_command("wg show")
        wg_status = stdout.read().decode('utf-8')
        
        if wg_status.strip():
            print("   ✅ Статус WireGuard:")
            print(f"   {wg_status}")
        else:
            print("   ⚠️  WireGuard не запущен")
        
        # Проверяем пир
        if client_public_key[:20] in wg_status:
            print(f"\n   ✅ Пир клиента найден в конфигурации")
        else:
            print(f"\n   ⚠️  Пир клиента не найден, но должен быть добавлен")
        
        client.close()
        
        print(f"\n{'='*60}")
        print("  НАСТРОЙКА ЗАВЕРШЕНА")
        print(f"{'='*60}\n")
        
        # Обновляем публичный ключ сервера в БД
        print("Обновление базы данных...")
        db = SessionLocal()
        try:
            result = db.execute(text("""
                UPDATE servers 
                SET wireguard_public_key = :public_key
                WHERE ip_address = :ip
            """), {
                "public_key": server_public_key,
                "ip": host
            })
            db.commit()
            print(f"✅ Публичный ключ сервера обновлен в БД: {server_public_key[:20]}...")
        except Exception as e:
            print(f"⚠️  Ошибка обновления БД: {e}")
        finally:
            db.close()
        
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = setup_vpn_server()
    sys.exit(0 if success else 1)

