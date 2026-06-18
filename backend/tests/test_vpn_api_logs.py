"""
Unit-тесты для API endpoint получения логов с VPN серверов.
Проверяют работу GET /api/vpn/server/{server_id}/logs

Примечание: Основная функциональность покрыта тестами в test_remote_vpn_manager_logs.py.
Эти тесты проверяют только базовую структуру API.
"""
import pytest
from sqlalchemy.orm import Session

from domain.models.server import Server


@pytest.fixture
def test_server(db_session: Session):
    """Создает тестовый сервер"""
    server = Server(
        name="Test VPN Server",
        ip_address="45.12.132.94",
        country="HU",
        city="Budapest",
        is_active=True,
        xray_config_path="/usr/local/etc/xray/config.json",
        ssh_host="45.12.132.94",
        ssh_port=22,
        ssh_user="root",
        supported_protocols=["wireguard", "xray_vless", "xray_vmess", "xray_reality"]
    )
    db_session.add(server)
    db_session.commit()
    db_session.refresh(server)
    return server


class TestGetServerLogsAPI:
    """Тесты для API endpoint получения логов
    
    Примечание: Полные тесты API требуют настройки FastAPI приложения и авторизации.
    Основная функциональность уже покрыта тестами RemoteVPNManager в test_remote_vpn_manager_logs.py.
    """
    
    def test_endpoint_exists(self):
        """Проверяем, что endpoint определен в API"""
        try:
            from api import vpn
            assert hasattr(vpn, 'router')
            
            # Проверяем, что есть метод get_server_logs
            routes = [r for r in vpn.router.routes if hasattr(r, 'path')]
            log_routes = [r for r in routes if 'logs' in r.path]
            assert len(log_routes) > 0, "Endpoint для получения логов не найден"
        except ImportError:
            pytest.skip("API модуль не доступен для тестирования")
    
    def test_remote_vpn_manager_has_logs_methods(self):
        """Проверяем, что RemoteVPNManager имеет методы для получения логов"""
        from services.remote_vpn_manager import RemoteVPNManager
        
        manager = RemoteVPNManager()
        assert hasattr(manager, 'get_xray_logs'), "Метод get_xray_logs не найден"
        assert hasattr(manager, 'get_wireguard_logs'), "Метод get_wireguard_logs не найден"
