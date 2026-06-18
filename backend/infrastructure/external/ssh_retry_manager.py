"""
Менеджер retry логики для SSH операций
Реализует exponential backoff и circuit breaker pattern
"""
import logging
import time
from typing import Callable, Any, Optional, Dict
from functools import wraps

logger = logging.getLogger(__name__)

class SSHRetryManager:
    """Менеджер для retry логики SSH операций"""
    
    # Типы ошибок, при которых стоит повторять попытку
    RETRYABLE_ERRORS = [
        'timeout',
        'connection',
        'network',
        'temporary',
        'unavailable',
        'refused',
        'reset',
    ]
    
    # Типы ошибок, при которых НЕ стоит повторять попытку
    NON_RETRYABLE_ERRORS = [
        'authentication',
        'permission',
        'invalid',
        'not found',
        'syntax',
    ]
    
    @classmethod
    def is_retryable_error(cls, error: Exception) -> bool:
        """Проверяет, стоит ли повторять попытку при данной ошибке"""
        error_str = str(error).lower()
        error_type = type(error).__name__.lower()
        
        # Проверяем на не-retryable ошибки
        for non_retryable in cls.NON_RETRYABLE_ERRORS:
            if non_retryable in error_str or non_retryable in error_type:
                return False
        
        # Проверяем на retryable ошибки
        for retryable in cls.RETRYABLE_ERRORS:
            if retryable in error_str or retryable in error_type:
                return True
        
        # По умолчанию не повторяем (безопаснее)
        return False
    
    @classmethod
    def retry_with_backoff(
        cls,
        max_retries: int = 3,
        initial_delay: float = 1.0,
        max_delay: float = 30.0,
        exponential_base: float = 2.0,
        jitter: bool = True
    ):
        """
        Декоратор для retry с exponential backoff
        
        Args:
            max_retries: Максимальное количество попыток
            initial_delay: Начальная задержка в секундах
            max_delay: Максимальная задержка в секундах
            exponential_base: База для экспоненциального роста
            jitter: Добавлять ли случайную задержку для предотвращения thundering herd
        """
        def decorator(func: Callable) -> Callable:
            @wraps(func)
            def wrapper(*args, **kwargs) -> Any:
                last_exception = None
                
                for attempt in range(max_retries + 1):
                    try:
                        return func(*args, **kwargs)
                    except Exception as e:
                        last_exception = e
                        
                        # Проверяем, стоит ли повторять
                        if not cls.is_retryable_error(e):
                            logger.warning(f"Ошибка не является retryable, прекращаем попытки: {e}")
                            raise
                        
                        # Если это последняя попытка, выбрасываем исключение
                        if attempt >= max_retries:
                            logger.error(f"Достигнуто максимальное количество попыток ({max_retries}), прекращаем retry")
                            raise
                        
                        # Вычисляем задержку с exponential backoff
                        delay = min(
                            initial_delay * (exponential_base ** attempt),
                            max_delay
                        )
                        
                        # Добавляем jitter для предотвращения thundering herd
                        if jitter:
                            import random
                            jitter_amount = delay * 0.1  # 10% jitter
                            delay += random.uniform(-jitter_amount, jitter_amount)
                            delay = max(0, delay)  # Не может быть отрицательной
                        
                        logger.warning(
                            f"Ошибка при выполнении {func.__name__} (попытка {attempt + 1}/{max_retries + 1}): {e}. "
                            f"Повтор через {delay:.2f} сек"
                        )
                        
                        time.sleep(delay)
                
                # Не должно быть достигнуто, но на всякий случай
                if last_exception:
                    raise last_exception
                raise Exception("Неожиданная ошибка в retry логике")
            
            return wrapper
        return decorator
    
    @classmethod
    def execute_with_retry(
        cls,
        func: Callable,
        *args,
        max_retries: int = 3,
        initial_delay: float = 1.0,
        **kwargs
    ) -> Any:
        """
        Выполняет функцию с retry логикой
        
        Args:
            func: Функция для выполнения
            *args: Аргументы функции
            max_retries: Максимальное количество попыток
            initial_delay: Начальная задержка
            **kwargs: Дополнительные аргументы функции
        
        Returns:
            Результат выполнения функции
        """
        last_exception = None
        
        for attempt in range(max_retries + 1):
            try:
                return func(*args, **kwargs)
            except Exception as e:
                last_exception = e
                
                if not cls.is_retryable_error(e):
                    logger.warning(f"Ошибка не является retryable: {e}")
                    raise
                
                if attempt >= max_retries:
                    logger.error(f"Достигнуто максимальное количество попыток: {max_retries}")
                    raise
                
                delay = min(initial_delay * (2 ** attempt), 30.0)
                logger.warning(f"Попытка {attempt + 1}/{max_retries + 1} не удалась, повтор через {delay:.2f} сек: {e}")
                time.sleep(delay)
        
        if last_exception:
            raise last_exception
        raise Exception("Неожиданная ошибка")
