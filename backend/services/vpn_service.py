import subprocess
import os
import json
from typing import Dict, Any
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.backends import default_backend
import base64

from core.config import settings
from models.user import Device
from models.server import Server

class VPNService:
    def __init__(self):
        self.wireguard_config_path = settings.WIREGUARD_CONFIG_PATH
        self.wireguard_interface = settings.WIREGUARD_INTERFACE
    
    def generate_key_pair(self) -> Dict[str, str]:
        """Генерация пары ключей WireGuard (использует WireGuardManager)"""
        from services.wireguard_manager import WireGuardManager
        wg_manager = WireGuardManager()
        return wg_manager.generate_key_pair()
    
    def generate_client_config(self, device: Device, server: Server) -> str:
        """Генерация конфигурации клиента WireGuard"""
        # Генерируем ключи для устройства, если их нет
        if not device.wireguard_private_key:
            keys = self.generate_key_pair()
            device.wireguard_private_key = keys["private_key"]
            device.wireguard_public_key = keys["public_key"]
        
        # Создаем конфигурацию клиента
        config = f"""[Interface]
PrivateKey = {device.wireguard_private_key}
Address = 10.0.0.{device.id}/32
DNS = 8.8.8.8, 8.8.4.4

[Peer]
PublicKey = {server.wireguard_public_key}
Endpoint = {server.ip_address}:{server.wireguard_port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
"""
        
        return config
    
    def add_client_to_server(self, device: Device, server: Server) -> bool:
        """Добавление клиента на сервер WireGuard"""
        try:
            # Читаем текущую конфигурацию сервера
            with open(self.wireguard_config_path, 'r') as f:
                config_content = f.read()
            
            # Добавляем нового клиента
            client_section = f"""

# Client: {device.device_name or device.device_id}
[Peer]
PublicKey = {device.wireguard_public_key}
AllowedIPs = 10.0.0.{device.id}/32
"""
            
            config_content += client_section
            
            # Записываем обновленную конфигурацию
            with open(self.wireguard_config_path, 'w') as f:
                f.write(config_content)
            
            # Перезагружаем WireGuard
            self.reload_wireguard()
            
            return True
            
        except Exception as e:
            print(f"Ошибка при добавлении клиента: {e}")
            return False
    
    def remove_client_from_server(self, device: Device) -> bool:
        """Удаление клиента с сервера WireGuard"""
        try:
            # Читаем текущую конфигурацию сервера
            with open(self.wireguard_config_path, 'r') as f:
                config_lines = f.readlines()
            
            # Удаляем секцию клиента
            new_config_lines = []
            skip_section = False
            
            for line in config_lines:
                if f"# Client: {device.device_name or device.device_id}" in line:
                    skip_section = True
                    continue
                
                if skip_section and line.strip() == "":
                    skip_section = False
                    continue
                
                if skip_section and line.startswith("[Peer]"):
                    skip_section = False
                
                if not skip_section:
                    new_config_lines.append(line)
            
            # Записываем обновленную конфигурацию
            with open(self.wireguard_config_path, 'w') as f:
                f.writelines(new_config_lines)
            
            # Перезагружаем WireGuard
            self.reload_wireguard()
            
            return True
            
        except Exception as e:
            print(f"Ошибка при удалении клиента: {e}")
            return False
    
    def reload_wireguard(self) -> bool:
        """Перезагрузка WireGuard интерфейса"""
        try:
            # Останавливаем интерфейс
            subprocess.run([
                "wg-quick", "down", self.wireguard_interface
            ], check=True)
            
            # Запускаем интерфейс
            subprocess.run([
                "wg-quick", "up", self.wireguard_interface
            ], check=True)
            
            return True
            
        except subprocess.CalledProcessError as e:
            print(f"Ошибка при перезагрузке WireGuard: {e}")
            return False
    
    def get_wireguard_status(self) -> Dict[str, Any]:
        """Получение статуса WireGuard"""
        try:
            result = subprocess.run([
                "wg", "show", self.wireguard_interface
            ], capture_output=True, text=True, check=True)
            
            return {
                "status": "running",
                "output": result.stdout
            }
            
        except subprocess.CalledProcessError:
            return {
                "status": "stopped",
                "output": ""
            }
    
    def set_speed_limit(self, device_id: int, speed_mbps: int) -> bool:
        """Установка ограничения скорости для устройства"""
        try:
            # Используем tc (traffic control) для ограничения скорости
            interface = f"wg{device_id}"
            
            # Удаляем существующие правила
            subprocess.run([
                "tc", "qdisc", "del", "dev", interface, "root"
            ], capture_output=True)
            
            # Добавляем новое ограничение
            subprocess.run([
                "tc", "qdisc", "add", "dev", interface, "root", "tbf",
                "rate", f"{speed_mbps}mbit", "burst", "32kbit", "latency", "400ms"
            ], check=True)
            
            return True
            
        except subprocess.CalledProcessError as e:
            print(f"Ошибка при установке ограничения скорости: {e}")
            return False
    
    def get_connection_stats(self, device_id: int) -> Dict[str, Any]:
        """Получение статистики подключения"""
        try:
            interface = f"wg{device_id}"
            
            # Получаем статистику через wg
            result = subprocess.run([
                "wg", "show", interface, "dump"
            ], capture_output=True, text=True, check=True)
            
            lines = result.stdout.strip().split('\n')
            if len(lines) > 1:
                peer_data = lines[1].split('\t')
                if len(peer_data) >= 6:
                    return {
                        "rx_bytes": int(peer_data[5]),
                        "tx_bytes": int(peer_data[6]),
                        "last_handshake": peer_data[4]
                    }
            
            return {
                "rx_bytes": 0,
                "tx_bytes": 0,
                "last_handshake": None
            }
            
        except subprocess.CalledProcessError:
            return {
                "rx_bytes": 0,
                "tx_bytes": 0,
                "last_handshake": None
            }
    
    def check_server_health(self, server: Server) -> Dict[str, Any]:
        """Проверка здоровья сервера"""
        try:
            # Проверяем доступность сервера
            result = subprocess.run([
                "ping", "-c", "1", "-W", "5", server.ip_address
            ], capture_output=True, text=True)
            
            is_reachable = result.returncode == 0
            
            # Проверяем WireGuard статус
            wg_status = self.get_wireguard_status()
            
            return {
                "server_id": server.id,
                "server_name": server.name,
                "is_reachable": is_reachable,
                "wireguard_status": wg_status["status"],
                "current_users": server.current_users,
                "max_users": server.max_users
            }
            
        except Exception as e:
            return {
                "server_id": server.id,
                "server_name": server.name,
                "is_reachable": False,
                "wireguard_status": "unknown",
                "error": str(e)
            }









