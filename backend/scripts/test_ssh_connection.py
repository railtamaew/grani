#!/usr/bin/env python3
"""
Тест SSH подключения к VPN серверу
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

try:
    import paramiko
    PARAMIKO_AVAILABLE = True
except ImportError:
    print("❌ paramiko не установлен. Установите: pip install paramiko")
    sys.exit(1)

def test_ssh_connection():
    """Тестирует SSH подключение к серверу"""
    password = os.getenv("SSH_PASSWORD")
    if not password:
        print("✗ Задайте SSH_PASSWORD через переменную окружения.")
        sys.exit(1)
    host = "45.12.132.94"
    port = 22
    username = "root"

    print(f"\n{'='*60}")
    print(f"  ТЕСТ SSH ПОДКЛЮЧЕНИЯ К СЕРВЕРУ")
    print(f"{'='*60}\n")
    print(f"Сервер: {username}@{host}:{port}")
    
    try:
        # Создаем SSH клиент
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        
        print("Подключение...")
        client.connect(
            hostname=host,
            port=port,
            username=username,
            password=password,
            timeout=10
        )
        
        print("✅ Подключение успешно!\n")
        
        # Выполняем тестовые команды
        commands = [
            ("hostname", "Имя хоста"),
            ("whoami", "Текущий пользователь"),
            ("uname -a", "Информация о системе"),
            ("wg --version 2>/dev/null || echo 'WireGuard не установлен'", "Версия WireGuard"),
            ("sysctl net.ipv4.ip_forward", "IP Forwarding"),
            ("ip route | grep default | awk '{print $5}' | head -n1", "Основной сетевой интерфейс"),
            ("ls -la /etc/wireguard/ 2>/dev/null || echo 'Директория не существует'", "Конфигурация WireGuard"),
        ]
        
        for cmd, description in commands:
            print(f"\n{description}:")
            print(f"  Команда: {cmd}")
            stdin, stdout, stderr = client.exec_command(cmd)
            output = stdout.read().decode('utf-8').strip()
            error = stderr.read().decode('utf-8').strip()
            
            if output:
                print(f"  Результат: {output}")
            if error and "No such file" not in error:
                print(f"  Ошибка: {error}")
        
        # Проверяем конфигурацию WireGuard
        print(f"\n{'='*60}")
        print("  ПРОВЕРКА WIREGUARD")
        print(f"{'='*60}\n")
        
        # Проверяем наличие конфигурации
        stdin, stdout, stderr = client.exec_command("cat /etc/wireguard/wg0.conf 2>/dev/null || echo 'Файл не существует'")
        config = stdout.read().decode('utf-8')
        
        if "не существует" not in config:
            print("✅ Конфигурация WireGuard найдена:")
            print(config[:500] + "..." if len(config) > 500 else config)
        else:
            print("❌ Конфигурация WireGuard не найдена")
        
        # Проверяем статус WireGuard
        stdin, stdout, stderr = client.exec_command("wg show 2>&1")
        wg_status = stdout.read().decode('utf-8')
        wg_error = stderr.read().decode('utf-8')
        
        if wg_status.strip():
            print("\n✅ Статус WireGuard:")
            print(wg_status)
        elif "No such device" in wg_error:
            print("\n⚠️  WireGuard интерфейс не запущен")
        else:
            print("\n⚠️  Не удалось получить статус WireGuard")
        
        client.close()
        print(f"\n{'='*60}")
        print("  ПОДКЛЮЧЕНИЕ ЗАКРЫТО")
        print(f"{'='*60}\n")
        
        return True
        
    except paramiko.AuthenticationException:
        print("❌ Ошибка аутентификации: неверный логин или пароль")
        return False
    except paramiko.SSHException as e:
        print(f"❌ Ошибка SSH: {e}")
        return False
    except Exception as e:
        print(f"❌ Ошибка подключения: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = test_ssh_connection()
    sys.exit(0 if success else 1)

