#!/usr/bin/env python3
"""
Сервис автоматической установки и настройки XRay на удаленных VPN серверах
Поддерживает установку VLESS, VMESS и REALITY протоколов
"""
import logging
import json
import secrets
import subprocess
from typing import Dict, Any, Optional, List
from models.server import Server
from core.constants import (
    XRAY_REALITY_DEFAULT_PORT,
    XRAY_VLESS_DEFAULT_PORT,
    XRAY_VMESS_DEFAULT_PORT,
)
from infrastructure.external.remote_vpn_manager import RemoteVPNManager
from infrastructure.external.xray_manager import XrayManager

logger = logging.getLogger(__name__)


def _ensure_xray_log_paths(config: Dict[str, Any]) -> None:
    """Гарантирует file-based логи Xray для диагностики."""
    log_section = config.get("log")
    if not isinstance(log_section, dict):
        log_section = {}
    loglevel = str(log_section.get("loglevel") or "warning").strip().lower()
    if loglevel not in {"debug", "info", "warning", "error", "none"}:
        loglevel = "warning"
    log_section["loglevel"] = loglevel
    log_section["access"] = "/var/log/xray/access.log"
    log_section["error"] = "/var/log/xray/error.log"
    config["log"] = log_section


class XrayProvisioningService:
    """Сервис для автоматической установки и настройки XRay на VPN серверах"""
    
    def __init__(self):
        self.remote_manager = RemoteVPNManager()
        if not self.remote_manager.ssh_manager:
            raise RuntimeError("SSHManager недоступен. Установите paramiko: pip install paramiko")
    
    def install_xray(self, server: Server) -> Dict[str, Any]:
        """
        Устанавливает XRay на удаленном сервере
        
        Args:
            server: Сервер для установки XRay
            
        Returns:
            Результат установки
        """
        ssh_config = self.remote_manager.get_ssh_config(server)
        
        logger.info(f"Начало установки XRay на сервере {server.id} ({server.ip_address})")
        
        try:
            # 1. Проверяем, установлен ли XRay
            check_result = self.remote_manager.ssh_manager.execute_command(
                ssh_config['host'],
                "which xray && xray version 2>&1 | head -1 || echo 'NOT_INSTALLED'",
                ssh_config['port'],
                ssh_config['username'],
                ssh_config.get('key_path'),
                ssh_config.get('key_content'),
                ssh_config.get('password')
            )
            
            if check_result['success'] and 'NOT_INSTALLED' not in check_result['stdout']:
                logger.info(f"XRay уже установлен на сервере {server.id}: {check_result['stdout'].strip()}")
                return {
                    'success': True,
                    'installed': True,
                    'version': check_result['stdout'].strip(),
                    'message': 'XRay уже установлен'
                }
            
            # 2. Устанавливаем XRay
            logger.info(f"Установка XRay на сервере {server.id}...")
            install_script = """
            bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
            """
            
            install_result = self.remote_manager.ssh_manager.execute_command(
                ssh_config['host'],
                install_script,
                ssh_config['port'],
                ssh_config['username'],
                ssh_config.get('key_path'),
                ssh_config.get('key_content'),
                ssh_config.get('password'),
                timeout=300  # 5 минут на установку
            )
            
            if not install_result['success']:
                error_msg = install_result.get('stderr', install_result.get('stdout', 'Unknown error'))
                logger.error(f"Ошибка установки XRay на сервере {server.id}: {error_msg}")
                return {
                    'success': False,
                    'installed': False,
                    'error': error_msg
                }
            
            # 3. Проверяем установку
            verify_result = self.remote_manager.ssh_manager.execute_command(
                ssh_config['host'],
                "which xray && xray version 2>&1 | head -1",
                ssh_config['port'],
                ssh_config['username'],
                ssh_config.get('key_path'),
                ssh_config.get('key_content'),
                ssh_config.get('password')
            )
            
            if verify_result['success'] and 'xray' in verify_result['stdout'].lower():
                version = verify_result['stdout'].strip()
                logger.info(f"XRay успешно установлен на сервере {server.id}: {version}")
                return {
                    'success': True,
                    'installed': True,
                    'version': version,
                    'message': 'XRay успешно установлен'
                }
            else:
                logger.error(f"XRay не найден после установки на сервере {server.id}")
                return {
                    'success': False,
                    'installed': False,
                    'error': 'XRay не найден после установки'
                }
                
        except Exception as e:
            logger.error(f"Ошибка установки XRay на сервере {server.id}: {e}", exc_info=True)
            return {
                'success': False,
                'installed': False,
                'error': str(e)
            }
    
    def setup_base_xray_config(self, server: Server, port: int = None) -> Dict[str, Any]:
        """
        Создает базовую конфигурацию XRay с поддержкой VLESS и VMESS
        
        Args:
            server: Сервер для настройки
            port: Порт plain VLESS (по умолчанию XRAY_VLESS_DEFAULT_PORT, не 443 — под nginx API)
            
        Returns:
            Результат настройки
        """
        ssh_config = self.remote_manager.get_ssh_config(server)
        xray_manager = XrayManager(server)
        
        vless_port = port if port is not None else XRAY_VLESS_DEFAULT_PORT
        vmess_port = XRAY_VMESS_DEFAULT_PORT
        logger.info(
            f"Настройка базовой конфигурации XRay на сервере {server.id} "
            f"(VLESS/REALITY порт {vless_port}, VMESS порт {vmess_port})"
        )
        
        try:
            # Читаем существующую конфигурацию или создаем новую
            try:
                config = xray_manager._read_xray_config(server)
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
            _ensure_xray_log_paths(config)
            
            # Проверяем наличие VLESS inbound
            vless_inbound = None
            vmess_inbound = None
            
            for inbound in config.get('inbounds', []):
                if inbound.get('protocol') == 'vless' and inbound.get('port') == vless_port:
                    vless_inbound = inbound
                elif inbound.get('protocol') == 'vmess' and inbound.get('port') == vmess_port:
                    vmess_inbound = inbound
            
            # Создаем VLESS inbound если его нет
            if not vless_inbound:
                vless_inbound = {
                    "port": vless_port,
                    "protocol": "vless",
                    "settings": {
                        "clients": [],
                        "decryption": "none",
                    },
                    "streamSettings": {
                        "network": "tcp",
                        "security": "none",
                        "tcpSettings": {
                            "acceptProxyProtocol": False
                        }
                    },
                    "tag": "vless-in"
                }
                config['inbounds'].append(vless_inbound)
                logger.info(f"Добавлен VLESS inbound на порт {vless_port}")
            
            # Создаем VMESS inbound если его нет (используем отдельный порт)
            if not vmess_inbound:
                vmess_inbound = {
                    "port": vmess_port,
                    "protocol": "vmess",
                    "settings": {
                        "clients": []
                    },
                    "streamSettings": {
                        "network": "tcp",
                        "security": "none"
                    },
                    "tag": "vmess-in"
                }
                config['inbounds'].append(vmess_inbound)
                logger.info(f"Добавлен VMESS inbound на порт {vmess_port}")
            
            # Добавляем Stats API inbound если его нет
            stats_inbound = None
            for inbound in config.get('inbounds', []):
                if inbound.get('protocol') == 'dokodemo-door' and inbound.get('port') == 10085:
                    stats_inbound = inbound
                    break
            
            if not stats_inbound:
                stats_inbound = {
                    "port": 10085,
                    "protocol": "dokodemo-door",
                    "settings": {
                        "address": "127.0.0.1"
                    },
                    "tag": "stats-api"
                }
                config['inbounds'].append(stats_inbound)
                logger.info("Добавлен Stats API inbound на порт 10085")
            
            # Сохраняем конфигурацию
            if not xray_manager._write_xray_config(server, config):
                raise Exception("Не удалось сохранить конфигурацию XRay")
            
            # Перезагружаем XRay
            reload_result = xray_manager._reload_xray(server)
            if not reload_result:
                logger.warning(f"Не удалось перезагрузить XRay на сервере {server.id}")
            
            logger.info(f"Базовая конфигурация XRay успешно настроена на сервере {server.id}")
            
            return {
                'success': True,
                'port': vless_port,
                'vmess_port': vmess_port,
                'vless_configured': True,
                'message': 'Базовая конфигурация XRay создана'
            }
            
        except Exception as e:
            logger.error(f"Ошибка настройки базовой конфигурации XRay на сервере {server.id}: {e}", exc_info=True)
            return {
                'success': False,
                'error': str(e)
            }
    
    def setup_reality(self, server: Server, sni: str = "google.com", dest: str = "google.com:443") -> Dict[str, Any]:
        """
        Настраивает REALITY протокол на сервере
        
        Args:
            server: Сервер для настройки
            sni: Server Name Indication (по умолчанию google.com)
            dest: Destination адрес (по умолчанию google.com:443)
            
        Returns:
            Результат настройки с ключами
        """
        ssh_config = self.remote_manager.get_ssh_config(server)
        xray_manager = XrayManager(server)
        
        logger.info(f"Настройка REALITY на сервере {server.id} (SNI: {sni}, Dest: {dest})")
        
        try:
            # 1. Генерируем ключи REALITY
            logger.info("Генерация ключей REALITY...")
            keygen_result = self.remote_manager.ssh_manager.execute_command(
                ssh_config['host'],
                "xray x25519",
                ssh_config['port'],
                ssh_config['username'],
                ssh_config.get('key_path'),
                ssh_config.get('key_content'),
                ssh_config.get('password')
            )
            
            if not keygen_result['success']:
                raise Exception(f"Не удалось сгенерировать ключи REALITY: {keygen_result.get('stderr')}")
            
            # Парсим ключи из вывода
            output = keygen_result['stdout']
            private_key = None
            public_key = None
            
            for line in output.split('\n'):
                if 'Private key:' in line:
                    private_key = line.split('Private key:')[1].strip()
                elif 'Public key:' in line:
                    public_key = line.split('Public key:')[1].strip()
            
            if not private_key or not public_key:
                # Альтернативный способ парсинга
                lines = output.strip().split('\n')
                for i, line in enumerate(lines):
                    if 'key' in line.lower() and 'private' in line.lower():
                        if i + 1 < len(lines):
                            private_key = lines[i + 1].strip()
                    elif 'key' in line.lower() and 'public' in line.lower():
                        if i + 1 < len(lines):
                            public_key = lines[i + 1].strip()
            
            if not private_key or not public_key:
                raise Exception("Не удалось извлечь ключи REALITY из вывода")
            
            logger.info(f"Ключи REALITY сгенерированы: public_key={public_key[:20]}...")
            
            # 2. Генерируем short_id (8 байт в hex = 16 символов)
            short_id = secrets.token_hex(8)
            
            # 3. Читаем конфигурацию
            config = xray_manager._read_xray_config(server)
            
            # 4. Находим или создаем VLESS inbound с REALITY
            reality_port = server.xray_port or XRAY_REALITY_DEFAULT_PORT
            reality_inbound = None
            
            for inbound in config.get('inbounds', []):
                if inbound.get('protocol') == 'vless' and inbound.get('port') == reality_port:
                    reality_inbound = inbound
                    break
            
            if not reality_inbound:
                reality_inbound = {
                    "port": reality_port,
                    "protocol": "vless",
                    "settings": {
                        "clients": [],
                        "decryption": "none"
                    },
                    "streamSettings": {
                        "network": "tcp",
                        "security": "reality",
                        "realitySettings": {
                            "show": False,
                            "dest": dest,
                            "xver": 0,
                            "serverNames": [sni],
                            "privateKey": private_key,
                            "shortIds": [short_id]
                        }
                    },
                    "tag": "reality-in"
                }
                config['inbounds'].append(reality_inbound)
            else:
                # Обновляем существующий inbound
                if 'streamSettings' not in reality_inbound:
                    reality_inbound['streamSettings'] = {}
                reality_inbound['streamSettings']['network'] = 'tcp'
                reality_inbound['streamSettings']['security'] = 'reality'
                reality_inbound['streamSettings']['realitySettings'] = {
                    "show": False,
                    "dest": dest,
                    "xver": 0,
                    "serverNames": [sni],
                    "privateKey": private_key,
                    "shortIds": [short_id]
                }
            
            # 5. Сохраняем конфигурацию
            if not xray_manager._write_xray_config(server, config):
                raise Exception("Не удалось сохранить конфигурацию REALITY")
            
            # 6. Перезагружаем XRay
            reload_result = xray_manager._reload_xray(server)
            if not reload_result:
                logger.warning(f"Не удалось перезагрузить XRay после настройки REALITY на сервере {server.id}")
            
            logger.info(f"REALITY успешно настроен на сервере {server.id}")
            
            return {
                'success': True,
                'private_key': private_key,
                'public_key': public_key,
                'short_id': short_id,
                'sni': sni,
                'dest': dest,
                'port': reality_port,
                'message': 'REALITY успешно настроен'
            }
            
        except Exception as e:
            logger.error(f"Ошибка настройки REALITY на сервере {server.id}: {e}", exc_info=True)
            return {
                'success': False,
                'error': str(e)
            }
    
    def provision_server(self, server: Server, protocols: List[str] = None) -> Dict[str, Any]:
        """
        Полная настройка сервера: установка XRay и настройка протоколов
        
        Args:
            server: Сервер для настройки
            protocols: Список протоколов для настройки ['wireguard', 'xray_vless', 'xray_vmess', 'xray_reality']
            
        Returns:
            Результат настройки
        """
        if protocols is None:
            protocols = server.get_supported_protocols() if hasattr(server, 'get_supported_protocols') else []
        
        logger.info(f"Начало полной настройки сервера {server.id} с протоколами: {protocols}")
        
        results = {
            'server_id': server.id,
            'server_ip': server.ip_address,
            'protocols': protocols,
            'steps': {}
        }
        
        # 1. Установка XRay (если нужны XRay протоколы)
        xray_protocols = [p for p in protocols if 'xray' in p.lower()]
        if xray_protocols:
            install_result = self.install_xray(server)
            results['steps']['xray_installation'] = install_result
            
            if not install_result.get('success'):
                logger.error(f"Не удалось установить XRay на сервере {server.id}")
                results['success'] = False
                results['error'] = 'XRay installation failed'
                return results
            
            # 2. Настройка базовой конфигурации XRay (plain VLESS всегда на XRAY_VLESS_DEFAULT_PORT; xray_port в БД — для REALITY)
            config_result = self.setup_base_xray_config(server, XRAY_VLESS_DEFAULT_PORT)
            results['steps']['xray_config'] = config_result
            
            if not config_result.get('success'):
                logger.error(f"Не удалось настроить базовую конфигурацию XRay на сервере {server.id}")
                results['success'] = False
                results['error'] = 'XRay configuration failed'
                return results
            
            # 3. Настройка REALITY (если нужен)
            if 'xray_reality' in protocols or 'reality' in protocols:
                reality_result = self.setup_reality(server)
                results['steps']['reality_setup'] = reality_result
                
                if not reality_result.get('success'):
                    logger.warning(f"Не удалось настроить REALITY на сервере {server.id}, но продолжаем")
                else:
                    # Обновляем сервер в БД с ключами REALITY
                    # Это должно быть сделано в вызывающем коде
                    logger.info(f"REALITY настроен, ключи: public_key={reality_result.get('public_key')[:20]}...")
        
        results['success'] = True
        results['message'] = f'Сервер {server.id} успешно настроен с протоколами: {", ".join(protocols)}'
        
        logger.info(f"Полная настройка сервера {server.id} завершена успешно")
        
        return results
