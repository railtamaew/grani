"""
Централизованная обработка ошибок для VPN сервиса
"""
import logging
from typing import Dict, Any, Optional
from fastapi import HTTPException, status
from sqlalchemy.exc import SQLAlchemyError

logger = logging.getLogger(__name__)

class VPNErrorHandler:
    """Централизованный обработчик ошибок VPN операций"""
    
    # Маппинг типов ошибок на HTTP статусы
    ERROR_STATUS_MAP = {
        'validation': status.HTTP_400_BAD_REQUEST,
        'authentication': status.HTTP_401_UNAUTHORIZED,
        'authorization': status.HTTP_403_FORBIDDEN,
        'not_found': status.HTTP_404_NOT_FOUND,
        'conflict': status.HTTP_409_CONFLICT,
        'server_error': status.HTTP_500_INTERNAL_SERVER_ERROR,
        'service_unavailable': status.HTTP_503_SERVICE_UNAVAILABLE,
    }
    
    @classmethod
    def handle_ssh_error(cls, error: Exception, context: str = "") -> HTTPException:
        """
        Обрабатывает ошибки SSH операций
        
        Args:
            error: Исключение
            context: Контекст операции
        
        Returns:
            HTTPException с соответствующим статусом
        """
        error_msg = str(error).lower()
        error_type = type(error).__name__
        
        # Определяем тип ошибки
        if 'authentication' in error_msg or 'auth' in error_msg or 'permission' in error_msg:
            logger.error(f"Ошибка аутентификации SSH {context}: {error}")
            return HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail=f"Ошибка аутентификации SSH: {str(error)}"
            )
        elif 'timeout' in error_msg or 'connection' in error_msg:
            logger.error(f"Ошибка подключения SSH {context}: {error}")
            return HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail=f"Сервер VPN недоступен. Попробуйте позже."
            )
        elif 'paramiko' in error_msg or 'ssh' in error_msg.lower():
            logger.error(f"Ошибка SSH {context}: {error}")
            return HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Сервер управления VPN недоступен. Обратитесь к администратору."
            )
        else:
            logger.error(f"Неизвестная ошибка SSH {context}: {error}", exc_info=True)
            return HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"Ошибка настройки VPN сервера: {str(error)}"
            )
    
    @classmethod
    def handle_validation_error(cls, error: Exception, context: str = "") -> HTTPException:
        """
        Обрабатывает ошибки валидации
        
        Args:
            error: Исключение
            context: Контекст операции
        
        Returns:
            HTTPException с соответствующим статусом
        """
        error_msg = str(error)
        logger.warning(f"Ошибка валидации {context}: {error_msg}")
        
        return HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Ошибка валидации: {error_msg}"
        )
    
    @classmethod
    def handle_database_error(cls, error: Exception, context: str = "") -> HTTPException:
        """
        Обрабатывает ошибки базы данных
        
        Args:
            error: Исключение
            context: Контекст операции
        
        Returns:
            HTTPException с соответствующим статусом
        """
        error_msg = str(error).lower()
        logger.error(f"Ошибка базы данных {context}: {error}", exc_info=True)
        
        if isinstance(error, SQLAlchemyError):
            if 'unique' in error_msg or 'duplicate' in error_msg:
                return HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Запись уже существует"
                )
            elif 'foreign key' in error_msg or 'constraint' in error_msg:
                return HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="Нарушение ограничений базы данных"
                )
        
        return HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Ошибка базы данных. Обратитесь к администратору."
        )
    
    @classmethod
    def handle_configuration_error(cls, error: Exception, context: str = "") -> HTTPException:
        """
        Обрабатывает ошибки конфигурации VPN
        
        Args:
            error: Исключение
            context: Контекст операции
        
        Returns:
            HTTPException с соответствующим статусом
        """
        error_msg = str(error)
        logger.error(f"Ошибка конфигурации VPN {context}: {error_msg}", exc_info=True)
        
        return HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Ошибка конфигурации VPN: {error_msg}"
        )
    
    @classmethod
    def handle_generic_error(cls, error: Exception, context: str = "") -> HTTPException:
        """
        Обрабатывает общие ошибки
        
        Args:
            error: Исключение
            context: Контекст операции
        
        Returns:
            HTTPException с соответствующим статусом
        """
        error_msg = str(error)
        error_type = type(error).__name__
        
        logger.error(f"Неожиданная ошибка {context}: {error_type}: {error_msg}", exc_info=True)
        
        # Не раскрываем детали ошибки пользователю в production
        from core.config import settings
        if settings.is_production:
            detail = "Произошла внутренняя ошибка. Обратитесь к администратору."
        else:
            detail = f"Ошибка: {error_msg}"
        
        return HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=detail
        )
    
    @classmethod
    def handle_error(cls, error: Exception, context: str = "", error_type: Optional[str] = None) -> HTTPException:
        """
        Универсальный обработчик ошибок
        
        Args:
            error: Исключение
            context: Контекст операции
            error_type: Тип ошибки (ssh, validation, database, configuration, generic)
        
        Returns:
            HTTPException с соответствующим статусом
        """
        # Если тип ошибки указан явно, используем соответствующий обработчик
        if error_type:
            handlers = {
                'ssh': cls.handle_ssh_error,
                'validation': cls.handle_validation_error,
                'database': cls.handle_database_error,
                'configuration': cls.handle_configuration_error,
            }
            handler = handlers.get(error_type, cls.handle_generic_error)
            return handler(error, context)
        
        # Автоматическое определение типа ошибки
        error_msg = str(error).lower()
        error_type_name = type(error).__name__
        
        if isinstance(error, HTTPException):
            return error
        
        if isinstance(error, ValueError):
            return cls.handle_validation_error(error, context)
        
        if isinstance(error, SQLAlchemyError):
            return cls.handle_database_error(error, context)
        
        if 'ssh' in error_msg or 'paramiko' in error_msg:
            return cls.handle_ssh_error(error, context)
        
        if 'validation' in error_msg or 'invalid' in error_msg:
            return cls.handle_validation_error(error, context)
        
        if 'config' in error_msg or 'configuration' in error_msg:
            return cls.handle_configuration_error(error, context)
        
        return cls.handle_generic_error(error, context)
