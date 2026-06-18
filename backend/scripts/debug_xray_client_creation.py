#!/usr/bin/env python3
"""
Отладка создания XRay клиента
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import paramiko
import json
import uuid

def debug_xray_client():
    """Отладка создания XRay клиента"""
    password = os.getenv("SSH_PASSWORD")
    if not password:
        print("✗ Задайте SSH_PASSWORD через переменную окружения.")
        sys.exit(1)
    host = "45.12.132.94"
    port = 22
    username = "root"

    print(f"\n{'='*60}")
    print(f"  ОТЛАДКА СОЗДАНИЯ XRAY КЛИЕНТА")
    print(f"{'='*60}\n")
    
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(hostname=host, port=port, username=username, password=password, timeout=10)
        print("✅ SSH подключение установлено\n")
        
        # 1. Проверяем конфигурацию
        print("1. Чтение конфигурации XRay...")
        sftp = client.open_sftp()
        try:
            remote_file = sftp.file('/usr/local/etc/xray/config.json', 'r')
            config_content = remote_file.read().decode('utf-8')
            remote_file.close()
            config = json.loads(config_content)
            print("   ✅ Конфигурация прочитана")
            print(f"   Inbounds: {len(config.get('inbounds', []))}")
        except Exception as e:
            print(f"   ❌ Ошибка чтения: {e}")
            return False
        finally:
            sftp.close()
        
        # 2. Находим VLESS inbound
        print("\n2. Поиск VLESS inbound...")
        vless_inbound = None
        for inbound in config.get('inbounds', []):
            if inbound.get('protocol') == 'vless':
                vless_inbound = inbound
                print(f"   ✅ VLESS inbound найден на порту {inbound.get('port')}")
                print(f"   Текущих клиентов: {len(inbound.get('settings', {}).get('clients', []))}")
                break
        
        if not vless_inbound:
            print("   ❌ VLESS inbound не найден!")
            return False
        
        # 3. Добавляем тестового клиента
        print("\n3. Добавление тестового клиента...")
        client_uuid = str(uuid.uuid4())
        client_config = {
            'id': client_uuid,
            'level': 0,
            'email': 'test@granivpn.com'
        }
        
        clients = vless_inbound.get('settings', {}).get('clients', [])
        clients.append(client_config)
        vless_inbound['settings']['clients'] = clients
        
        print(f"   ✅ Клиент добавлен: {client_uuid}")
        print(f"   Всего клиентов: {len(clients)}")
        
        # 4. Сохраняем конфигурацию
        print("\n4. Сохранение конфигурации...")
        config_json = json.dumps(config, indent=2)
        sftp = client.open_sftp()
        try:
            remote_file = sftp.file('/usr/local/etc/xray/config.json', 'w')
            remote_file.write(config_json)
            remote_file.close()
            print("   ✅ Конфигурация сохранена")
        except Exception as e:
            print(f"   ❌ Ошибка сохранения: {e}")
            return False
        finally:
            sftp.close()
        
        # 5. Проверяем валидность JSON
        print("\n5. Проверка валидности JSON...")
        stdin, stdout, stderr = client.exec_command("python3 -m json.tool /usr/local/etc/xray/config.json > /dev/null 2>&1 && echo 'OK' || echo 'ERROR'")
        result = stdout.read().decode('utf-8').strip()
        if result == 'OK':
            print("   ✅ JSON валиден")
        else:
            error = stderr.read().decode('utf-8')
            print(f"   ❌ JSON невалиден: {error}")
            return False
        
        # 6. Перезагружаем XRay
        print("\n6. Перезагрузка XRay...")
        stdin, stdout, stderr = client.exec_command("systemctl reload xray-v2")
        exit_status = stdout.channel.recv_exit_status()
        
        if exit_status == 0:
            print("   ✅ XRay перезагружен")
        else:
            error = stderr.read().decode('utf-8')
            print(f"   ⚠️  Ошибка перезагрузки: {error}")
            # Пробуем restart
            print("   Пробуем restart...")
            stdin, stdout, stderr = client.exec_command("systemctl restart xray-v2")
            exit_status = stdout.channel.recv_exit_status()
            if exit_status == 0:
                print("   ✅ XRay перезапущен")
            else:
                error = stderr.read().decode('utf-8')
                print(f"   ❌ Ошибка: {error}")
        
        # 7. Проверяем статус
        print("\n7. Проверка статуса XRay...")
        stdin, stdout, stderr = client.exec_command("systemctl status xray-v2 --no-pager | head -5")
        status = stdout.read().decode('utf-8')
        print(status)
        
        # 8. Проверяем клиентов
        print("\n8. Проверка клиентов в конфигурации...")
        stdin, stdout, stderr = client.exec_command("cat /usr/local/etc/xray/config.json | python3 -c \"import sys, json; data=json.load(sys.stdin); inbounds=[i for i in data.get('inbounds', []) if i.get('protocol')=='vless']; print('Clients:', len(inbounds[0].get('settings', {}).get('clients', [])) if inbounds else 0)\"")
        clients_count = stdout.read().decode('utf-8').strip()
        print(f"   Клиентов в конфигурации: {clients_count}")
        
        client.close()
        
        print(f"\n{'='*60}")
        print("  ОТЛАДКА ЗАВЕРШЕНА")
        print(f"{'='*60}\n")
        print(f"💡 Тестовый клиент добавлен: {client_uuid}")
        print(f"\n{'='*60}\n")
        
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = debug_xray_client()
    sys.exit(0 if success else 1)

