import logging
from typing import Dict, Any, Optional, List, Tuple
import re
import ipaddress
import shlex

# Опциональный импорт SSHManager (зависит от paramiko)
try:
    from infrastructure.external.ssh_manager import SSHManager
    SSH_MANAGER_AVAILABLE = True
except ImportError as e:
    SSHManager = None
    SSH_MANAGER_AVAILABLE = False
    logging.warning(f"SSHManager недоступен (paramiko не установлен): {e}")

# Импорт retry менеджера
try:
    from infrastructure.external.ssh_retry_manager import SSHRetryManager
    RETRY_MANAGER_AVAILABLE = True
except ImportError:
    SSHRetryManager = None
    RETRY_MANAGER_AVAILABLE = False

from domain.models.user import Device
from domain.models.server import Server

logger = logging.getLogger(__name__)

class RemoteVPNManager:
    """Менеджер для управления VPN на удаленных серверах через SSH"""
    
    def __init__(self):
        if SSH_MANAGER_AVAILABLE and SSHManager:
            self.ssh_manager = SSHManager()
            logger.info("RemoteVPNManager инициализирован с SSHManager")
        else:
            self.ssh_manager = None
            logger.error("RemoteVPNManager инициализирован без SSHManager. SSH функции недоступны. Установите paramiko: pip install paramiko")
    
    def get_ssh_config(self, server: Server) -> Dict[str, Any]:
        """Получает SSH конфигурацию из модели Server"""
        ssh_config = {
            'host': getattr(server, 'ssh_host', None) or server.ip_address,
            'port': getattr(server, 'ssh_port', 22),
            'username': getattr(server, 'ssh_user', 'root'),
            'key_path': getattr(server, 'ssh_key_path', None),
            'key_content': getattr(server, 'ssh_key_content', None),
        }
        
        # Используем пароль только если нет SSH ключей
        has_keys = ssh_config['key_path'] or ssh_config['key_content']
        if not has_keys:
            ssh_password = getattr(server, 'ssh_password', None)
            
            # КРИТИЧНО: Никогда не используем хардкод пароли в коде!
            # Пароли должны храниться только в БД или переменных окружения
            # Если пароль не указан, требуем SSH ключ
            if not ssh_password:
                # Пробуем получить из переменных окружения (только для development)
                import os
                from core.config import settings
                from core.logging_utils import mask_sensitive_string
                
                # Только для development окружения и только если явно указано
                if settings.env.lower() == "development":
                    env_key = f"SSH_PASSWORD_{server.ip_address.replace('.', '_')}"
                    ssh_password = os.getenv(env_key)
                    
                    if ssh_password:
                        masked_password = mask_sensitive_string(ssh_password)
                        logger.warning(
                            f"Используется пароль из переменной окружения для {server.ip_address} "
                            f"(пароль: {masked_password}). В production используйте SSH ключи!",
                            extra={
                                'server_ip': server.ip_address,
                                'server_id': getattr(server, 'id', None),
                                'password_source': 'environment_variable'
                            }
                        )
                    else:
                        logger.error(
                            f"SSH пароль не указан для сервера {server.ip_address}. "
                            f"Установите SSH ключ или переменную окружения {env_key}",
                            extra={
                                'server_ip': server.ip_address,
                                'server_id': getattr(server, 'id', None),
                                'missing_auth': True
                            }
                        )
                        raise RuntimeError(
                            f"SSH аутентификация не настроена для сервера {server.ip_address}. "
                            f"Установите SSH ключ (ssh_key_path или ssh_key_content) или пароль в БД. "
                            f"Хардкод пароли в коде запрещены по соображениям безопасности."
                        )
                else:
                    # В production строго требуем SSH ключи
                    logger.error(
                        f"SSH пароль не указан для сервера {server.ip_address} в production окружении. "
                        f"Используйте SSH ключи для безопасности.",
                        extra={
                            'server_ip': server.ip_address,
                            'server_id': getattr(server, 'id', None),
                            'environment': 'production',
                            'missing_auth': True
                        }
                    )
                    raise RuntimeError(
                        f"SSH аутентификация не настроена для сервера {server.ip_address}. "
                        f"В production окружении разрешены только SSH ключи. "
                        f"Установите ssh_key_path или ssh_key_content в настройках сервера."
                    )
            
            ssh_config['password'] = ssh_password
        else:
            ssh_config['password'] = None
        
        return ssh_config

    def with_ssh_connection(self, server: Server, callback):
        """
        Выполняет callback(ssh_client) в рамках одного SSH-соединения.
        Используется для оптимизации Xray create-client (один handshake на все операции).
        """
        if not self.ssh_manager:
            raise RuntimeError("SSH недоступен")
        ssh_config = self.get_ssh_config(server)
        return self.ssh_manager.with_connection(
            ssh_config["host"],
            ssh_config["port"],
            ssh_config["username"],
            callback,
            key_path=ssh_config.get("key_path"),
            key_content=ssh_config.get("key_content"),
            password=ssh_config.get("password"),
        )
    
    def _is_remote_server(self, server: Server) -> bool:
        """Проверяет, является ли сервер удаленным"""
        return getattr(server, 'is_local', False) == False
    
    # ========== WireGuard методы ==========
    
    def generate_wireguard_key_pair(self, server: Server) -> Dict[str, str]:
        """Генерирует пару ключей WireGuard на удаленном сервере"""
        from infrastructure.external.ssh_command_validator import SSHCommandValidator
        
        ssh_config = self.get_ssh_config(server)
        
        # Валидация входных данных
        if not SSHCommandValidator.validate_ip_address(ssh_config['host']):
            raise ValueError(f"Невалидный IP адрес: {ssh_config['host']}")
        
        if not SSHCommandValidator.validate_port(ssh_config['port']):
            raise ValueError(f"Невалидный порт: {ssh_config['port']}")
        
        # Генерируем приватный ключ (команда безопасна, не принимает аргументов)
        if not SSHCommandValidator.validate_wireguard_key_generation():
            raise ValueError("Команда генерации ключа не прошла валидацию")
        
        result = self.ssh_manager.execute_command(
            ssh_config['host'],
            "wg genkey",
            ssh_config['port'],
            ssh_config['username'],
            ssh_config.get('key_path'),
            ssh_config.get('key_content'),
            ssh_config.get('password')
        )
        
        if not result['success']:
            raise Exception(f"Не удалось сгенерировать приватный ключ: {result['stderr']}")
        
        private_key = result['stdout'].strip()
        
        # Валидация сгенерированного ключа
        if not SSHCommandValidator.validate_key(private_key):
            raise ValueError("Сгенерированный приватный ключ не прошел валидацию")
        
        # Генерируем публичный ключ безопасным способом
        # Используем временный файл с безопасным именем для предотвращения инъекций
        if not SSHCommandValidator.validate_wireguard_pubkey_command(private_key):
            raise ValueError("Команда генерации публичного ключа не прошла валидацию")
        
        # Безопасный способ: используем временный файл с случайным именем
        import secrets
        import shlex
        
        # Генерируем безопасное имя временного файла
        temp_file = f"/tmp/wg_key_{secrets.token_hex(16)}"
        
        # Валидация имени файла
        if not SSHCommandValidator.validate_path(temp_file):
            raise ValueError(f"Невалидное имя временного файла: {temp_file}")
        
        # Безопасная команда: создаем файл, записываем ключ, генерируем публичный ключ, удаляем файл
        # Используем shlex.quote для безопасного экранирования
        safe_private_key = shlex.quote(private_key)
        safe_temp_file = shlex.quote(temp_file)
        
        # Команда выполняется атомарно: создание файла -> запись ключа -> генерация публичного ключа -> удаление файла
        safe_command = f"echo {safe_private_key} > {safe_temp_file} && wg pubkey < {safe_temp_file} && rm -f {safe_temp_file}"
        
        # Дополнительная валидация команды
        if not SSHCommandValidator.validate_command_string(safe_command):
            raise ValueError("Команда генерации публичного ключа не прошла валидацию безопасности")
        
        # Используем retry для надежности
        if RETRY_MANAGER_AVAILABLE and SSHRetryManager:
            def execute_pubkey():
                return self.ssh_manager.execute_command(
                    ssh_config['host'],
                    safe_command,
                    ssh_config['port'],
                    ssh_config['username'],
                    ssh_config.get('key_path'),
                    ssh_config.get('key_content'),
                    ssh_config.get('password')
                )
            
            result = SSHRetryManager.execute_with_retry(
                execute_pubkey,
                max_retries=3,
                initial_delay=1.0
            )
        else:
            result = self.ssh_manager.execute_command(
                ssh_config['host'],
                safe_command,
                ssh_config['port'],
                ssh_config['username'],
                ssh_config.get('key_path'),
                ssh_config.get('key_content'),
                ssh_config.get('password')
            )
        
        if not result['success']:
            raise Exception(f"Не удалось сгенерировать публичный ключ: {result['stderr']}")
        
        public_key = result['stdout'].strip()
        
        # Валидация сгенерированного публичного ключа
        if not SSHCommandValidator.validate_key(public_key):
            raise ValueError("Сгенерированный публичный ключ не прошел валидацию")
        
        return {
            'private_key': private_key,
            'public_key': public_key
        }
    
    def get_wireguard_config(self, server: Server) -> Optional[str]:
        """Получает конфигурацию WireGuard с удаленного сервера"""
        from infrastructure.external.ssh_command_validator import SSHCommandValidator
        
        ssh_config = self.get_ssh_config(server)
        config_path = getattr(server, 'wireguard_config_path', '/etc/wireguard/wg0.conf')
        
        # Валидация пути
        if not SSHCommandValidator.validate_path(config_path):
            raise ValueError(f"Невалидный путь к конфигурации: {config_path}")
        
        # Используем retry для надежности
        if RETRY_MANAGER_AVAILABLE and SSHRetryManager:
            def download():
                return self.ssh_manager.download_content(
                    ssh_config['host'],
                    config_path,
                    ssh_config['port'],
                    ssh_config['username'],
                    ssh_config.get('key_path'),
                    ssh_config.get('key_content'),
                    ssh_config.get('password')
                )
            
            return SSHRetryManager.execute_with_retry(
                download,
                max_retries=3,
                initial_delay=1.0
            )
        else:
            return self.ssh_manager.download_content(
                ssh_config['host'],
                config_path,
                ssh_config['port'],
                ssh_config['username'],
                ssh_config.get('key_path'),
                ssh_config.get('key_content'),
                ssh_config.get('password')
            )
    
    def update_wireguard_config(self, server: Server, config_content: str) -> bool:
        """Обновляет конфигурацию WireGuard на удаленном сервере"""
        ssh_config = self.get_ssh_config(server)
        config_path = getattr(server, 'wireguard_config_path', '/etc/wireguard/wg0.conf')

        config_content = self._normalize_wireguard_config(config_content)
        
        # Загружаем конфигурацию атомарно, чтобы не оставить обрезанный wg0.conf.
        upload_atomic = getattr(self.ssh_manager, 'upload_content_atomic', None)
        success = False
        if upload_atomic:
            success = upload_atomic(
                ssh_config['host'],
                config_content,
                config_path,
                ssh_config['port'],
                ssh_config['username'],
                ssh_config['key_path'],
                ssh_config['key_content'],
                ssh_config.get('password')
            )
            if not success:
                logger.warning(
                    "Atomic WireGuard config upload failed on server %s; falling back to direct upload",
                    getattr(server, 'id', None),
                )
        if not success:
            success = self.ssh_manager.upload_content(
                ssh_config['host'],
                config_content,
                config_path,
                ssh_config['port'],
                ssh_config['username'],
                ssh_config['key_path'],
                ssh_config['key_content'],
                ssh_config.get('password')
            )
        
        if success:
            # Устанавливаем правильные права доступа
            self.ssh_manager.execute_command(
                ssh_config['host'],
                f"chmod 600 {config_path}",
                ssh_config['port'],
                ssh_config['username'],
                ssh_config['key_path'],
                ssh_config['key_content'],
                ssh_config.get('password')
            )
        
        return success

    def _normalize_wireguard_config(self, config: str) -> str:
        """Нормализует WireGuard конфиг: SaveConfig=false, peer cleanup и дедупликация."""
        if not config:
            return config
        lines = config.split('\n')
        normalized_lines = []
        for line in lines:
            if line.strip().startswith('SaveConfig'):
                normalized_lines.append('SaveConfig = false')
            else:
                normalized_lines.append(line)
        config = '\n'.join(normalized_lines)
        return self._dedupe_wireguard_peers(config)

    def _dedupe_wireguard_peers(self, config: str) -> str:
        """Удаляет мусорные и дублирующиеся peer-блоки по PublicKey, оставляя последний."""
        if not config:
            return config
        lines = config.split('\n')
        header = []
        peer_blocks = []
        current = []
        in_peer = False
        peer_only_keys = (
            'PublicKey',
            'PresharedKey',
            'AllowedIPs',
            'Endpoint',
            'PersistentKeepalive',
        )

        for line in lines:
            if line.strip().startswith('[Peer]'):
                if in_peer and current:
                    peer_blocks.append(current)
                in_peer = True
                current = [line]
                continue
            if in_peer:
                current.append(line)
                if line.strip() == '':
                    peer_blocks.append(current)
                    current = []
                    in_peer = False
                continue
            stripped = line.strip()
            if stripped.startswith('# Peer for device'):
                continue
            if any(stripped.startswith(f'{key} =') for key in peer_only_keys):
                continue
            header.append(line)

        if in_peer and current:
            peer_blocks.append(current)

        by_key = {}
        for block in peer_blocks:
            public_key = None
            allowed_ips = None
            for block_line in block:
                if block_line.strip().startswith('PublicKey ='):
                    public_key = block_line.split('=', 1)[1].strip()
                if block_line.strip().startswith('AllowedIPs ='):
                    allowed_ips = block_line.split('=', 1)[1].strip()
            if public_key and allowed_ips:
                by_key[public_key] = block

        merged = '\n'.join(header).rstrip()
        for block in by_key.values():
            merged += '\n' + '\n'.join(block).rstrip() + '\n'
        return merged.strip() + '\n'
    
    def add_wireguard_peer(
        self,
        server: Server,
        device: Device,
        client_ip: str,
        preshared_key: Optional[str] = None,
    ) -> bool:
        """Добавляет пир в конфигурацию WireGuard на удаленном сервере"""
        # КРИТИЧНО: SSH обязателен для работы с удаленными серверами
        if not self.ssh_manager:
            error_msg = f"SSHManager недоступен для сервера {server.id}. Установите paramiko: pip install paramiko"
            logger.error(error_msg)
            raise RuntimeError(error_msg)
        
        try:
            # Проверяем и настраиваем IP forwarding
            if not self.check_ip_forwarding(server):
                logger.info(f"Включаем IP forwarding на сервере {server.id}")
                if not self.enable_ip_forwarding(server):
                    logger.warning(f"Не удалось включить IP forwarding на сервере {server.id}")
                    # Продолжаем, так как правила могут быть настроены вручную
            
            # Получаем текущую конфигурацию
            config = self.get_wireguard_config(server)
            if not config:
                # Если конфигурации нет, создаем базовую
                logger.info(f"Создаем базовую конфигурацию WireGuard для сервера {server.id}")
                config = self._create_base_wireguard_config(server)
                
                # Проверяем, что базовая конфигурация содержит PostUp/PostDown
                if "PostUp" not in config or "PostDown" not in config:
                    logger.warning(f"Базовая конфигурация не содержит PostUp/PostDown, добавляем")
                    main_interface = self._get_main_network_interface(server)
                    # Добавляем PostUp/PostDown если их нет
                    lines = config.split('\n')
                    interface_line_idx = None
                    for i, line in enumerate(lines):
                        if line.startswith('ListenPort'):
                            interface_line_idx = i
                            break
                    
                    if interface_line_idx:
                        post_up = f"PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o {main_interface} -j MASQUERADE"
                        post_down = f"PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o {main_interface} -j MASQUERADE"
                        lines.insert(interface_line_idx + 1, post_up)
                        lines.insert(interface_line_idx + 2, post_down)
                        config = '\n'.join(lines)
            else:
                # Проверяем наличие PostUp/PostDown в существующей конфигурации
                if "PostUp" not in config or "PostDown" not in config:
                    logger.warning(f"Конфигурация сервера {server.id} не содержит PostUp/PostDown, добавляем")
                    main_interface = self._get_main_network_interface(server)
                    # Находим строку с ListenPort и добавляем после неё
                    lines = config.split('\n')
                    interface_line_idx = None
                    for i, line in enumerate(lines):
                        if line.startswith('ListenPort'):
                            interface_line_idx = i
                            break
                    
                    if interface_line_idx:
                        post_up = f"PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o {main_interface} -j MASQUERADE"
                        post_down = f"PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o {main_interface} -j MASQUERADE"
                        lines.insert(interface_line_idx + 1, post_up)
                        lines.insert(interface_line_idx + 2, post_down)
                        config = '\n'.join(lines)
            
            # Удаляем старые блоки для этого public key, чтобы избежать дублей
            if device.wireguard_public_key:
                config = self._remove_peer_by_public_key(config, device.wireguard_public_key)

            # Добавляем нового пира
            peer_config = f"""

# Peer for device {device.id} - {device.device_name or device.device_id}
[Peer]
PublicKey = {device.wireguard_public_key}
{f"PresharedKey = {preshared_key}" if preshared_key else ""}
AllowedIPs = {client_ip}/32
"""
            config += peer_config
            
            # Обновляем конфигурацию
            if not self.update_wireguard_config(server, config):
                error_msg = f"Не удалось обновить конфигурацию WireGuard на сервере {server.id}"
                logger.error(error_msg)
                raise RuntimeError(error_msg)
            
            # Применяем peer в живой интерфейс без полного down/up. Для AmneziaWG
            # полный reload может перезаписать только что обновленный конфиг
            # текущим runtime-состоянием и потерять нового peer.
            runtime_result = self._apply_wireguard_peer_runtime(
                server,
                device,
                client_ip,
                preshared_key=preshared_key,
            )
            if not runtime_result:
                error_msg = f"Не удалось применить WireGuard peer на сервере {server.id}"
                logger.error(error_msg)
                raise RuntimeError(error_msg)
            
            logger.info(f"Пир успешно добавлен на сервер {server.id} для устройства {device.id}")
            return True
            
        except Exception as e:
            error_msg = f"Ошибка добавления пира WireGuard на сервере {server.id}: {e}"
            logger.error(error_msg, exc_info=True)
            raise RuntimeError(error_msg) from e

    def _apply_wireguard_peer_runtime(
        self,
        server: Server,
        device: Device,
        client_ip: str,
        preshared_key: Optional[str] = None,
    ) -> bool:
        """Применяет peer к поднятому wg/awg интерфейсу без перезапуска туннеля."""
        if not device.wireguard_public_key:
            return False
        ssh_config = self.get_ssh_config(server)
        interface = getattr(server, 'wireguard_interface', 'wg0')
        config_path = getattr(server, 'wireguard_config_path', '/etc/wireguard/wg0.conf')
        safe_interface = shlex.quote(interface)
        safe_config_path = shlex.quote(config_path)
        safe_public_key = shlex.quote(device.wireguard_public_key)
        safe_allowed_ip = shlex.quote(f'{client_ip}/32')
        command = (
            "set -e; "
            "tool=wg; quick=wg-quick; "
            f"if command -v awg >/dev/null 2>&1 && "
            f"(grep -Eq '^(Jc|Jmin|Jmax|H1|H2|H3|H4)\\s*=' {safe_config_path} 2>/dev/null || "
            f"printf '%s' {shlex.quote(config_path)} | grep -q '/amnezia/'); "
            "then tool=awg; quick=awg-quick; fi; "
            f"if ip link show {safe_interface} >/dev/null 2>&1; then "
        )
        if preshared_key:
            command += (
                "tmp=$(mktemp); "
                "trap 'rm -f \"$tmp\"' EXIT; "
                f"printf '%s\\n' {shlex.quote(preshared_key)} > \"$tmp\"; "
                f"$tool set {safe_interface} peer {safe_public_key} "
                f"preshared-key \"$tmp\" allowed-ips {safe_allowed_ip}; "
            )
        else:
            command += (
                f"$tool set {safe_interface} peer {safe_public_key} "
                f"allowed-ips {safe_allowed_ip}; "
            )
        command += (
            "else "
            f"$quick up {safe_interface}; "
            "fi; "
            f"$tool show {safe_interface} dump | grep -F -- {safe_public_key}"
        )

        result = self.ssh_manager.execute_command(
            ssh_config['host'],
            command,
            ssh_config['port'],
            ssh_config['username'],
            ssh_config['key_path'],
            ssh_config['key_content'],
            ssh_config.get('password'),
        )
        if not result['success']:
            logger.error(
                "WireGuard peer runtime apply failed on server %s: stdout=%s stderr=%s",
                getattr(server, 'id', None),
                result.get('stdout', ''),
                result.get('stderr', ''),
            )
        return result['success']

    def _remove_peer_by_public_key(self, config: str, public_key: str) -> str:
        """Удаляет peer-блоки с заданным public key"""
        lines = config.split('\n')
        new_lines = []
        current_block = []
        in_peer = False

        def flush_block():
            nonlocal current_block, in_peer
            if not current_block:
                return
            has_key = any(
                line.strip().startswith('PublicKey =') and line.split('=', 1)[1].strip() == public_key
                for line in current_block
            )
            if not has_key:
                new_lines.extend(current_block)
            current_block = []
            in_peer = False

        for line in lines:
            if line.strip().startswith('[Peer]'):
                flush_block()
                in_peer = True
                current_block = [line]
                continue
            if in_peer:
                current_block.append(line)
                if line.strip() == '':
                    flush_block()
                continue
            new_lines.append(line)

        flush_block()
        return '\n'.join(new_lines)
    
    def remove_wireguard_peer(self, server: Server, device: Device) -> bool:
        """Удаляет пир из конфигурации WireGuard на удаленном сервере"""
        try:
            config = self.get_wireguard_config(server)
            if not config:
                return False
            
            # Удаляем секцию пира
            lines = config.split('\n')
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
            
            # Обновляем конфигурацию
            new_config = '\n'.join(new_lines)
            if not self.update_wireguard_config(server, new_config):
                return False
            
            # Перезагружаем WireGuard
            return self.reload_wireguard(server)
            
        except Exception as e:
            logger.error(f"Ошибка удаления пира WireGuard: {e}")
            return False
    
    def reload_wireguard(self, server: Server) -> bool:
        """Перезагружает WireGuard интерфейс на удаленном сервере"""
        ssh_config = self.get_ssh_config(server)
        interface = getattr(server, 'wireguard_interface', 'wg0')
        config_path = getattr(server, 'wireguard_config_path', '/etc/wireguard/wg0.conf')
        safe_interface = shlex.quote(interface)
        safe_config_path = shlex.quote(config_path)
        reload_command = (
            "set -e; "
            f"tool=wg-quick; "
            f"if command -v awg-quick >/dev/null 2>&1 && "
            f"(grep -Eq '^(Jc|Jmin|Jmax|H1|H2|H3|H4)\\s*=' {safe_config_path} 2>/dev/null || "
            f"printf '%s' {shlex.quote(config_path)} | grep -q '/amnezia/'); "
            f"then tool=awg-quick; fi; "
            f"$tool down {safe_interface} >/tmp/grani-wg-down.log 2>&1 || true; "
            f"$tool up {safe_interface}"
        )
        
        result = self.ssh_manager.execute_command(
            ssh_config['host'],
            reload_command,
            ssh_config['port'],
            ssh_config['username'],
            ssh_config['key_path'],
            ssh_config['key_content'],
            ssh_config.get('password')
        )
        if not result['success']:
            logger.error(
                "WireGuard reload failed on server %s: stdout=%s stderr=%s",
                getattr(server, 'id', None),
                result.get('stdout', ''),
                result.get('stderr', ''),
            )
        return result['success']
    
    def get_wireguard_status(self, server: Server) -> Dict[str, Any]:
        """Получает статус WireGuard на удаленном сервере"""
        ssh_config = self.get_ssh_config(server)
        interface = getattr(server, 'wireguard_interface', 'wg0')
        
        result = self.ssh_manager.execute_command(
            ssh_config['host'],
            f"wg show {interface}",
            ssh_config['port'],
            ssh_config['username'],
            ssh_config['key_path'],
            ssh_config['key_content'],
            ssh_config.get('password')
        )
        
        if result['success']:
            return {
                'status': 'running',
                'output': result['stdout']
            }
        else:
            return {
                'status': 'stopped',
                'output': result['stderr']
            }
    
    def get_wireguard_used_ips(self, server: Server) -> List[str]:
        """Получает список используемых IP адресов на удаленном сервере"""
        config = self.get_wireguard_config(server)
        if not config:
            return []
        
        # Ищем все AllowedIPs в конфигурации
        matches = re.findall(r'AllowedIPs = (\d+\.\d+\.\d+\.\d+)', config)
        return list(set(matches))
    
    def get_next_available_wireguard_ip(self, server: Server, network: str = "10.0.0.0/24") -> Optional[str]:
        """Получает следующий доступный IP адрес для WireGuard"""
        used_ips = set(self.get_wireguard_used_ips(server))
        network_obj = ipaddress.IPv4Network(network, strict=False)
        first_host = str(next(network_obj.hosts(), ""))
        
        for ip in network_obj.hosts():
            ip_str = str(ip)
            if ip_str not in used_ips and ip_str != first_host:  # Первый host адрес - сервер
                return ip_str
        
        return None
    
    def _get_main_network_interface(self, server: Server) -> str:
        """Автоматически определяет основной сетевой интерфейс сервера"""
        ssh_config = self.get_ssh_config(server)
        
        # КРИТИЧНО: SSH обязателен для определения интерфейса
        if not self.ssh_manager:
            logger.warning(f"SSHManager недоступен, используем eth0 по умолчанию (может быть неверно)")
            return "eth0"
        
        try:
            # Получаем интерфейс по умолчанию
            result = self.ssh_manager.execute_command(
                ssh_config['host'],
                "ip route | grep default | awk '{print $5}' | head -n1",
                ssh_config['port'],
                ssh_config['username'],
                ssh_config['key_path'],
                ssh_config['key_content'],
                ssh_config.get('password')
            )
            
            if result['success'] and result['stdout'].strip():
                interface = result['stdout'].strip()
                logger.info(f"Определен сетевой интерфейс: {interface}")
                return interface
            else:
                # Пробуем альтернативный способ
                result = self.ssh_manager.execute_command(
                    ssh_config['host'],
                    "route | grep default | awk '{print $8}' | head -n1",
                    ssh_config['port'],
                    ssh_config['username'],
                    ssh_config['key_path'],
                    ssh_config['key_content'],
                    ssh_config.get('password')
                )
                
                if result['success'] and result['stdout'].strip():
                    interface = result['stdout'].strip()
                    logger.info(f"Определен сетевой интерфейс (альтернативный способ): {interface}")
                    return interface
        except Exception as e:
            logger.warning(f"Ошибка определения сетевого интерфейса: {e}")
        
        # Возвращаем значение по умолчанию
        logger.warning(f"Не удалось определить сетевой интерфейс, используем eth0")
        return "eth0"
    
    def check_ip_forwarding(self, server: Server) -> bool:
        """Проверяет, включен ли IP forwarding на сервере"""
        ssh_config = self.get_ssh_config(server)
        
        # КРИТИЧНО: SSH обязателен для проверки IP forwarding
        if not self.ssh_manager:
            logger.warning(f"SSHManager недоступен, не можем проверить IP forwarding на сервере {server.id}")
            return False
        
        try:
            result = self.ssh_manager.execute_command(
                ssh_config['host'],
                "sysctl net.ipv4.ip_forward | awk '{print $3}'",
                ssh_config['port'],
                ssh_config['username'],
                ssh_config['key_path'],
                ssh_config['key_content'],
                ssh_config.get('password')
            )
            
            if result['success']:
                value = result['stdout'].strip()
                is_enabled = value == "1"
                if not is_enabled:
                    logger.warning(f"IP forwarding отключен на сервере {server.id}, значение: {value}")
                return is_enabled
        except Exception as e:
            logger.warning(f"Ошибка проверки IP forwarding: {e}")
        
        return False
    
    def enable_ip_forwarding(self, server: Server) -> bool:
        """Включает IP forwarding на сервере"""
        ssh_config = self.get_ssh_config(server)
        
        # КРИТИЧНО: SSH обязателен для включения IP forwarding
        if not self.ssh_manager:
            error_msg = f"SSHManager недоступен, не можем включить IP forwarding на сервере {server.id}"
            logger.error(error_msg)
            raise RuntimeError(error_msg)
        
        try:
            # Проверяем, не включен ли уже
            if self.check_ip_forwarding(server):
                logger.info(f"IP forwarding уже включен на сервере {server.id}")
                return True
            
            # Добавляем в sysctl.conf если еще нет
            result = self.ssh_manager.execute_command(
                ssh_config['host'],
                "grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf",
                ssh_config['port'],
                ssh_config['username'],
                ssh_config['key_path'],
                ssh_config['key_content'],
                ssh_config.get('password')
            )
            
            # Применяем настройки
            result = self.ssh_manager.execute_command(
                ssh_config['host'],
                "sysctl -p",
                ssh_config['port'],
                ssh_config['username'],
                ssh_config['key_path'],
                ssh_config['key_content'],
                ssh_config.get('password')
            )
            
            if result['success']:
                logger.info(f"IP forwarding включен на сервере {server.id}")
                return True
        except Exception as e:
            logger.error(f"Ошибка включения IP forwarding: {e}")
        
        return False
    
    def check_iptables_rules(self, server: Server, interface: str = "wg0") -> Dict[str, bool]:
        """Проверяет наличие необходимых iptables правил"""
        ssh_config = self.get_ssh_config(server)
        
        # КРИТИЧНО: SSH обязателен для проверки iptables правил
        if not self.ssh_manager:
            logger.warning(f"SSHManager недоступен, не можем проверить iptables правила на сервере {server.id}")
            return {"forward": False, "masquerade": False}
        
        result = {
            "forward": False,
            "masquerade": False
        }
        
        try:
            # Проверяем правило FORWARD
            cmd = f"iptables -C FORWARD -i {interface} -j ACCEPT 2>/dev/null && echo 'OK' || echo 'MISSING'"
            forward_result = self.ssh_manager.execute_command(
                ssh_config['host'],
                cmd,
                ssh_config['port'],
                ssh_config['username'],
                ssh_config['key_path'],
                ssh_config['key_content'],
                ssh_config.get('password')
            )
            
            if forward_result['success']:
                result["forward"] = "OK" in forward_result['stdout']
            
            # Проверяем правило MASQUERADE (проверяем наличие в цепочке POSTROUTING)
            cmd = "iptables -t nat -L POSTROUTING -n -v | grep -q MASQUERADE && echo 'OK' || echo 'MISSING'"
            masq_result = self.ssh_manager.execute_command(
                ssh_config['host'],
                cmd,
                ssh_config['port'],
                ssh_config['username'],
                ssh_config['key_path'],
                ssh_config['key_content'],
                ssh_config.get('password')
            )
            
            if masq_result['success']:
                result["masquerade"] = "OK" in masq_result['stdout']
        except Exception as e:
            logger.warning(f"Ошибка проверки iptables правил: {e}")
        
        return result
    
    def _create_base_wireguard_config(self, server: Server) -> str:
        """Создает базовую конфигурацию WireGuard"""
        private_key = server.wireguard_private_key or ""
        port = server.wireguard_port or 51820
        
        # Автоматически определяем сетевой интерфейс
        main_interface = self._get_main_network_interface(server)
        
        return f"""[Interface]
PrivateKey = {private_key}
Address = 10.0.0.1/24
ListenPort = {port}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o {main_interface} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o {main_interface} -j MASQUERADE

# DNS
DNS = 8.8.8.8, 8.8.4.4

# MTU
MTU = 1420

# Сохранение конфигурации (отключено, чтобы избежать перезаписи)
SaveConfig = false
"""
    
    # ========== Xray методы ==========
    
    def get_xray_config(self, server: Server) -> Optional[Dict[str, Any]]:
        """Получает конфигурацию Xray с удаленного сервера"""
        ssh_config = self.get_ssh_config(server)
        # Используем правильный путь к конфигурации XRay
        config_path = getattr(server, 'xray_config_path', '/usr/local/etc/xray/config.json')
        
        content = self.ssh_manager.download_content(
            ssh_config['host'],
            config_path,
            ssh_config['port'],
            ssh_config['username'],
            ssh_config.get('key_path'),
            ssh_config.get('key_content'),
            ssh_config.get('password')
        )
        
        if not content:
            return None
        
        try:
            import json
            return json.loads(content)
        except:
            return None
    
    def update_xray_config(self, server: Server, config: Dict[str, Any]) -> Tuple[bool, bool]:
        """
        Обновляет конфигурацию Xray: при наличии edge-токена — в очередь агента (без SSH-записи).
        Возвращает (успех, via_edge): при via_edge=True вызывающий не должен делать SSH reload — его сделает агент.
        """
        from services.edge_enqueue import try_commit_apply_xray_config_edge

        if try_commit_apply_xray_config_edge(server, config):
            return (True, True)

        ssh_config = self.get_ssh_config(server)
        # Используем правильный путь к конфигурации XRay
        config_path = getattr(server, 'xray_config_path', '/usr/local/etc/xray/config.json')
        
        try:
            import json
            config_content = json.dumps(config, indent=2)
            
            # Загружаем конфигурацию
            success = self.ssh_manager.upload_content(
                ssh_config['host'],
                config_content,
                config_path,
                ssh_config['port'],
                ssh_config['username'],
                ssh_config.get('key_path'),
                ssh_config.get('key_content'),
                ssh_config.get('password')
            )
            
            if success:
                # Устанавливаем правильные права доступа
                self.ssh_manager.execute_command(
                    ssh_config['host'],
                    f"chmod 644 {config_path}",
                    ssh_config['port'],
                    ssh_config['username'],
                    ssh_config.get('key_path'),
                    ssh_config.get('key_content'),
                    ssh_config.get('password')
                )
            
            return (success, False)
        except Exception as e:
            logger.error(f"Ошибка обновления конфигурации Xray: {e}")
            return (False, False)
    
    def add_xray_client(self, server: Server, device: Device, protocol: str = "vless") -> Optional[Dict[str, Any]]:
        """Добавляет клиента в конфигурацию Xray на удаленном сервере"""
        try:
            import uuid
            
            logger.info(f"Добавление XRay клиента: server_id={server.id}, device_id={device.id}, protocol={protocol}")
            
            config = self.get_xray_config(server)
            if not config:
                logger.error(f"Не удалось получить конфигурацию XRay с сервера {server.id}")
                return None
            
            logger.info(f"Конфигурация XRay получена, inbounds: {len(config.get('inbounds', []))}")
            
            # Нормализуем протокол (xray_vless -> vless, xray_vmess -> vmess)
            protocol_normalized = protocol.replace('xray_', '') if protocol.startswith('xray_') else protocol
            logger.info(f"Нормализованный протокол: {protocol_normalized}")
            
            # Для REALITY ищем vless inbound с security=reality
            is_reality = protocol_normalized == 'reality'
            if is_reality:
                protocol_normalized = 'vless'
                logger.info("REALITY протокол - ищем vless inbound с security=reality")
            
            # Генерируем UUID для клиента
            client_uuid = str(uuid.uuid4())
            logger.info(f"Сгенерирован UUID клиента: {client_uuid}")
            
            # Находим соответствующий inbound
            inbound_found = False
            for inbound in config.get('inbounds', []):
                inbound_protocol = inbound.get('protocol')
                inbound_security = inbound.get('streamSettings', {}).get('security', '')
                inbound_port = inbound.get('port')
                logger.debug(f"Проверка inbound: protocol={inbound_protocol}, security={inbound_security}, port={inbound_port}")
                
                # Для REALITY ищем vless с security=reality
                if is_reality:
                    if inbound_protocol == 'vless' and inbound_security == 'reality':
                        clients = inbound.get('settings', {}).get('clients', [])
                        client_config = {
                            'id': client_uuid,
                            'level': 0,
                            'email': f"{device.user_id}_{device.id}@granivpn.com",
                            'flow': 'xtls-rprx-vision'  # Обязательно для REALITY
                        }
                        clients.append(client_config)
                        inbound['settings']['clients'] = clients
                        inbound_found = True
                        logger.info(f"REALITY клиент {client_uuid} добавлен в vless inbound на сервере {server.id}, всего клиентов: {len(clients)}")
                        break
                elif inbound_protocol == protocol_normalized:
                    clients = inbound.get('settings', {}).get('clients', [])
                    client_config = {
                        'id': client_uuid,
                        'level': 0,
                        'email': f"{device.user_id}_{device.id}@granivpn.com"
                    }
                    clients.append(client_config)
                    inbound['settings']['clients'] = clients
                    inbound_found = True
                    logger.info(f"Клиент {client_uuid} добавлен в inbound {protocol_normalized} на сервере {server.id}, всего клиентов: {len(clients)}")
                    break
            
            if not inbound_found:
                available_inbounds = [f"{inbound.get('protocol')}:{inbound.get('streamSettings', {}).get('security', 'none')}" for inbound in config.get('inbounds', [])]
                logger.error(f"Inbound для протокола {protocol} не найден на сервере {server.id}. Доступные inbounds: {available_inbounds}")
                return None
            
            # Обновляем конфигурацию
            logger.info(f"Обновление конфигурации XRay на сервере {server.id}...")
            ok, via_edge = self.update_xray_config(server, config)
            if not ok:
                logger.error(f"Не удалось обновить конфигурацию XRay на сервере {server.id}")
                return None
            logger.info(f"Конфигурация XRay обновлена на сервере {server.id}")
            if via_edge:
                logger.info(f"Конфиг XRay поставлен в очередь edge на сервере {server.id}, SSH reload пропущен")
                return {
                    'client_id': client_uuid,
                    'protocol': protocol
                }
            # Перезагружаем Xray
            logger.info(f"Перезагрузка XRay на сервере {server.id}...")
            if not self.reload_xray(server):
                logger.error(f"Не удалось перезагрузить XRay на сервере {server.id}")
                return None
            logger.info(f"XRay перезагружен на сервере {server.id}")
            
            return {
                'client_id': client_uuid,
                'protocol': protocol
            }
            
        except Exception as e:
            logger.error(f"Ошибка добавления клиента Xray: {e}", exc_info=True)
            return None
    
    def remove_xray_client(self, server: Server, client_uuid: str) -> bool:
        """Удаляет клиента из конфигурации Xray на удаленном сервере"""
        try:
            config = self.get_xray_config(server)
            if not config:
                return False
            
            # Удаляем клиента из всех inbound'ов
            for inbound in config.get('inbounds', []):
                clients = inbound.get('settings', {}).get('clients', [])
                inbound['settings']['clients'] = [
                    client for client in clients if client.get('id') != client_uuid
                ]
            
            # Обновляем конфигурацию
            ok, via_edge = self.update_xray_config(server, config)
            if not ok:
                return False
            if via_edge:
                return True
            # Перезагружаем Xray
            return self.reload_xray(server)
            
        except Exception as e:
            logger.error(f"Ошибка удаления клиента Xray: {e}")
            return False
    
    def reload_xray(self, server: Server) -> bool:
        """Перезагружает Xray-v2 сервис на удаленном сервере"""
        ssh_config = self.get_ssh_config(server)
        
        # XRay не поддерживает reload, используем restart
        result = self.ssh_manager.execute_command(
            ssh_config['host'],
            "systemctl restart xray-v2",
            ssh_config['port'],
            ssh_config['username'],
            ssh_config.get('key_path'),
            ssh_config.get('key_content'),
            ssh_config.get('password')
        )
        
        return result['success']
    
    def get_xray_status(self, server: Server) -> Dict[str, Any]:
        """Получает статус Xray-v2 на удаленном сервере"""
        ssh_config = self.get_ssh_config(server)
        
        result = self.ssh_manager.execute_command(
            ssh_config['host'],
            "systemctl is-active xray-v2",
            ssh_config['port'],
            ssh_config['username'],
            ssh_config['key_path'],
            ssh_config['key_content'],
            ssh_config.get('password')
        )
        
        if result['success'] and result['stdout'].strip() == 'active':
            return {
                'status': 'running',
                'active': True
            }
        else:
            return {
                'status': 'stopped',
                'active': False
            }
    
    def get_xray_logs(
        self, 
        server: Server, 
        log_type: str = "access", 
        lines: int = 100,
        follow: bool = False
    ) -> Dict[str, Any]:
        """
        Получает логи XRay с сервера
        
        Args:
            server: Сервер
            log_type: Тип лога - "access", "error", или "journalctl" (для systemd логов)
            lines: Количество строк для получения
            follow: Следить за логами в реальном времени (не поддерживается через SSH)
        
        Returns:
            Словарь с логами и метаданными
        """
        if not self.ssh_manager:
            logger.warning(f"SSHManager недоступен для получения логов сервера {server.id}")
            return {
                'success': False,
                'error': 'SSH недоступен',
                'logs': []
            }
        
        ssh_config = self.get_ssh_config(server)
        
        try:
            if log_type == "journalctl":
                # Получаем логи через systemd journal
                command = f"journalctl -u xray-v2 -n {lines} --no-pager"
            elif log_type == "error":
                # Получаем логи ошибок из файла
                command = f"tail -n {lines} /var/log/xray/error.log 2>/dev/null || echo 'Файл логов не найден'"
            else:
                # По умолчанию access логи
                command = f"tail -n {lines} /var/log/xray/access.log 2>/dev/null || echo 'Файл логов не найден'"
            
            result = self.ssh_manager.execute_command(
                ssh_config['host'],
                command,
                ssh_config['port'],
                ssh_config['username'],
                ssh_config['key_path'],
                ssh_config['key_content'],
                ssh_config.get('password')
            )
            
            if result['success']:
                log_lines = result['stdout'].strip().split('\n') if result['stdout'].strip() else []
                return {
                    'success': True,
                    'log_type': log_type,
                    'server_id': server.id,
                    'lines_count': len(log_lines),
                    'logs': log_lines,
                    'raw_output': result['stdout']
                }
            else:
                return {
                    'success': False,
                    'error': result.get('stderr', 'Неизвестная ошибка'),
                    'logs': []
                }
        except Exception as e:
            logger.error(f"Ошибка получения логов XRay с сервера {server.id}: {e}", exc_info=True)
            return {
                'success': False,
                'error': str(e),
                'logs': []
            }
    
    def get_wireguard_logs(
        self, 
        server: Server, 
        lines: int = 100,
        interface: str = "wg0"
    ) -> Dict[str, Any]:
        """
        Получает логи WireGuard с сервера
        
        Args:
            server: Сервер
            lines: Количество строк для получения
            interface: Имя интерфейса WireGuard (по умолчанию wg0)
        
        Returns:
            Словарь с логами и метаданными
        """
        if not self.ssh_manager:
            logger.warning(f"SSHManager недоступен для получения логов сервера {server.id}")
            return {
                'success': False,
                'error': 'SSH недоступен',
                'logs': []
            }
        
        ssh_config = self.get_ssh_config(server)
        
        try:
            # Получаем логи через systemd journal
            command = f"journalctl -u wg-quick@{interface} -n {lines} --no-pager 2>/dev/null || journalctl -u wireguard -n {lines} --no-pager 2>/dev/null || echo 'Логи WireGuard не найдены'"
            
            result = self.ssh_manager.execute_command(
                ssh_config['host'],
                command,
                ssh_config['port'],
                ssh_config['username'],
                ssh_config['key_path'],
                ssh_config['key_content'],
                ssh_config.get('password')
            )
            
            if result['success']:
                log_lines = result['stdout'].strip().split('\n') if result['stdout'].strip() else []
                return {
                    'success': True,
                    'log_type': 'wireguard',
                    'server_id': server.id,
                    'interface': interface,
                    'lines_count': len(log_lines),
                    'logs': log_lines,
                    'raw_output': result['stdout']
                }
            else:
                return {
                    'success': False,
                    'error': result.get('stderr', 'Неизвестная ошибка'),
                    'logs': []
                }
        except Exception as e:
            logger.error(f"Ошибка получения логов WireGuard с сервера {server.id}: {e}", exc_info=True)
            return {
                'success': False,
                'error': str(e),
                'logs': []
            }
    
    def _create_base_xray_config(self, server: Server) -> Dict[str, Any]:
        """Создает базовую конфигурацию Xray"""
        return {
            "log": {
                "loglevel": "warning",
                "access": "/var/log/xray/access.log",
                "error": "/var/log/xray/error.log"
            },
            "inbounds": [
                {
                    "port": 443,
                    "protocol": "vless",
                    "settings": {
                        "clients": [],
                        "decryption": "none"
                    },
                    "streamSettings": {
                        "network": "ws",
                        "wsSettings": {
                            "path": "/ray"
                        },
                        "security": "tls",
                        "tlsSettings": {
                            "certificates": [
                                {
                                    "certificateFile": "/etc/ssl/certs/cert.pem",
                                    "keyFile": "/etc/ssl/private/key.pem"
                                }
                            ]
                        }
                    }
                },
                {
                    "port": 8080,
                    "protocol": "vmess",
                    "settings": {
                        "clients": []
                    },
                    "streamSettings": {
                        "network": "ws",
                        "wsSettings": {
                            "path": "/vmess"
                        },
                        "security": "tls"
                    }
                }
            ],
            "outbounds": [
                {
                    "protocol": "freedom",
                    "settings": {}
                }
            ]
        }
    
    # ========== Общие методы ==========
    
    def test_connection(self, server: Server) -> bool:
        """Тестирует SSH подключение к серверу"""
        ssh_config = self.get_ssh_config(server)
        return self.ssh_manager.test_connection(
            ssh_config['host'],
            ssh_config['port'],
            ssh_config['username'],
            ssh_config.get('password'),
            ssh_config['key_path'],
            ssh_config['key_content']
        )
