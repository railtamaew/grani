#!/usr/bin/env python3
"""
Настройка XRay на VPN сервере для обхода блокировок в России.
Для продакшена с большим числом клиентов см. docs/VPN_NODE_TUNING.md (LimitNOFILE, TCP-буферы).
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import paramiko
import json
import uuid

def setup_xray():
    """Настраивает XRay на сервере"""
    password = os.getenv("SSH_PASSWORD")
    if not password:
        print("✗ Задайте SSH_PASSWORD через переменную окружения.")
        sys.exit(1)
    host = "45.12.132.94"
    port = 22
    username = "root"

    print(f"\n{'='*60}")
    print(f"  НАСТРОЙКА XRAY НА СЕРВЕРЕ")
    print(f"{'='*60}\n")
    print("⚠️  ВАЖНО: XRay обходит блокировки DPI в России")
    print("   Используется порт 443 (HTTPS) для маскировки\n")
    
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(hostname=host, port=port, username=username, password=password, timeout=10)
        print("✅ Подключение установлено\n")
        
        # 1. Проверяем, установлен ли XRay
        print("1. Проверка установки XRay...")
        stdin, stdout, stderr = client.exec_command("which xray || echo 'не установлен'")
        xray_path = stdout.read().decode('utf-8').strip()
        
        if "не установлен" in xray_path:
            print("   ⚠️  XRay не установлен. Устанавливаем...")
            # Установка XRay
            install_script = """
            bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
            """
            stdin, stdout, stderr = client.exec_command(install_script)
            output = stdout.read().decode('utf-8')
            error = stderr.read().decode('utf-8')
            
            if "installed" in output.lower() or "success" in output.lower():
                print("   ✅ XRay установлен")
            else:
                print(f"   ⚠️  Ошибка установки: {error}")
                print("   Попробуем альтернативный способ...")
                # Альтернативная установка
                client.exec_command("bash -c 'bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)'")
        else:
            print(f"   ✅ XRay уже установлен: {xray_path}")
        
        # 2. Создаем базовую конфигурацию XRay
        print("\n2. Создание конфигурации XRay...")
        
        # Генерируем UUID для сервера
        server_uuid = str(uuid.uuid4())
        
        xray_config = {
            "log": {
                "loglevel": "warning"
            },
            "inbounds": [
                {
                    "port": 443,
                    "protocol": "vless",
                    "settings": {
                        "clients": [],
                        "decryption": "none",
                    },
                    "streamSettings": {
                        "network": "tcp",
                        "security": "none",
                        "tcpSettings": {
                            "acceptProxyProtocol": True
                        }
                    }
                },
                {
                    "port": 10085,
                    "protocol": "dokodemo-door",
                    "settings": {
                        "address": "127.0.0.1"
                    }
                }
            ],
            "outbounds": [
                {
                    "protocol": "freedom",
                    "settings": {}
                },
                {
                    "protocol": "blackhole",
                    "settings": {},
                    "tag": "blocked"
                }
            ],
            "routing": {
                "rules": [
                    {
                        "type": "field",
                        "ip": ["geoip:private"],
                        "outboundTag": "blocked"
                    }
                ]
            }
        }
        
        # Создаем директорию если нет
        client.exec_command("mkdir -p /etc/xray")
        
        # Загружаем конфигурацию
        config_json = json.dumps(xray_config, indent=2)
        sftp = client.open_sftp()
        try:
            remote_file = sftp.file('/etc/xray/config.json', 'w')
            remote_file.write(config_json)
            remote_file.close()
            print("   ✅ Конфигурация создана")
        finally:
            sftp.close()
        
        client.exec_command("chmod 644 /etc/xray/config.json")
        
        # 3. Запускаем XRay
        print("\n3. Запуск XRay...")
        client.exec_command("systemctl stop xray-v2 2>/dev/null || true")
        client.exec_command("systemctl enable xray")
        stdin, stdout, stderr = client.exec_command("systemctl start xray-v2")
        exit_status = stdout.channel.recv_exit_status()
        
        if exit_status == 0:
            print("   ✅ XRay запущен")
        else:
            error = stderr.read().decode('utf-8')
            print(f"   ⚠️  Ошибка запуска: {error}")
        
        # 4. Проверяем статус
        print("\n4. Проверка статуса...")
        stdin, stdout, stderr = client.exec_command("systemctl status xray-v2 --no-pager | head -10")
        status = stdout.read().decode('utf-8')
        print(status)

        # 4b. LimitNOFILE для большого числа соединений (см. docs/VPN_NODE_TUNING.md)
        print("\n4b. Настройка LimitNOFILE для Xray...")
        try:
            client.exec_command("mkdir -p /etc/systemd/system/xray.service.d")
            sftp = client.open_sftp()
            try:
                with sftp.file("/etc/systemd/system/xray.service.d/override.conf", "w") as f:
                    f.write("[Service]\nLimitNOFILE=65536\n")
            finally:
                sftp.close()
            stdin, stdout, stderr = client.exec_command("systemctl daemon-reload && systemctl restart xray-v2")
            stdout.channel.recv_exit_status()
            print("   ✅ LimitNOFILE=65536 установлен, Xray перезапущен")
        except Exception as e:
            print(f"   ⚠️  Не удалось установить LimitNOFILE: {e}")
        
        # 5. Проверяем порт
        print("\n5. Проверка порта 443...")
        stdin, stdout, stderr = client.exec_command("ss -tlnp | grep 443 || netstat -tlnp | grep 443")
        port_check = stdout.read().decode('utf-8')
        if port_check.strip():
            print(f"   ✅ Порт 443 слушается:")
            print(f"   {port_check}")
        else:
            print("   ⚠️  Порт 443 не найден")
        
        client.close()
        
        print(f"\n{'='*60}")
        print("  НАСТРОЙКА ЗАВЕРШЕНА")
        print(f"{'='*60}\n")
        print("💡 Следующие шаги:")
        print("   1. Обновите сервер в БД - добавьте xray_port = 443")
        print("   2. Используйте протокол 'xray_vless' или 'xray_vmess' в мобильном приложении")
        print("   3. XRay использует порт 443 (HTTPS) и обходит блокировки DPI")
        print(f"\n{'='*60}\n")
        
        return True
        
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = setup_xray()
    sys.exit(0 if success else 1)

