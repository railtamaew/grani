"""
Обратная совместимость: реэкспорт сервисов из новой структуры
"""
# Application services (бизнес-логика)
from application.services.auth_service import AuthService
# CodeService не экспортируется (используется внутри)
from application.services.device_manager import DeviceManager
from application.services.vpn_operations_service import VPNOperationsService
from application.services.health_service import HealthService
from application.services.server_selector import ServerSelector
from application.services.server_load_calculator import ServerLoadCalculator
from application.services.protocol_analyzer import ProtocolAnalyzer
from application.services.provider_monitor import ProviderMonitor
# TrialService не экспортируется (используется внутри)
from application.services.telemetry_service import TelemetryService
from application.services.app_config_service import AppConfigService
from application.services.admin_auth_service import AdminAuthService

# Infrastructure services (внешние зависимости)
from infrastructure.external.wireguard_manager import WireGuardManager
from infrastructure.external.xray_manager import XrayManager
from infrastructure.external.openvpn_manager import OpenVPNManager
from infrastructure.external.cloak_manager import CloakManager
from infrastructure.external.ssh_manager import SSHManager
from infrastructure.external.remote_vpn_manager import RemoteVPNManager
# EmailService - не экспортируется (используется внутри)

__all__ = [
    # Application services
    'AuthService',
    # CodeService - не экспортируется
    'DeviceManager',
    'VPNOperationsService',
    'HealthService',
    'ServerSelector',
    'ServerLoadCalculator',
    'ProtocolAnalyzer',
    'ProviderMonitor',
    # TrialService - функции, не класс
    'TelemetryService',
    'AppConfigService',
    'AdminAuthService',
    # Infrastructure services
    'WireGuardManager',
    'XrayManager',
    'OpenVPNManager',
    'CloakManager',
    'SSHManager',
    'RemoteVPNManager',
    # EmailService - не экспортируется
]
