#!/usr/bin/env python3
"""
Настройка XRay на сервере для работы с клиентами
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import paramiko
import json
import uuid

def setup_xray_for_clients():
    """Настраивает XRay для работы с клиентами"""
    password = os.getenv("SSH_PASSWORD")
    if not password:
        print("✗ Задайте SSH_PASSWORD через переменную окружения.")
        sys.exit(1)
    host = "45.12.132.94"
    port = 22
    username = "root"

    print(f"\n{'='*60}")
    print(f"  НАСТРОЙКА XRAY ДЛЯ РАБОТЫ С КЛИЕНТАМИ")
    print(f"{'='*60}\n")
    
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(hostname=host, port=port, username=username, password=password, timeout=10)
        print("✅ Подключение установлено\n")
        
        # Читаем текущую конфигурацию
        print("1. Чтение текущей конфигурации XRay...")
        sftp = client.open_sftp()
        try:
            try:
                remote_file = sftp.file('/usr/local/etc/xray/config.json', 'r')
                config_content = remote_file.read().decode('utf-8')
                remote_file.close()
                config = json.loads(config_content)
                print("   ✅ Конфигурация прочитана")
            except:
                # Если файла нет, создаем базовую конфигурацию
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
                print("   ⚠️  Конфигурация не найдена, создаем новую")
        finally:
            sftp.close()
        
        # Находим или создаем VLESS inbound
        print("\n2. Настройка VLESS inbound...")
        vless_inbound = None
        for inbound in config.get('inbounds', []):
            if inbound.get('protocol') == 'vless':
                vless_inbound = inbound
                break
        
        if not vless_inbound:
            vless_inbound = {
                "port": 4443,
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
            print("   ✅ VLESS inbound создан")
        else:
            print("   ✅ VLESS inbound найден")
            # Убеждаемся, что порт правильный
            if vless_inbound.get('port') != 4443:
                vless_inbound['port'] = 4443
                print(f"   ✅ Порт обновлен на 4443")
        
        # Убеждаемся, что есть список clients
        if 'clients' not in vless_inbound.get('settings', {}):
            vless_inbound['settings']['clients'] = []
        
        # Сохраняем конфигурацию
        print("\n3. Сохранение конфигурации...")
        config_json = json.dumps(config, indent=2)
        sftp = client.open_sftp()
        try:
            remote_file = sftp.file('/usr/local/etc/xray/config.json', 'w')
            remote_file.write(config_json)
            remote_file.close()
            print("   ✅ Конфигурация сохранена")
        finally:
            sftp.close()
        
        client.exec_command("chmod 644 /usr/local/etc/xray/config.json")
        
        # Перезапускаем XRay
        print("\n4. Перезапуск XRay...")
        stdin, stdout, stderr = client.exec_command("systemctl restart xray-v2")
        exit_status = stdout.channel.recv_exit_status()
        
        if exit_status == 0:
            print("   ✅ XRay перезапущен")
        else:
            error = stderr.read().decode('utf-8')
            print(f"   ⚠️  Ошибка: {error}")
        
        # Проверяем статус
        print("\n5. Проверка статуса...")
        stdin, stdout, stderr = client.exec_command("systemctl status xray-v2 --no-pager | head -5")
        status = stdout.read().decode('utf-8')
        print(status)
        
        # Проверяем порт
        stdin, stdout, stderr = client.exec_command("ss -tlnp | grep 4443")
        port_check = stdout.read().decode('utf-8')
        if port_check.strip():
            print(f"\n✅ Порт 4443 слушается:")
            print(port_check)
        else:
            print("\n⚠️  Порт 4443 не найден")
        
        # Показываем текущую конфигурацию
        print("\n6. Текущая конфигурация VLESS:")
        stdin, stdout, stderr = client.exec_command("cat /usr/local/etc/xray/config.json | python3 -m json.tool | grep -A 20 'vless'")
        vless_config = stdout.read().decode('utf-8')
        print(vless_config[:500] if len(vless_config) > 500 else vless_config)
        
        client.close()
        
        print(f"\n{'='*60}")
        print("  НАСТРОЙКА ЗАВЕРШЕНА")
        print(f"{'='*60}\n")
        print("💡 Теперь можно подключать клиентов через XRay VLESS")
        print(f"\n{'='*60}\n")
        
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = setup_xray_for_clients()
    sys.exit(0 if success else 1)

