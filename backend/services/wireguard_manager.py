import subprocess
import os
import json
import re
import ipaddress
import secrets
from typing import Dict, Any, List, Optional, Tuple
from datetime import datetime
import logging

from core.config import settings
from domain.models.user import Device
from domain.models.server import Server
# Опциональный импорт RemoteVPNManager (может зависеть от paramiko)
try:
    from infrastructure.external.remote_vpn_manager import RemoteVPNManager
    REMOTE_VPN_MANAGER_AVAILABLE = True
except ImportError:
    RemoteVPNManager = None
    REMOTE_VPN_MANAGER_AVAILABLE = False

logger = logging.getLogger(__name__)

AWG_PARAM_ORDER = (
    "Jc", "Jmin", "Jmax",
    "S1", "S2", "S3", "S4",
    "H1", "H2", "H3", "H4",
    "I1", "I2", "I3", "I4", "I5",
)

AWG_V2_REQUIRED_KEYS = (
    "Jc", "Jmin", "Jmax",
    "S1", "S2", "S3", "S4",
    "H1", "H2", "H3", "H4",
)

AWG_V2_OPTIONAL_KEYS = ("I1", "I2", "I3", "I4", "I5")

AWG_LEGACY_DEFAULTS = {
    "Jc": 4,
    "Jmin": 5,
    "Jmax": 60,
    "H1": "1",
    "H2": "2",
    "H3": "3",
    "H4": "4",
}

AWG_DEFAULT_SPECIAL_JUNK_1 = (
    "<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c"
    "000100010000105a00044d583737>"
)
AWG_DEFAULT_SPECIAL_JUNK_2 = ""
AWG_DEFAULT_SPECIAL_JUNK_3 = ""
AWG_DEFAULT_SPECIAL_JUNK_4 = ""
AWG_DEFAULT_SPECIAL_JUNK_5 = ""

AWG_MESSAGE_INITIATION_SIZE = 148
AWG_MESSAGE_RESPONSE_SIZE = 92
AWG_MESSAGE_COOKIE_REPLY_SIZE = 64
AWG_MAX_QINT32 = 2147483647

