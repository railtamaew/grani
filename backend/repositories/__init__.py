"""
Обратная совместимость: реэкспорт репозиториев из infrastructure/repositories
"""
from infrastructure.repositories.base_repository import BaseRepository
from infrastructure.repositories.device_repository import DeviceRepository
from infrastructure.repositories.server_repository import ServerRepository
from infrastructure.repositories.user_repository import UserRepository

__all__ = [
    'BaseRepository',
    'DeviceRepository',
    'ServerRepository',
    'UserRepository',
]
