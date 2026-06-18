"""
Валидатор для безопасного выполнения SSH команд
Предотвращает инъекцию команд и валидирует входные данные
"""
import re
import ipaddress
import logging
from typing import Optional, List
from pathlib import Path

logger = logging.getLogger(__name__)

class SSHCommandValidator:
    """Валидатор для SSH команд и параметров"""
    
    # Whitelist разрешенных символов для различных типов данных
    SAFE_CHARS_PATTERN = re.compile(r'^[a-zA-Z0-9_\-\./]+$')
    IP_ADDRESS_PATTERN = re.compile(r'^(\d{1,3}\.){3}\d{1,3}$')
    PORT_PATTERN = re.compile(r'^\d{1,5}$')
    KEY_PATTERN = re.compile(r'^[A-Za-z0-9+/=]+$')  # Base64 ключи
    
    # Разрешенные команды (whitelist)
    ALLOWED_COMMANDS = {
        'wg': ['genkey', 'pubkey', 'show'],
        'systemctl': ['start', 'stop', 'restart', 'reload', 'status', 'is-active', 'enable'],
        'ip': ['addr', 'link'],
        'iptables': ['-L', '-C', '-A', '-D', '-t', 'nat'],
        'sysctl': ['net.ipv4.ip_forward'],
        'chmod': ['644', '600', '755'],
        'mkdir': ['-p'],
        'cat': [],
        'echo': [],
        'xray': ['x25519', 'version'],
        'which': [],
        'test': ['-f'],
        'ss': ['-tlnp'],
        'netstat': ['-tlnp'],
        'curl': ['-s'],
    }
    
    # Запрещенные символы для инъекции команд
    DANGEROUS_CHARS = [';', '&', '|', '`', '$', '(', ')', '<', '>', '\n', '\r']
    
    @classmethod
    def validate_ip_address(cls, ip: str) -> bool:
        """Валидирует IP адрес"""
        try:
            ipaddress.ip_address(ip)
            return True
        except ValueError:
            return False
    
    @classmethod
    def validate_port(cls, port: int) -> bool:
        """Валидирует порт"""
        return 1 <= port <= 65535
    
    @classmethod
    def validate_path(cls, path: str, must_exist: bool = False) -> bool:
        """Валидирует путь к файлу"""
        if not path:
            return False
        
        # Проверяем на опасные символы
        if any(char in path for char in cls.DANGEROUS_CHARS):
            return False
        
        # Проверяем на path traversal
        if '..' in path:
            return False
        
        # Проверяем формат пути
        try:
            path_obj = Path(path)
            # Разрешаем только абсолютные пути для безопасности
            if not path_obj.is_absolute():
                return False
            
            # Проверяем существование если требуется
            if must_exist:
                return path_obj.exists()
            
            return True
        except Exception:
            return False
    
    @classmethod
    def validate_key(cls, key: str) -> bool:
        """Валидирует ключ (WireGuard, SSH и т.д.)"""
        if not key:
            return False
        
        # Проверяем на опасные символы
        if any(char in key for char in cls.DANGEROUS_CHARS):
            return False
        
        # Проверяем формат (Base64 для WireGuard)
        if not cls.KEY_PATTERN.match(key.strip()):
            return False
        
        # Проверяем длину (WireGuard ключи обычно 44 символа)
        if len(key.strip()) < 20 or len(key.strip()) > 200:
            return False
        
        return True
    
    @classmethod
    def validate_command_string(cls, command: str) -> bool:
        """Валидирует строку команды на наличие инъекций"""
        if not command:
            return False
        
        # Проверяем на опасные символы
        if any(char in command for char in cls.DANGEROUS_CHARS):
            logger.warning(f"Обнаружены опасные символы в команде: {command[:50]}")
            return False
        
        # Проверяем на множественные команды
        if '&&' in command or '||' in command:
            logger.warning(f"Обнаружены множественные команды: {command[:50]}")
            return False
        
        return True
    
    @classmethod
    def sanitize_string(cls, value: str, max_length: int = 1000) -> Optional[str]:
        """Санитизирует строку, удаляя опасные символы"""
        if not value:
            return None
        
        # Ограничиваем длину
        if len(value) > max_length:
            logger.warning(f"Строка превышает максимальную длину: {len(value)} > {max_length}")
            return None
        
        # Удаляем опасные символы
        sanitized = value
        for char in cls.DANGEROUS_CHARS:
            sanitized = sanitized.replace(char, '')
        
        return sanitized
    
    @classmethod
    def build_safe_command(cls, base_command: str, *args) -> Optional[str]:
        """Строит безопасную команду с валидированными аргументами"""
        if not cls.validate_command_string(base_command):
            logger.error(f"Небезопасная базовая команда: {base_command}")
            return None
        
        # Извлекаем команду и проверяем whitelist
        parts = base_command.split()
        if not parts:
            return None
        
        cmd_name = parts[0]
        
        # Проверяем, разрешена ли команда
        if cmd_name not in cls.ALLOWED_COMMANDS:
            logger.warning(f"Команда не в whitelist: {cmd_name}")
            return None
        
        # Валидируем аргументы
        safe_args = []
        for arg in args:
            sanitized = cls.sanitize_string(str(arg))
            if sanitized is None:
                logger.warning(f"Не удалось санитизировать аргумент: {arg[:50]}")
                return None
            safe_args.append(sanitized)
        
        # Собираем команду
        if safe_args:
            # Используем shlex.quote для безопасного экранирования
            import shlex
            quoted_args = [shlex.quote(arg) for arg in safe_args]
            return f"{base_command} {' '.join(quoted_args)}"
        
        return base_command
    
    @classmethod
    def validate_wireguard_key_generation(cls) -> bool:
        """Проверяет, что команда генерации ключа безопасна"""
        # Команда 'wg genkey' не принимает аргументов, безопасна
        return True
    
    @classmethod
    def validate_wireguard_pubkey_command(cls, private_key: str) -> bool:
        """Валидирует команду генерации публичного ключа"""
        if not cls.validate_key(private_key):
            return False
        
        # Команда должна быть безопасной
        # Используем безопасный способ передачи ключа
        return True
