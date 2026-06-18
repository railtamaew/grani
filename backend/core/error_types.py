"""
Типы ошибок для централизованной обработки.
Определяет стандартные коды и типы ошибок приложения.
"""
from enum import Enum
from typing import Optional, List, Dict, Any, Union
from dataclasses import dataclass


class ErrorCode(str, Enum):
    """Коды ошибок приложения"""
    
    # HTTP ошибки
    HTTP_BAD_REQUEST = "BAD_REQUEST"
    HTTP_UNAUTHORIZED = "UNAUTHORIZED"
    HTTP_FORBIDDEN = "FORBIDDEN"
    HTTP_NOT_FOUND = "NOT_FOUND"
    HTTP_CONFLICT = "CONFLICT"
    HTTP_UNPROCESSABLE_ENTITY = "UNPROCESSABLE_ENTITY"
    HTTP_INTERNAL_SERVER_ERROR = "INTERNAL_SERVER_ERROR"
    
    # Валидация
    VALIDATION_ERROR = "VALIDATION_ERROR"
    INVALID_INPUT = "INVALID_INPUT"
    
    # Аутентификация и авторизация
    AUTH_REQUIRED = "AUTH_REQUIRED"
    AUTH_FAILED = "AUTH_FAILED"
    TOKEN_EXPIRED = "TOKEN_EXPIRED"
    TOKEN_INVALID = "TOKEN_INVALID"
    INVALID_CREDENTIALS = "INVALID_CREDENTIALS"
    MAX_ATTEMPTS_EXCEEDED = "MAX_ATTEMPTS_EXCEEDED"
    
    # Устройства
    DEVICE_NOT_FOUND = "DEVICE_NOT_FOUND"
    DEVICE_LIMIT_EXCEEDED = "DEVICE_LIMIT_EXCEEDED"
    DEVICE_ALREADY_REGISTERED = "DEVICE_ALREADY_REGISTERED"
    
    # Серверы
    SERVER_NOT_FOUND = "SERVER_NOT_FOUND"
    SERVER_NOT_ACTIVE = "SERVER_NOT_ACTIVE"
    SERVER_OVERLOADED = "SERVER_OVERLOADED"
    PROTOCOL_NOT_SUPPORTED = "PROTOCOL_NOT_SUPPORTED"
    
    # VPN подключения
    CONNECTION_FAILED = "CONNECTION_FAILED"
    DISCONNECTION_FAILED = "DISCONNECTION_FAILED"
    CONNECTION_TIMEOUT = "CONNECTION_TIMEOUT"
    VPN_CLIENT_NOT_FOUND = "VPN_CLIENT_NOT_FOUND"
    
    # База данных
    DATABASE_ERROR = "DATABASE_ERROR"
    DATABASE_CONNECTION_ERROR = "DATABASE_CONNECTION_ERROR"
    
    # Внешние сервисы
    EMAIL_SERVICE_ERROR = "EMAIL_SERVICE_ERROR"
    SSH_SERVICE_ERROR = "SSH_SERVICE_ERROR"
    XRAY_SERVICE_ERROR = "XRAY_SERVICE_ERROR"
    
    # Общие ошибки
    INTERNAL_ERROR = "INTERNAL_ERROR"
    SERVICE_UNAVAILABLE = "SERVICE_UNAVAILABLE"
    RATE_LIMIT_EXCEEDED = "RATE_LIMIT_EXCEEDED"


@dataclass
class ErrorDetail:
    """Детали ошибки валидации"""
    field: str
    message: str
    type: str
    value: Optional[Any] = None


@dataclass
class AppError:
    """Стандартная структура ошибки приложения"""
    code: ErrorCode
    message: str
    details: Optional[Union[List[ErrorDetail], Dict[str, Any]]] = None
    path: Optional[str] = None
    method: Optional[str] = None
    timestamp: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Преобразует ошибку в словарь для JSON ответа"""
        result = {
            "code": self.code.value,
            "message": self.message
        }
        
        if self.details:
            if isinstance(self.details, dict):
                result["details"] = self.details
            else:
                result["details"] = [
                    {
                        "field": detail.field,
                        "message": detail.message,
                        "type": detail.type,
                        **({"value": detail.value} if detail.value is not None else {})
                    }
                    for detail in self.details
                ]
        
        if self.path:
            result["path"] = self.path
        if self.method:
            result["method"] = self.method
        if self.timestamp:
            result["timestamp"] = self.timestamp
        
        return result


class AppException(Exception):
    """Базовое исключение приложения с кодом ошибки"""
    
    def __init__(
        self,
        code: ErrorCode,
        message: str,
        details: Optional[Union[List[ErrorDetail], Dict[str, Any]]] = None,
        status_code: int = 400
    ):
        self.code = code
        self.message = message
        self.details = details or []
        self.status_code = status_code
        super().__init__(self.message)
    
    def to_app_error(self, path: Optional[str] = None, method: Optional[str] = None) -> AppError:
        """Преобразует исключение в AppError"""
        from datetime import datetime
        return AppError(
            code=self.code,
            message=self.message,
            details=self.details,
            path=path,
            method=method,
            timestamp=datetime.now().isoformat()
        )


# Специализированные исключения
class ValidationError(AppException):
    """Ошибка валидации"""
    def __init__(self, message: str, details: Optional[List[ErrorDetail]] = None):
        super().__init__(
            code=ErrorCode.VALIDATION_ERROR,
            message=message,
            details=details,
            status_code=422
        )


class AuthenticationError(AppException):
    """Ошибка аутентификации"""
    def __init__(self, message: str = "Ошибка аутентификации"):
        super().__init__(
            code=ErrorCode.AUTH_FAILED,
            message=message,
            status_code=401
        )


class AuthorizationError(AppException):
    """Ошибка авторизации"""
    def __init__(self, message: str = "Доступ запрещен"):
        super().__init__(
            code=ErrorCode.HTTP_FORBIDDEN,
            message=message,
            status_code=403
        )


class DeviceNotFoundError(AppException):
    """Устройство не найдено"""
    def __init__(self, device_id: Optional[str] = None):
        message = f"Устройство не найдено"
        if device_id:
            message += f": {device_id}"
        super().__init__(
            code=ErrorCode.DEVICE_NOT_FOUND,
            message=message,
            status_code=404
        )


class ServerNotFoundError(AppException):
    """Сервер не найден"""
    def __init__(self, server_id: Optional[int] = None):
        message = "Сервер не найден или неактивен"
        if server_id:
            message += f": server_id={server_id}"
        super().__init__(
            code=ErrorCode.SERVER_NOT_FOUND,
            message=message,
            status_code=404
        )


class ProtocolNotSupportedError(AppException):
    """Протокол не поддерживается"""
    def __init__(self, protocol: str, supported_protocols: Optional[List[str]] = None):
        message = f"Сервер не поддерживает протокол: {protocol}"
        if supported_protocols:
            message += f". Доступные протоколы: {', '.join(supported_protocols)}"
        super().__init__(
            code=ErrorCode.PROTOCOL_NOT_SUPPORTED,
            message=message,
            status_code=400
        )


class DatabaseError(AppException):
    """Ошибка базы данных"""
    def __init__(self, message: str = "Ошибка базы данных"):
        super().__init__(
            code=ErrorCode.DATABASE_ERROR,
            message=message,
            status_code=500
        )
