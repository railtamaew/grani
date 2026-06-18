"""
Утилиты для безопасного логирования.
Маскирует чувствительные данные (пароли, токены, ключи) в логах.
"""
import re
from typing import Any, Dict, List, Optional


# Паттерны для поиска чувствительных данных
SENSITIVE_PATTERNS = [
    r'password["\']?\s*[:=]\s*["\']?([^"\'\s]+)',
    r'password_hash["\']?\s*[:=]\s*["\']?([^"\'\s]+)',
    r'token["\']?\s*[:=]\s*["\']?([^"\'\s]+)',
    r'access_token["\']?\s*[:=]\s*["\']?([^"\'\s]+)',
    r'refresh_token["\']?\s*[:=]\s*["\']?([^"\'\s]+)',
    r'secret["\']?\s*[:=]\s*["\']?([^"\'\s]+)',
    r'secret_key["\']?\s*[:=]\s*["\']?([^"\'\s]+)',
    r'api_key["\']?\s*[:=]\s*["\']?([^"\'\s]+)',
    r'private_key["\']?\s*[:=]\s*["\']?([^"\'\s]+)',
    r'public_key["\']?\s*[:=]\s*["\']?([^"\'\s]+)',
    r'authorization["\']?\s*[:=]\s*["\']?([^"\'\s]+)',
    r'auth["\']?\s*[:=]\s*["\']?([^"\'\s]+)',
]

# Ключи словарей, которые могут содержать чувствительные данные
SENSITIVE_KEYS = [
    'password', 'password_hash', 'token', 'access_token', 'refresh_token',
    'secret', 'secret_key', 'api_key', 'private_key', 'public_key',
    'authorization', 'auth', 'code', 'verification_code', 'auth_code',
    'jwt', 'bearer', 'credentials', 'credential'
]


def mask_sensitive_string(value: str, mask_char: str = '*', visible_chars: int = 4) -> str:
    """
    Маскирует строку, оставляя видимыми только первые и последние символы.
    
    Args:
        value: Строка для маскирования
        mask_char: Символ для маскирования
        visible_chars: Количество видимых символов с начала и конца
    
    Returns:
        Замаскированная строка
    """
    if not value or len(value) <= visible_chars * 2:
        # Если строка слишком короткая, маскируем полностью
        return mask_char * len(value) if value else ""
    
    visible_start = value[:visible_chars]
    visible_end = value[-visible_chars:] if len(value) > visible_chars * 2 else ""
    masked_middle = mask_char * max(4, len(value) - visible_chars * 2)
    
    return f"{visible_start}{masked_middle}{visible_end}"


def mask_sensitive_dict(data: Dict[str, Any], mask_char: str = '*') -> Dict[str, Any]:
    """
    Маскирует чувствительные данные в словаре.
    
    Args:
        data: Словарь для обработки
        mask_char: Символ для маскирования
    
    Returns:
        Словарь с замаскированными чувствительными данными
    """
    if not isinstance(data, dict):
        return data
    
    masked_data = {}
    for key, value in data.items():
        key_lower = str(key).lower()
        
        # Проверяем, является ли ключ чувствительным
        is_sensitive = any(sensitive_key in key_lower for sensitive_key in SENSITIVE_KEYS)
        
        if is_sensitive and value:
            if isinstance(value, str):
                masked_data[key] = mask_sensitive_string(value, mask_char)
            elif isinstance(value, dict):
                masked_data[key] = mask_sensitive_dict(value, mask_char)
            elif isinstance(value, list):
                masked_data[key] = [mask_sensitive_string(str(v), mask_char) if isinstance(v, str) else v for v in value]
            else:
                masked_data[key] = mask_char * 8  # Маскируем полностью
        elif isinstance(value, dict):
            masked_data[key] = mask_sensitive_dict(value, mask_char)
        elif isinstance(value, list):
            masked_data[key] = [
                mask_sensitive_dict(v, mask_char) if isinstance(v, dict) else v
                for v in value
            ]
        else:
            masked_data[key] = value
    
    return masked_data


def mask_sensitive_text(text: str, mask_char: str = '*') -> str:
    """
    Маскирует чувствительные данные в тексте, используя регулярные выражения.
    
    Args:
        text: Текст для обработки
        mask_char: Символ для маскирования
    
    Returns:
        Текст с замаскированными чувствительными данными
    """
    if not text:
        return text
    
    masked_text = text
    
    # Применяем паттерны для поиска и маскирования
    for pattern in SENSITIVE_PATTERNS:
        def replace_match(match):
            full_match = match.group(0)
            sensitive_value = match.group(1) if match.lastindex else ""
            
            if sensitive_value:
                masked_value = mask_sensitive_string(sensitive_value, mask_char)
                # Заменяем значение в исходной строке
                return full_match.replace(sensitive_value, masked_value)
            return full_match
        
        masked_text = re.sub(pattern, replace_match, masked_text, flags=re.IGNORECASE)
    
    return masked_text


def safe_log_value(value: Any, mask_char: str = '*') -> Any:
    """
    Безопасно подготавливает значение для логирования.
    
    Args:
        value: Значение для логирования
        mask_char: Символ для маскирования
    
    Returns:
        Безопасное для логирования значение
    """
    if isinstance(value, dict):
        return mask_sensitive_dict(value, mask_char)
    elif isinstance(value, str):
        return mask_sensitive_text(value, mask_char)
    elif isinstance(value, list):
        return [
            safe_log_value(item, mask_char) if isinstance(item, (dict, str)) else item
            for item in value
        ]
    else:
        return value


def format_safe_log_message(message: str, **kwargs) -> str:
    """
    Форматирует сообщение для логирования, маскируя чувствительные данные.
    
    Args:
        message: Шаблон сообщения
        **kwargs: Аргументы для форматирования
    
    Returns:
        Безопасное сообщение для логирования
    """
    safe_kwargs = {k: safe_log_value(v) for k, v in kwargs.items()}
    return message.format(**safe_kwargs)
