#!/usr/bin/env python3
"""
Исправление пути конфигурации XRay
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import paramiko
import json
import time

def fix_config_path():
    """Исправляет путь конфигурации XRay"""
    password = os.getenv("SSH_PASSWORD")
    if not password:
        print("✗ Задайте SSH_PASSWORD через переменную окружения.")
        sys.exit(1)
    host = "45.12.132.94"
    port = 22
    username = "root"

    print(f"\n{'='*60}")
    print(f"  ИСПРАВЛЕНИЕ ПУТИ КОНФИГУРАЦИИ XRAY")
    print(f"{'='*60}\n")
    
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(hostname=host, port=port, username=username, password=password, timeout=10)
        print("✅ Подключение установлено\n")
        
        # Читаем конфигурацию из /etc/xray/config.json
        print("1. Чтение конфигурации...")
        sftp = client.open_sftp()
        try:
            remote_file = sftp.file('/etc/xray/config.json', 'r')
            config_content = remote_file.read().decode('utf-8')
            remote_file.close()
            config = json.loads(config_content)
            print("   ✅ Конфигурация прочитана")
        except Exception as e:
            print(f"   ⚠️  Ошибка чтения: {e}")
            # Создаем базовую конфигурацию
            config = {
                "log": {"loglevel": "warning"},
                "inbounds": [
                    {
                        "port": 4443,
                        "protocol": "vless",
                        "settings": {
                            "clients": [],
                            "decryption": "none"
                        },
                        "streamSettings": {
                            "network": "tcp",
                            "security": "none"
                        }
                    }
                ],
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
        
        # Сохраняем в правильное место
        print("\n2. Сохранение конфигурации в /usr/local/etc/xray/config.json...")
        client.exec_command("mkdir -p /usr/local/etc/xray")
        
        config_json = json.dumps(config, indent=2)
        try:
            remote_file = sftp.file('/usr/local/etc/xray/config.json', 'w')
            remote_file.write(config_json)
            remote_file.close()
            print("   ✅ Конфигурация сохранена")
        finally:
            sftp.close()
        
        client.exec_command("chmod 644 /usr/local/etc/xray/config.json")
        
        # Перезапускаем XRay
        print("\n3. Перезапуск XRay...")
        stdin, stdout, stderr = client.exec_command("systemctl restart xray-v2")
        exit_status = stdout.channel.recv_exit_status()
        
        if exit_status == 0:
            print("   ✅ XRay перезапущен")
        else:
            error = stderr.read().decode('utf-8')
            print(f"   ⚠️  Ошибка: {error}")
        
        time.sleep(2)
        
        # Проверяем порт
        print("\n4. Проверка порта 4443...")
        stdin, stdout, stderr = client.exec_command("ss -tlnp | grep 4443")
        port_check = stdout.read().decode('utf-8')
        if port_check.strip():
            print(f"   ✅ Порт 4443 слушается:")
            print(f"   {port_check}")
        else:
            print("   ⚠️  Порт 4443 не найден")
            print("   Проверяем логи...")
            stdin, stdout, stderr = client.exec_command("journalctl -u xray-v2 -n 10 --no-pager")
            logs = stdout.read().decode('utf-8')
            print(logs)
        
        # Проверяем статус
        print("\n5. Статус XRay...")
        stdin, stdout, stderr = client.exec_command("systemctl status xray-v2 --no-pager | head -10")
        status = stdout.read().decode('utf-8')
        print(status)
        
        client.close()
        
        print(f"\n{'='*60}")
        print("  ИСПРАВЛЕНИЕ ЗАВЕРШЕНО")
        print(f"{'='*60}\n")
        
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = fix_config_path()
    sys.exit(0 if success else 1)

