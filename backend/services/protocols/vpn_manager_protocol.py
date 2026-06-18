"""
Протокол (интерфейс) для VPN менеджеров.

Этот модуль определяет протокол, которому должны следовать все VPN менеджеры
(WireGuard, Xray, OpenVPN и т.д.) для единообразной работы с ними.
"""
from typing import Protocol, Dict, Any, Optional
from models.user import Device
from models.server import Server


class VPNManagerProtocol(Protocol):
    """
    Протокол для VPN менеджеров.
    
    Все VPN менеджеры (WireGuardManager, XrayManager, OpenVPNManager и т.д.)
    должны реализовывать методы этого протокола для единообразной работы.
    """
    
    def connect_device(
        self, 
        device: Device, 
        server: Server,
        **kwargs: Any
    ) -> Dict[str, Any]:
        """
        Подключение устройства к VPN серверу.
        
        Args:
            device: Устройство для подключения
            server: VPN сервер
            **kwargs: Дополнительные параметры (протокол, IP адрес и т.д.)
        
        Returns:
            Словарь с результатом подключения:
            - success: bool - успешность подключения
            - config: str - конфигурация для клиента
            - ip_address: str - назначенный IP адрес
            - client_id: Optional[str] - ID клиента (для Xray)
            - server_info: Dict - информация о сервере
        
        Raises:
            Exception: Если подключение не удалось
        """
        ...
    
    def disconnect_device(
        self, 
        device: Device, 
        server: Server
    ) -> bool:
        """
        Отключение устройства от VPN сервера.
        
        Args:
            device: Устройство для отключения
            server: VPN сервер
        
        Returns:
            True если отключение успешно, False иначе
        
        Raises:
            Exception: Если отключение не удалось
        """
        ...
    
    def get_device_status(
        self, 
        device: Device, 
        server: Server
    ) -> Dict[str, Any]:
        """
        Получение статуса подключения устройства.
        
        Args:
            device: Устройство
            server: VPN сервер
        
        Returns:
            Словарь со статусом:
            - connected: bool - подключено ли устройство
            - ip_address: Optional[str] - IP адрес устройства
            - stats: Optional[Dict] - статистика подключения
            - error: Optional[str] - ошибка если есть
        """
        ...
    
    def get_client_config(
        self,
        device: Device,
        server: Server,
        **kwargs: Any
    ) -> str:
        """
        Получение конфигурации клиента для устройства.
        
        Args:
            device: Устройство
            server: VPN сервер
            **kwargs: Дополнительные параметры
        
        Returns:
            Строка с конфигурацией клиента
        """
        ...


# Тип для проверки соответствия протоколу
VPNManager = VPNManagerProtocol
