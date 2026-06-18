"""
Обратная совместимость: реэкспорт из domain.models.user
"""
from domain.models.user import User, Device, UserRole

__all__ = ['User', 'Device', 'UserRole']
