#!/usr/bin/env python3
"""
Исправление порта XRay (443 занят Docker, используем 4443)
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import paramiko
import json
import uuid

def fix_xray_port():
    """Исправляет порт XRay"""
    password = os.getenv("SSH_PASSWORD")
    if not password:
        print("✗ Задайте SSH_PASSWORD через переменную окружения.")
        sys.exit(1)
    host = "45.12.132.94"
    port = 22
    username = "root"

    xray_port = 4443  # Альтернативный порт
    
    print(f"\n{'='*60}")
    print(f"  ИСПРАВЛЕНИЕ ПОРТА XRAY")
    print(f"{'='*60}\n")
    print(f"Используем порт {xray_port} (443 занят Docker)\n")
    
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(hostname=host, port=port, username=username, password=password, timeout=10)
        print("✅ Подключение установлено\n")
        
        # Читаем текущую конфигурацию
        print("1. Чтение текущей конфигурации...")
        sftp = client.open_sftp()
        try:
            remote_file = sftp.file('/etc/xray/config.json', 'r')
            config_content = remote_file.read().decode('utf-8')
            remote_file.close()
            config = json.loads(config_content)
        except:
            config = {
                "log": {"loglevel": "warning"},
                "inbounds": [],
                "outbounds": [
                    {"protocol": "freedom", "settings": {}},
                    {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
                ],
                "routing": {
                    "rules": [
                        {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"}
                    ]
                }
            }
        finally:
            sftp.close()
        
        # Обновляем порт в конфигурации
        print(f"\n2. Обновление порта на {xray_port}...")
        
        # Ищем или создаем VLESS inbound
        vless_inbound = None
        for inbound in config.get('inbounds', []):
            if inbound.get('protocol') == 'vless':
                vless_inbound = inbound
                break
        
        if not vless_inbound:
            vless_inbound = {
                "port": xray_port,
                "protocol": "vless",
                "settings": {
                    "clients": [],
                    "decryption": "none"
                },
                "streamSettings": {
                    "network": "tcp",
                    "security": "none",
                    "tcpSettings": {
                        "acceptProxyProtocol": True
                    }
                }
            }
            config['inbounds'].append(vless_inbound)
        else:
            vless_inbound['port'] = xray_port
        
        # Сохраняем конфигурацию
        config_json = json.dumps(config, indent=2)
        sftp = client.open_sftp()
        try:
            remote_file = sftp.file('/etc/xray/config.json', 'w')
            remote_file.write(config_json)
            remote_file.close()
            print("   ✅ Конфигурация обновлена")
        finally:
            sftp.close()
        
        # Перезапускаем XRay
        print("\n3. Перезапуск XRay...")
        stdin, stdout, stderr = client.exec_command("systemctl restart xray-v2")
        exit_status = stdout.channel.recv_exit_status()
        
        if exit_status == 0:
            print("   ✅ XRay перезапущен")
        else:
            error = stderr.read().decode('utf-8')
            print(f"   ⚠️  Ошибка: {error}")
        
        # Проверяем порт
        print(f"\n4. Проверка порта {xray_port}...")
        stdin, stdout, stderr = client.exec_command(f"ss -tlnp | grep {xray_port} || netstat -tlnp | grep {xray_port}")
        port_check = stdout.read().decode('utf-8')
        if port_check.strip():
            print(f"   ✅ Порт {xray_port} слушается:")
            print(f"   {port_check}")
        else:
            print(f"   ⚠️  Порт {xray_port} не найден")
        
        # Проверяем статус
        print("\n5. Статус XRay...")
        stdin, stdout, stderr = client.exec_command("systemctl status xray-v2 --no-pager | head -5")
        status = stdout.read().decode('utf-8')
        print(status)
        
        client.close()
        
        print(f"\n{'='*60}")
        print("  ИСПРАВЛЕНИЕ ЗАВЕРШЕНО")
        print(f"{'='*60}\n")
        print(f"💡 XRay настроен на порту {xray_port}")
        print("   Обновите сервер в БД: xray_port = 4443")
        print(f"\n{'='*60}\n")
        
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = fix_xray_port()
    sys.exit(0 if success else 1)

