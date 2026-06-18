"""
Обратная совместимость: реэкспорт моделей из domain/models
"""
# Реэкспортируем все модели из domain для обратной совместимости
from domain.models.user import User, Device, UserRole
from domain.models.server import Server, ConnectionLog
from domain.models.subscription import Subscription, Plan
from domain.models.payment import Payment
from domain.models.auth_code import AuthCode
from domain.models.protocol_stats import ProtocolStats
from domain.models.protocol import Protocol
from domain.models.telemetry import TelemetryEvent
from domain.models.audit_log import AuditLog
from domain.models.admin_login_log import AdminLoginLog
from domain.models.client_log import ClientLog
from domain.models.user_vpn_connection import UserVpnConnection
from domain.models.observability import (
    ObservabilityEvent,
    ObservabilityIncident,
    ObservabilityIncidentComment,
    EventDictionary,
)

__all__ = [
    'User', 'Device', 'UserRole',
    'Server', 'ConnectionLog',
    'Subscription', 'Plan',
    'Payment',
    'AuthCode',
    'ProtocolStats',
    'Protocol',
    'TelemetryEvent',
    'AuditLog',
    'AdminLoginLog',
    'ClientLog',
    'UserVpnConnection',
    'ObservabilityEvent',
    'ObservabilityIncident',
    'ObservabilityIncidentComment',
    'EventDictionary',
]