class WireGuardManager:
    """Менеджер для работы с WireGuard (локальные и удаленные серверы)"""
    
    def __init__(self, server: Optional[Server] = None):
        self.server = server
        self.config_path = settings.WIREGUARD_CONFIG_PATH
        self.interface = settings.WIREGUARD_INTERFACE
        self.network = ipaddress.IPv4Network('10.0.0.0/24', strict=False)
        self.used_ips = set()
        if REMOTE_VPN_MANAGER_AVAILABLE and RemoteVPNManager:
            self.remote_manager = RemoteVPNManager()
        else:
            self.remote_manager = None
            logger.warning("WireGuardManager инициализирован без RemoteVPNManager. Удаленные серверы недоступны.")
        if not server:
            self._load_used_ips()
    
    def _is_local_server(self, server: Optional[Server] = None) -> bool:
        """Проверяет, является ли сервер локальным"""
        target_server = server or self.server
        if not target_server:
            return True  # По умолчанию считаем локальным
        
        return getattr(target_server, 'is_local', False) == True
    
    def _get_config_path(self, server: Optional[Server] = None) -> str:
        """Получает путь к конфигурации WireGuard"""
        target_server = server or self.server
        if target_server and not self._is_local_server(target_server):
            return getattr(target_server, 'wireguard_config_path', '/etc/wireguard/wg0.conf')
        return self.config_path
    
    def _get_interface(self, server: Optional[Server] = None) -> str:
        """Получает имя интерфейса WireGuard"""
        target_server = server or self.server
        if target_server and not self._is_local_server(target_server):
            return getattr(target_server, 'wireguard_interface', 'wg0')
        return self.interface
    
    def _load_used_ips(self):
        """Загружает уже используемые IP адреса из конфигурации"""
        try:
            if os.path.exists(self.config_path):
                with open(self.config_path, 'r') as f:
                    content = f.read()
                    # Ищем все AllowedIPs в конфигурации
                    matches = re.findall(r'AllowedIPs = (\d+\.\d+\.\d+\.\d+)', content)
                    for match in matches:
                        self.used_ips.add(match)
        except Exception as e:
            logger.error(f"Ошибка загрузки используемых IP: {e}")

    def _parse_awg_params(self, value: str) -> Dict[str, Any]:
        """Парсит AmneziaWG параметры из JSON строки."""
        if not value:
            return {}
        try:
            parsed = json.loads(value)
            if isinstance(parsed, dict):
                return parsed
        except Exception:
            return {}
        return {}

    def _format_awg_params(self, params: Dict[str, Any]) -> str:
        """Форматирует AmneziaWG параметры в конфиг (строки key = value)."""
        if not params:
            return ""
        lines = []
        for key in AWG_PARAM_ORDER:
            if key in AWG_V2_OPTIONAL_KEYS and key in params and params[key] is not None:
                lines.append(f"{key} = {params[key]}")
            elif key in params and params[key] not in (None, ""):
                lines.append(f"{key} = {params[key]}")
        return "\n".join(lines)

    @staticmethod
    def generate_amneziawg_v2_params() -> Dict[str, Any]:
        """Generate AWG2 params using the same ranges as Amnezia self-hosted installer."""
        def bounded(start: int, stop: int) -> int:
            return start + secrets.randbelow(stop - start)

        s1 = bounded(15, 150)
        s2 = bounded(15, 150)
        s3 = bounded(0, 64)
        s4 = bounded(0, 20)

        used_values = {s1}
        while (
            s2 in used_values
            or s1 + AWG_MESSAGE_INITIATION_SIZE == s2 + AWG_MESSAGE_RESPONSE_SIZE
        ):
            s2 = bounded(15, 150)
        used_values.add(s2)

        while (
            s3 in used_values
            or s1 + AWG_MESSAGE_INITIATION_SIZE == s3 + AWG_MESSAGE_COOKIE_REPLY_SIZE
            or s2 + AWG_MESSAGE_RESPONSE_SIZE == s3 + AWG_MESSAGE_COOKIE_REPLY_SIZE
        ):
            s3 = bounded(0, 64)
        used_values.add(s3)

        while s4 in used_values:
            s4 = bounded(0, 20)

        header_ranges = []
        header_min = 5
        while len(header_ranges) != 4:
            first = bounded(header_min, AWG_MAX_QINT32)
            second = bounded(first, AWG_MAX_QINT32)
            header_min = second
            header_ranges.append(f"{first}-{second}")

        return {
            "Jc": bounded(4, 7),
            "Jmin": 10,
            "Jmax": 50,
            "S1": s1,
            "S2": s2,
            "S3": s3,
            "S4": s4,
            "H1": header_ranges[0],
            "H2": header_ranges[1],
            "H3": header_ranges[2],
            "H4": header_ranges[3],
            "I1": AWG_DEFAULT_SPECIAL_JUNK_1,
            "I2": AWG_DEFAULT_SPECIAL_JUNK_2,
            "I3": AWG_DEFAULT_SPECIAL_JUNK_3,
            "I4": AWG_DEFAULT_SPECIAL_JUNK_4,
            "I5": AWG_DEFAULT_SPECIAL_JUNK_5,
        }

    def _normalize_awg_params(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Ensures AmneziaWG configs are explicit, including clients without app-side defaults."""
        normalized = dict(AWG_LEGACY_DEFAULTS)
        normalized.update(params or {})
        return normalized

    def _client_mtu(self, server: Optional[Server] = None) -> int:
        """Returns WireGuard/AmneziaWG client MTU with optional per-server override."""
        default_mtu = 1420
        target_server = server or self.server
        raw_value = None

        if target_server:
            try:
                specs = target_server.get_server_specs()
                raw_value = (
                    specs.get("graniwg_client_mtu")
                    or specs.get("wireguard_client_mtu")
                    or specs.get("client_mtu")
                )
            except Exception:
                raw_value = None

        if raw_value is None:
            raw_value = os.environ.get("GRANIWG_CLIENT_MTU") or os.environ.get("WIREGUARD_CLIENT_MTU")

        try:
            mtu = int(raw_value) if raw_value is not None else default_mtu
        except (TypeError, ValueError):
            mtu = default_mtu

        return max(576, min(mtu, 1420))

    def _client_network(self, server: Optional[Server] = None) -> str:
        """Returns the peer allocation subnet for remote WireGuard/AmneziaWG nodes."""
        default_network = "10.0.0.0/24"
        target_server = server or self.server
        raw_value = None

        if target_server:
            try:
                specs = target_server.get_server_specs()
                raw_value = (
                    specs.get("graniwg_client_network")
                    or specs.get("wireguard_client_network")
                    or specs.get("client_network")
                )
            except Exception:
                raw_value = None

        raw_value = raw_value or os.environ.get("GRANIWG_CLIENT_NETWORK")
        candidate = str(raw_value or default_network).strip()

        try:
            ipaddress.IPv4Network(candidate, strict=False)
            return candidate
        except ValueError:
            logger.warning("Invalid GRANIWG client network %r, using %s", candidate, default_network)
            return default_network
    
    def get_next_available_ip(self, server: Optional[Server] = None) -> str:
        """Получает следующий доступный IP адрес"""
        # Если сервер удаленный, используем RemoteVPNManager
        if server and not self._is_local_server(server):
            ip = self.remote_manager.get_next_available_wireguard_ip(
                server,
                network=self._client_network(server),
            )
            if ip:
                return ip
            raise Exception("Нет доступных IP адресов в сети")
        
        # Локальный сервер - используем старую логику
        for ip in self.network.hosts():
            ip_str = str(ip)
            if ip_str not in self.used_ips and ip_str != '10.0.0.1':  # 10.0.0.1 - сервер
                self.used_ips.add(ip_str)
                return ip_str
        raise Exception("Нет доступных IP адресов в сети")
    
    def generate_key_pair(self, server: Optional[Server] = None) -> Dict[str, str]:
        """Генерирует пару ключей WireGuard"""
        # Если сервер удаленный, используем RemoteVPNManager
        if server and not self._is_local_server(server):
            return self.remote_manager.generate_wireguard_key_pair(server)
        
        # Локальный сервер - используем subprocess
        try:
            # Генерация приватного ключа
            private_key = subprocess.check_output(
                ['wg', 'genkey'], 
                text=True, 
                stderr=subprocess.PIPE
            ).strip()
            
            # Генерация публичного ключа
            public_key = subprocess.check_output(
                ['wg', 'pubkey'], 
                input=private_key, 
                text=True, 
                stderr=subprocess.PIPE
            ).strip()
            
            return {
                'private_key': private_key,
                'public_key': public_key
            }
        except subprocess.CalledProcessError as e:
            logger.error(f"Ошибка генерации ключей: {e}")
            raise Exception("Не удалось сгенерировать ключи WireGuard")
    
    def create_client_config(
        self,
        device: Device,
        server: Server,
        client_ip: str,
        protocol: str = "wireguard",
        preshared_key: Optional[str] = None,
    ) -> str:
        """Создает конфигурацию клиента WireGuard или GRANIWG"""
        if protocol == "graniwg":
            return self.create_graniwg_client_config(device, server, client_ip, preshared_key=preshared_key)
        
        # Стандартный WireGuard конфиг
        config = f"""[Interface]
PrivateKey = {device.wireguard_private_key}
Address = {client_ip}/32
DNS = 1.1.1.1, 9.9.9.9
MTU = {self._client_mtu(server)}

[Peer]
PublicKey = {server.wireguard_public_key}
{f"PresharedKey = {preshared_key}" if preshared_key else ""}
Endpoint = {server.ip_address}:{server.wireguard_port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
"""
        return config
    
    def create_graniwg_client_config(
        self,
        device: Device,
        server: Server,
        client_ip: str,
        preshared_key: Optional[str] = None,
    ) -> str:
        """Создает обфусцированную конфигурацию GRANIWG"""
        # Проверяем, включен ли GRANIWG на сервере
        if not server.graniwg_enabled:
            logger.warning(f"GRANIWG не включен на сервере {server.id}, используем стандартный WireGuard")
            return self.create_client_config(device, server, client_ip, "wireguard", preshared_key=preshared_key)
        
        graniwg_config = server.get_graniwg_config()
        obfuscation_type = graniwg_config.get('obfuscationType', 'udp2raw')
        obfuscation_key = graniwg_config.get('obfuscationKey', '')
        awg_params = self._parse_awg_params(obfuscation_key) if obfuscation_type == "amneziawg" else {}
        if obfuscation_type == "amneziawg" and not awg_params:
            awg_params = settings.awg_params
        if obfuscation_type == "amneziawg":
            awg_params = self._normalize_awg_params(awg_params)
        
        # Базовый WireGuard конфиг
        base_config = f"""[Interface]
PrivateKey = {device.wireguard_private_key}
Address = {client_ip}/32
DNS = 1.1.1.1, 1.0.0.1
MTU = {self._client_mtu(server)}
{self._format_awg_params(awg_params) if obfuscation_type == "amneziawg" else ""}

[Peer]
PublicKey = {server.wireguard_public_key}
{f"PresharedKey = {preshared_key}" if preshared_key else ""}
Endpoint = {server.ip_address}:{server.wireguard_port}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
"""
        
        # Добавляем параметры обфускации в комментарии для совместимости
        if obfuscation_key and obfuscation_type != "amneziawg":
            obfuscation_note = f"""
# GRANIWG Configuration
# Obfuscation Type: {obfuscation_type}
# Obfuscation Key: {obfuscation_key}
# Note: Для использования GRANIWG требуется клиент с поддержкой обфускации
"""
            return obfuscation_note + base_config
        
        return base_config
    
    def add_peer_to_server(
        self,
        device: Device,
        server: Server,
        client_ip: str,
        preshared_key: Optional[str] = None,
    ) -> bool:
        """Добавляет пир в конфигурацию сервера"""
        # Если сервер удаленный, используем RemoteVPNManager
        if not self._is_local_server(server):
            try:
                return self.remote_manager.add_wireguard_peer(server, device, client_ip, preshared_key=preshared_key)
            except Exception as e:
                logger.error(f"Ошибка добавления пира на удаленном сервере: {e}")
                return False
        
        # Локальный сервер - используем файловую систему
        try:
            config_path = self._get_config_path(server)
            # Читаем текущую конфигурацию
            with open(config_path, 'r') as f:
                config_content = f.read()
            
            # Добавляем нового пира
            peer_config = f"""

# Peer for device {device.id} - {device.device_name or device.device_id}
[Peer]
PublicKey = {device.wireguard_public_key}
{f"PresharedKey = {preshared_key}" if preshared_key else ""}
AllowedIPs = {client_ip}/32
"""
            
            # Добавляем в конец файла
            with open(config_path, 'a') as f:
                f.write(peer_config)
            
            # Перезагружаем WireGuard
            return self.reload_interface(server)
            
        except Exception as e:
            logger.error(f"Ошибка добавления пира: {e}")
            return False
    
    def remove_peer_from_server(self, device: Device, server: Optional[Server] = None) -> bool:
        """Удаляет пир из конфигурации сервера"""
        target_server = server or self.server
        if not target_server:
            logger.error("Сервер не указан для удаления пира")
            return False
        
        # Если сервер удаленный, используем RemoteVPNManager
        if not self._is_local_server(target_server):
            try:
                return self.remote_manager.remove_wireguard_peer(target_server, device)
            except Exception as e:
                logger.error(f"Ошибка удаления пира на удаленном сервере: {e}")
                return False
        
        # Локальный сервер - используем файловую систему
        try:
            config_path = self._get_config_path(target_server)
            # Читаем конфигурацию
            with open(config_path, 'r') as f:
                lines = f.readlines()
            
            # Удаляем секцию пира
            new_lines = []
            skip_peer = False
            
            device_name = device.device_name or device.device_id
            for line in lines:
                if f"# Peer for device {device.id}" in line:
                    skip_peer = True
                    continue
                elif skip_peer and line.strip() == "":
                    skip_peer = False
                    continue
                elif skip_peer and line.startswith("[Peer]"):
                    skip_peer = False
                    new_lines.append(line)
                elif not skip_peer:
                    new_lines.append(line)
            
            # Записываем обновленную конфигурацию
            with open(config_path, 'w') as f:
                f.writelines(new_lines)
            
            # Перезагружаем WireGuard
            return self.reload_interface(target_server)
            
        except Exception as e:
            logger.error(f"Ошибка удаления пира: {e}")
            return False
    
    def reload_interface(self, server: Optional[Server] = None) -> bool:
        """Перезагружает интерфейс WireGuard"""
        target_server = server or self.server
        
        # Если сервер удаленный, используем RemoteVPNManager
        if target_server and not self._is_local_server(target_server):
            return self.remote_manager.reload_wireguard(target_server)
        
        # Локальный сервер - используем subprocess
        try:
            interface = self._get_interface(target_server)
            # Останавливаем интерфейс
            subprocess.run(['wg-quick', 'down', interface], 
                         capture_output=True, check=False)
            
            # Запускаем интерфейс
            result = subprocess.run(['wg-quick', 'up', interface], 
                                  capture_output=True, text=True)
            
            if result.returncode != 0:
                logger.error(f"Ошибка перезагрузки WireGuard: {result.stderr}")
                return False
            
            return True
            
        except Exception as e:
            logger.error(f"Ошибка перезагрузки интерфейса: {e}")
            return False
    
    def get_interface_status(self) -> Dict[str, Any]:
        """Получает статус интерфейса WireGuard"""
        try:
            # Получаем информацию о пирах
            result = subprocess.run(['wg', 'show', self.interface], 
                                  capture_output=True, text=True)
            
            if result.returncode != 0:
                return {'error': 'Интерфейс не активен'}
            
            # Парсим вывод
            peers = []
            current_peer = {}
            
            for line in result.stdout.split('\n'):
                if line.startswith('peer:'):
                    if current_peer:
                        peers.append(current_peer)
                    current_peer = {'public_key': line.split(':')[1].strip()}
                elif line.startswith('  endpoint:'):
                    current_peer['endpoint'] = line.split(':')[1].strip()
                elif line.startswith('  allowed ips:'):
                    current_peer['allowed_ips'] = line.split(':')[1].strip()
                elif line.startswith('  latest handshake:'):
                    current_peer['latest_handshake'] = line.split(':')[1].strip()
                elif line.startswith('  transfer:'):
                    transfer = line.split(':')[1].strip()
                    current_peer['transfer'] = transfer
            
            if current_peer:
                peers.append(current_peer)
            
            return {
                'interface': self.interface,
                'peers': peers,
                'total_peers': len(peers)
            }
            
        except Exception as e:
            logger.error(f"Ошибка получения статуса: {e}")
            return {'error': str(e)}
    
    def get_peer_stats(self, public_key: str, server: Optional[Server] = None) -> Dict[str, Any]:
        """Получает статистику конкретного пира"""
        target_server = server or self.server
        
        # Если сервер удаленный, используем SSH для получения статистики (с кэшем по серверу)
        if target_server and not self._is_local_server(target_server):
            try:
                server_id = getattr(target_server, "id", None)
                cache_ttl = 50

                def parse_dump_for_peer(stdout: str, pk: str) -> Dict[str, Any]:
                    for line in (stdout or "").split("\n"):
                        if line.strip() and pk in line:
                            parts = line.split("\t")
                            if len(parts) >= 6:
                                return {
                                    "public_key": parts[0],
                                    "endpoint": parts[2],
                                    "allowed_ips": parts[3],
                                    "latest_handshake": parts[4],
                                    "transfer_rx": parts[5],
                                    "transfer_tx": parts[6] if len(parts) > 6 else None,
                                }
                    return {"error": "Пир не найден"}

                if server_id is not None:
                    from core.cache import cache_get, cache_set
                    cache_key = f"wg:server:{server_id}"
                    cached_dump = cache_get(cache_key)
                    if cached_dump is not None:
                        return parse_dump_for_peer(cached_dump, public_key)

                if self.remote_manager and hasattr(self.remote_manager, "get_wireguard_status"):
                    status = self.remote_manager.get_wireguard_status(target_server)
                    if isinstance(status, dict) and "output" in status:
                        dump = status["output"]
                        if server_id is not None:
                            from core.cache import cache_set
                            cache_set(f"wg:server:{server_id}", dump, ttl=cache_ttl)
                        return parse_dump_for_peer(dump, public_key)
                    for peer in status.get("peers", []) if isinstance(status, dict) else []:
                        if peer.get("public_key") == public_key:
                            return peer
                    return {"error": "Пир не найден"}

                ssh_config = self.remote_manager.get_ssh_config(target_server)
                interface = getattr(target_server, "wireguard_interface", "wg0")
                result = self.remote_manager.ssh_manager.execute_command(
                    ssh_config["host"],
                    f"wg show {interface} dump",
                    ssh_config["port"],
                    ssh_config["username"],
                    ssh_config.get("key_path"),
                    ssh_config.get("key_content"),
                    ssh_config.get("password"),
                )
                if result.get("success"):
                    stdout = result.get("stdout", "")
                    if server_id is not None:
                        from core.cache import cache_set
                        cache_set(f"wg:server:{server_id}", stdout, ttl=cache_ttl)
                    return parse_dump_for_peer(stdout, public_key)
                return {"error": "Пир не найден"}
            except Exception as e:
                logger.error("Ошибка получения статистики пира через SSH: %s", e)
                return {"error": str(e)}
        
        # Локальный сервер - используем subprocess
        try:
            interface = self._get_interface(target_server)
            result = subprocess.run(['wg', 'show', interface, 'dump'], 
                                  capture_output=True, text=True)
            
            if result.returncode != 0:
                return {'error': 'Не удалось получить статистику'}
            
            for line in result.stdout.split('\n'):
                if line.strip() and public_key in line:
                    parts = line.split('\t')
                    # Формат wg show <iface> dump:
                    # public-key, preshared-key, endpoint, allowed-ips, latest-handshake, transfer-rx, transfer-tx, keepalive
                    if len(parts) >= 6:
                        return {
                            'public_key': parts[0],
                            'endpoint': parts[2],
                            'allowed_ips': parts[3],
                            'latest_handshake': parts[4],
                            'transfer_rx': parts[5],
                            'transfer_tx': parts[6] if len(parts) > 6 else None
                        }
            
            return {'error': 'Пир не найден'}
            
        except Exception as e:
            logger.error(f"Ошибка получения статистики пира: {e}")
            return {'error': str(e)}
    
    def set_peer_speed_limit(self, public_key: str, speed_mbps: int) -> bool:
        """Устанавливает ограничение скорости для пира"""
        try:
            # Используем tc для ограничения скорости
            # Создаем класс для ограничения скорости
            class_id = f"1:{hash(public_key) % 1000 + 1}"
            
            # Удаляем существующие правила
            subprocess.run(['tc', 'qdisc', 'del', 'dev', self.interface, 'root'], 
                         capture_output=True, check=False)
            
            # Создаем новую очередь
            subprocess.run([
                'tc', 'qdisc', 'add', 'dev', self.interface, 'root', 
                'handle', '1:', 'htb', 'default', '30'
            ], check=True)
            
            # Добавляем класс с ограничением скорости
            subprocess.run([
                'tc', 'class', 'add', 'dev', self.interface, 'parent', '1:', 
                'classid', class_id, 'htb', 'rate', f'{speed_mbps}mbit'
            ], check=True)
            
            # Добавляем фильтр для пира
            subprocess.run([
                'tc', 'filter', 'add', 'dev', self.interface, 'protocol', 'all', 
                'parent', '1:', 'prio', '1', 'u32', 'match', 'u32', '0', '0', 
                'flowid', class_id
            ], check=True)
            
            return True
            
        except Exception as e:
            logger.error(f"Ошибка установки ограничения скорости: {e}")
            return False
    
    def check_interface_health(self) -> Dict[str, Any]:
        """Проверяет здоровье интерфейса WireGuard"""
        try:
            # Проверяем, что интерфейс существует
            result = subprocess.run(['ip', 'link', 'show', self.interface], 
                                  capture_output=True, text=True)
            
            if result.returncode != 0:
                return {
                    'status': 'error',
                    'message': 'Интерфейс не существует'
                }
            
            # Проверяем статус
            status_result = subprocess.run(['wg', 'show', self.interface], 
                                         capture_output=True, text=True)
            
            if status_result.returncode != 0:
                return {
                    'status': 'error',
                    'message': 'Интерфейс не активен'
                }
            
            # Получаем статистику
            stats = self.get_interface_status()
            
            return {
                'status': 'healthy',
                'interface': self.interface,
                'peers_count': stats.get('total_peers', 0),
                'timestamp': datetime.now().isoformat()
            }
            
        except Exception as e:
            logger.error(f"Ошибка проверки здоровья интерфейса: {e}")
            return {
                'status': 'error',
                'message': str(e)
            }

