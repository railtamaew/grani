#!/usr/bin/env python3
"""
Интерактивный инструмент для тестирования VPN в Cursor
Позволяет подключаться/отключаться, тестировать протоколы, измерять скорость
"""
import sys
import os
import time
import json
import requests
import subprocess
from typing import Optional, Dict, List
from datetime import datetime

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from core.database import SessionLocal
from services.auth_service import AuthService
from sqlalchemy import text

class VPNTester:
    def __init__(self, email: str, api_base_url: str = "https://api.granilink.com"):
        self.email = email
        self.api_base_url = api_base_url
        self.token: Optional[str] = None
        # Используем фиксированный device_id для тестирования, чтобы не создавать много устройств
        self.device_id = f"cursor-vpn-tester-{os.getenv('USER', 'user')}"
        self.current_connection: Optional[Dict] = None
        
    def get_token(self) -> bool:
        """Получает токен для пользователя"""
        db = SessionLocal()
        try:
            conn = db.connection()
            
            # Получаем user_id через SQL запрос
            result = conn.execute(text("""
                SELECT id FROM users WHERE email = :email AND is_active = true
            """), {"email": self.email.lower().strip()})
            
            user_row = result.fetchone()
            if not user_row:
                print(f"❌ Пользователь {self.email} не найден или неактивен")
                return False
            
            user_id = user_row[0]
            self.token = AuthService.create_access_token(user_id)
            print(f"✅ Токен получен для {self.email} (ID: {user_id})")
            return True
        except Exception as e:
            print(f"❌ Ошибка получения токена: {e}")
            import traceback
            traceback.print_exc()
            return False
        finally:
            db.close()
    
    def _get_headers(self) -> Dict[str, str]:
        """Возвращает заголовки с токеном"""
        return {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json"
        }
    
    def get_servers(self) -> List[Dict]:
        """Получает список серверов"""
        try:
            response = requests.get(
                f"{self.api_base_url}/api/vpn/servers",
                headers=self._get_headers(),
                timeout=10
            )
            if response.status_code == 200:
                return response.json()
            else:
                print(f"❌ Ошибка получения серверов: {response.status_code}")
                print(response.text)
                return []
        except Exception as e:
            print(f"❌ Ошибка запроса: {e}")
            return []
    
    def get_devices(self) -> List[Dict]:
        """Получает список устройств пользователя"""
        try:
            response = requests.get(
                f"{self.api_base_url}/api/vpn/devices",
                headers=self._get_headers(),
                timeout=10
            )
            if response.status_code == 200:
                return response.json()
            else:
                print(f"⚠️  Ошибка получения устройств: {response.status_code}")
                return []
        except Exception as e:
            print(f"⚠️  Ошибка получения устройств: {e}")
            return []
    
    def register_device(self) -> bool:
        """Регистрирует тестовое устройство или использует существующее"""
        # Сначала пытаемся получить список существующих устройств
        devices = self.get_devices()
        
        if devices:
            # Используем первое доступное устройство
            existing_device = devices[0]
            self.device_id = existing_device.get('device_id') or existing_device.get('id')
            print(f"✅ Используем существующее устройство: {self.device_id}")
            print(f"   Название: {existing_device.get('name', 'N/A')}")
            return True
        
        # Если устройств нет, пытаемся зарегистрировать новое
        try:
            response = requests.post(
                f"{self.api_base_url}/api/vpn/device/register",
                headers=self._get_headers(),
                json={
                    "device_id": self.device_id,
                    "name": "Cursor Test Device",
                    "platform": "linux"
                },
                timeout=10
            )
            if response.status_code in [200, 201]:
                print(f"✅ Устройство зарегистрировано: {self.device_id}")
                return True
            else:
                # Устройство может быть уже зарегистрировано или достигнут лимит
                if response.status_code == 400:
                    error_text = response.text
                    if "лимит устройств" in error_text.lower() or "limit" in error_text.lower():
                        print(f"⚠️  Достигнут лимит устройств. Пытаемся использовать существующее...")
                        # Пытаемся снова получить устройства
                        devices = self.get_devices()
                        if devices:
                            existing_device = devices[0]
                            self.device_id = existing_device.get('device_id') or existing_device.get('id')
                            print(f"✅ Используем существующее устройство: {self.device_id}")
                            return True
                        else:
                            print(f"❌ Не удалось найти существующие устройства")
                            return False
                    else:
                        print(f"⚠️  Ошибка регистрации: {error_text}")
                        return False
                print(f"❌ Ошибка регистрации: {response.status_code}")
                print(response.text)
                return False
        except Exception as e:
            print(f"❌ Ошибка регистрации устройства: {e}")
            return False
    
    def connect(self, server_id: int, protocol: str = "wireguard") -> bool:
        """Подключается к VPN"""
        # Проверяем, что device_id установлен
        if not self.device_id:
            print("❌ Ошибка: device_id не установлен. Попробуйте обновить список устройств (пункт 8).")
            return False
        
        try:
            print(f"🔌 Подключение к серверу {server_id} через {protocol}...")
            print(f"   Используется устройство: {self.device_id}")
            response = requests.post(
                f"{self.api_base_url}/api/vpn/connect",
                headers=self._get_headers(),
                json={
                    "server_id": server_id,
                    "device_id": self.device_id,
                    "protocol": protocol
                },
                timeout=30
            )
            
            if response.status_code == 200:
                result = response.json()
                self.current_connection = {
                    "server_id": server_id,
                    "protocol": protocol,
                    "result": result
                }
                print(f"✅ Подключение установлено!")
                print(f"   Результат: {json.dumps(result, indent=2)}")
                return True
            elif response.status_code == 400:
                error_text = response.text
                # Проверяем, не связано ли это с устройством
                if "устройство не найдено" in error_text.lower() or "device" in error_text.lower():
                    print(f"⚠️  Устройство {self.device_id} не найдено. Ищем существующие устройства...")
                    devices = self.get_devices()
                    if devices:
                        existing_device = devices[0]
                        old_device_id = self.device_id
                        self.device_id = existing_device.get('device_id') or existing_device.get('id')
                        print(f"✅ Найдено устройство: {self.device_id} (было: {old_device_id})")
                        print(f"   Повторная попытка подключения...")
                        # Повторяем попытку подключения с новым device_id
                        return self.connect(server_id, protocol)
                    else:
                        print(f"❌ Устройства не найдены.")
                        print(f"   Зарегистрируйте устройство через мобильное приложение или удалите одно из существующих.")
                        return False
                else:
                    print(f"❌ Ошибка подключения: {response.status_code}")
                    print(response.text)
                    return False
            else:
                print(f"❌ Ошибка подключения: {response.status_code}")
                print(response.text)
                return False
        except Exception as e:
            print(f"❌ Ошибка подключения: {e}")
            return False
    
    def disconnect(self) -> bool:
        """Отключается от VPN"""
        try:
            print(f"🔌 Отключение от VPN...")
            response = requests.post(
                f"{self.api_base_url}/api/vpn/disconnect",
                headers=self._get_headers(),
                params={"device_id": self.device_id},
                timeout=10
            )
            
            if response.status_code == 200:
                print(f"✅ Отключение выполнено")
                self.current_connection = None
                return True
            else:
                print(f"❌ Ошибка отключения: {response.status_code}")
                print(response.text)
                return False
        except Exception as e:
            print(f"❌ Ошибка отключения: {e}")
            return False
    
    def get_status(self) -> Optional[Dict]:
        """Получает статус подключения"""
        # Если устройство не найдено, пытаемся получить список устройств и использовать первое
        try:
            response = requests.get(
                f"{self.api_base_url}/api/vpn/status",
                headers=self._get_headers(),
                params={"device_id": self.device_id},
                timeout=10
            )
            
            if response.status_code == 200:
                return response.json()
            elif response.status_code == 404:
                # Устройство не найдено, пытаемся найти существующее
                print(f"⚠️  Устройство {self.device_id} не найдено. Ищем существующие устройства...")
                devices = self.get_devices()
                if devices:
                    existing_device = devices[0]
                    self.device_id = existing_device.get('device_id') or existing_device.get('id')
                    print(f"✅ Найдено устройство: {self.device_id}")
                    # Пытаемся снова получить статус
                    response = requests.get(
                        f"{self.api_base_url}/api/vpn/status",
                        headers=self._get_headers(),
                        params={"device_id": self.device_id},
                        timeout=10
                    )
                    if response.status_code == 200:
                        return response.json()
                
                print(f"❌ Устройство не найдено и нет доступных устройств")
                print(f"   Попробуйте зарегистрировать устройство через мобильное приложение")
                return None
            else:
                print(f"❌ Ошибка получения статуса: {response.status_code}")
                print(response.text)
                return None
        except Exception as e:
            print(f"❌ Ошибка получения статуса: {e}")
            return None
    
    def test_speed(self) -> Dict:
        """Тестирует скорость подключения"""
        print("📊 Тестирование скорости...")
        print("   Это может занять некоторое время...")
        
        results = {
            "download": None,
            "upload": None,
            "ping": None
        }
        
        # Простой тест ping
        try:
            ping_result = subprocess.run(
                ["ping", "-c", "3", "8.8.8.8"],
                capture_output=True,
                text=True,
                timeout=10
            )
            if ping_result.returncode == 0:
                # Парсим средний ping
                lines = ping_result.stdout.split('\n')
                for line in lines:
                    if "avg" in line.lower() or "min/avg/max" in line.lower():
                        # Пример: "min/avg/max = 10.234/12.456/15.678 ms"
                        parts = line.split('=')
                        if len(parts) > 1:
                            times = parts[1].strip().split('/')
                            if len(times) >= 2:
                                results["ping"] = float(times[1].strip().split()[0])
                                break
                print(f"   ✅ Ping: {results['ping']:.2f} ms")
            else:
                print(f"   ⚠️  Ping не удался")
        except FileNotFoundError:
            print(f"   ⚠️  Команда ping не найдена")
        except Exception as e:
            print(f"   ⚠️  Ошибка ping: {e}")
        
        # Тест скорости через curl (если доступен speedtest-cli, можно использовать его)
        print("\n   💡 Для полного теста скорости рекомендуется использовать speedtest-cli:")
        print("      pip install speedtest-cli && speedtest-cli")
        print("   Или использовать онлайн сервисы:")
        print("      - https://www.speedtest.net/")
        print("      - https://fast.com/")
        
        return results
    
    def get_connection_stats(self, days: int = 7) -> Optional[Dict]:
        """Получает статистику подключений"""
        try:
            response = requests.get(
                f"{self.api_base_url}/api/vpn/stats",
                headers=self._get_headers(),
                params={"days": days},
                timeout=10
            )
            
            if response.status_code == 200:
                return response.json()
            else:
                print(f"❌ Ошибка получения статистики: {response.status_code}")
                return None
        except Exception as e:
            print(f"❌ Ошибка получения статистики: {e}")
            return None
    
    def print_menu(self):
        """Выводит меню"""
        print("\n" + "="*60)
        print("🔧 VPN TESTER - Интерактивное тестирование VPN")
        print("="*60)
        print(f"📱 Текущее устройство: {self.device_id}")
        print("="*60)
        print("1. 📋 Список серверов")
        print("2. 🔌 Подключиться к VPN")
        print("3. 🔌 Отключиться от VPN")
        print("4. 📊 Статус подключения")
        print("5. ⚡ Тест скорости")
        print("6. 📈 Статистика подключений")
        print("7. 🧪 Тест всех протоколов на сервере")
        print("8. 📱 Список устройств")
        print("9. 🔄 Обновить токен")
        print("0. ❌ Выход")
        print("="*60)
    
    def test_all_protocols(self, server_id: int):
        """Тестирует все протоколы на сервере"""
        servers = self.get_servers()
        server = next((s for s in servers if s['id'] == server_id), None)
        
        if not server:
            print(f"❌ Сервер {server_id} не найден")
            return
        
        protocols = server.get('supported_protocols', [])
        if not protocols:
            print(f"⚠️  Сервер {server_id} не поддерживает протоколы")
            return
        
        print(f"\n🧪 Тестирование протоколов на сервере {server['name']} ({server['country']})")
        print(f"   Поддерживаемые протоколы: {', '.join(protocols)}")
        print()
        
        for protocol in protocols:
            print(f"   Тестирование {protocol}...")
            if self.connect(server_id, protocol):
                time.sleep(2)  # Ждем установки подключения
                status = self.get_status()
                if status:
                    print(f"      ✅ Статус: {status.get('connected', False)}")
                self.disconnect()
                time.sleep(1)  # Пауза между тестами
            else:
                print(f"      ❌ Не удалось подключиться")
            print()
    
    def run(self):
        """Запускает интерактивный режим"""
        if not self.get_token():
            return
        
        # Сначала пытаемся найти существующее устройство
        devices = self.get_devices()
        if devices:
            # Используем первое доступное устройство
            existing_device = devices[0]
            self.device_id = existing_device.get('device_id') or existing_device.get('id')
            print(f"✅ Используем существующее устройство: {self.device_id}")
            print(f"   Название: {existing_device.get('name', 'N/A')}")
        else:
            # Если устройств нет, пытаемся зарегистрировать
            if not self.register_device():
                print("⚠️  Не удалось зарегистрировать устройство. Попробуйте использовать мобильное приложение для регистрации.")
                print("   Или удалите одно из существующих устройств через админ-панель.")
                return
        
        while True:
            self.print_menu()
            choice = input("\nВыберите действие: ").strip()
            
            if choice == "0":
                if self.current_connection:
                    print("\n⚠️  Активное подключение обнаружено. Отключаемся...")
                    self.disconnect()
                print("👋 До свидания!")
                break
            
            elif choice == "1":
                print("\n📋 Получение списка серверов...")
                servers = self.get_servers()
                if servers:
                    print(f"\n✅ Найдено серверов: {len(servers)}\n")
                    for s in servers:
                        protocols = ', '.join(s.get('supported_protocols', []))
                        status = "✅" if s.get('is_active') else "❌"
                        print(f"{status} ID: {s['id']:3d} | {s['name']:20s} | {s['country']:15s} | {s.get('ip_address', 'N/A'):15s}")
                        print(f"      Протоколы: {protocols}")
                        print()
                else:
                    print("❌ Серверы не найдены")
            
            elif choice == "2":
                servers = self.get_servers()
                if not servers:
                    print("❌ Нет доступных серверов")
                    continue
                
                print("\n📋 Доступные серверы:")
                for s in servers:
                    if s.get('is_active'):
                        print(f"  {s['id']:3d}. {s['name']} ({s['country']}) - {', '.join(s.get('supported_protocols', []))}")
                
                try:
                    server_id = int(input("\nВведите ID сервера: "))
                    protocols = next((s.get('supported_protocols', []) for s in servers if s['id'] == server_id), [])
                    
                    if not protocols:
                        print("❌ Сервер не найден или не поддерживает протоколы")
                        continue
                    
                    print(f"\nДоступные протоколы: {', '.join(protocols)}")
                    protocol = input(f"Введите протокол [{protocols[0]}]: ").strip() or protocols[0]
                    
                    self.connect(server_id, protocol)
                except ValueError:
                    print("❌ Неверный ID сервера")
                except KeyboardInterrupt:
                    print("\n⚠️  Отменено")
            
            elif choice == "3":
                self.disconnect()
            
            elif choice == "4":
                print("\n📊 Получение статуса...")
                status = self.get_status()
                if status:
                    print(f"\n✅ Статус подключения:")
                    print(json.dumps(status, indent=2, ensure_ascii=False))
                else:
                    print("❌ Не удалось получить статус")
            
            elif choice == "5":
                self.test_speed()
            
            elif choice == "6":
                try:
                    days = int(input("Введите количество дней (по умолчанию 7): ") or "7")
                    stats = self.get_connection_stats(days)
                    if stats:
                        print(f"\n📈 Статистика за {days} дней:")
                        print(json.dumps(stats, indent=2, ensure_ascii=False))
                    else:
                        print("❌ Не удалось получить статистику")
                except ValueError:
                    print("❌ Неверное количество дней")
            
            elif choice == "7":
                servers = self.get_servers()
                if not servers:
                    print("❌ Нет доступных серверов")
                    continue
                
                print("\n📋 Доступные серверы:")
                for s in servers:
                    if s.get('is_active'):
                        print(f"  {s['id']:3d}. {s['name']} ({s['country']})")
                
                try:
                    server_id = int(input("\nВведите ID сервера для тестирования всех протоколов: "))
                    self.test_all_protocols(server_id)
                except ValueError:
                    print("❌ Неверный ID сервера")
            
            elif choice == "8":
                print("\n📱 Получение списка устройств...")
                devices = self.get_devices()
                if devices:
                    print(f"\n✅ Найдено устройств: {len(devices)}\n")
                    for i, device in enumerate(devices, 1):
                        status = "✅" if device.get('is_active') else "❌"
                        print(f"{status} {i}. {device.get('name', 'N/A')} (ID: {device.get('device_id', device.get('id', 'N/A'))})")
                        print(f"      Платформа: {device.get('platform', 'N/A')}")
                        print(f"      IP: {device.get('ip_address', 'N/A')}")
                        print(f"      Активно: {device.get('is_active', False)}")
                        print()
                    
                    # Предлагаем выбрать устройство
                    try:
                        device_choice = input("Введите номер устройства для использования (Enter - пропустить): ").strip()
                        if device_choice:
                            device_index = int(device_choice) - 1
                            if 0 <= device_index < len(devices):
                                selected_device = devices[device_index]
                                self.device_id = selected_device.get('device_id') or selected_device.get('id')
                                print(f"✅ Выбрано устройство: {self.device_id}")
                            else:
                                print("❌ Неверный номер устройства")
                    except ValueError:
                        print("❌ Неверный ввод")
                else:
                    print("❌ Устройства не найдены")
            
            elif choice == "9":
                if not self.get_token():
                    print("❌ Не удалось обновить токен")
            
            else:
                print("❌ Неверный выбор")
            
            input("\nНажмите Enter для продолжения...")


if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="Интерактивный тестер VPN")
    parser.add_argument("--email", default="rail.tamaew@gmail.com", help="Email пользователя")
    parser.add_argument("--api-url", default=os.getenv("API_URL", "https://api.granilink.com"), help="URL API")
    
    args = parser.parse_args()
    
    tester = VPNTester(email=args.email, api_base_url=args.api_url)
    tester.run()

