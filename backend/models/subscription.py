"""
Обратная совместимость: реэкспорт из domain.models.subscription
"""
from domain.models.subscription import Subscription, Plan

__all__ = ['Subscription', 'Plan']
