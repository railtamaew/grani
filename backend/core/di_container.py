"""
Dependency Injection Container
Простой DI контейнер для управления зависимостями приложения
"""
from typing import Dict, Type, Callable, Any, Optional
from functools import lru_cache
import logging

logger = logging.getLogger(__name__)

class DIContainer:
    """Контейнер для управления зависимостями"""
    
    def __init__(self):
        self._singletons: Dict[Type, Any] = {}
        self._factories: Dict[Type, Callable] = {}
        self._transients: Dict[Type, Callable] = {}
    
    def register_singleton(self, interface: Type, implementation: Any):
        """Регистрация singleton (один экземпляр на все приложение)"""
        self._singletons[interface] = implementation
        logger.debug(f"Зарегистрирован singleton: {interface.__name__}")
    
    def register_factory(self, interface: Type, factory: Callable):
        """Регистрация factory (создает новый экземпляр при каждом запросе)"""
        self._factories[interface] = factory
        logger.debug(f"Зарегистрирована factory: {interface.__name__}")
    
    def register_transient(self, interface: Type, factory: Callable):
        """Регистрация transient (аналогично factory)"""
        self._transients[interface] = factory
        logger.debug(f"Зарегистрирован transient: {interface.__name__}")
    
    def get(self, interface: Type) -> Any:
        """Получить экземпляр зависимости"""
        # Проверяем singleton
        if interface in self._singletons:
            return self._singletons[interface]
        
        # Проверяем factory
        if interface in self._factories:
            instance = self._factories[interface]()
            # Если это singleton, сохраняем
            if hasattr(instance, '__singleton__') and instance.__singleton__:
                self._singletons[interface] = instance
            return instance
        
        # Проверяем transient
        if interface in self._transients:
            return self._transients[interface]()
        
        raise ValueError(f"Зависимость {interface.__name__} не зарегистрирована")
    
    def get_or_none(self, interface: Type) -> Optional[Any]:
        """Получить экземпляр зависимости или None"""
        try:
            return self.get(interface)
        except ValueError:
            return None
    
    def is_registered(self, interface: Type) -> bool:
        """Проверить, зарегистрирована ли зависимость"""
        return (interface in self._singletons or 
                interface in self._factories or 
                interface in self._transients)
    
    def clear(self):
        """Очистить все зарегистрированные зависимости"""
        self._singletons.clear()
        self._factories.clear()
        self._transients.clear()
        logger.debug("DI контейнер очищен")

# Глобальный экземпляр контейнера
_container: Optional[DIContainer] = None

def get_container() -> DIContainer:
    """Получить глобальный DI контейнер"""
    global _container
    if _container is None:
        _container = DIContainer()
    return _container

def reset_container():
    """Сбросить глобальный контейнер (для тестов)"""
    global _container
    _container = None
