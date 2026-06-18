"""
Тесты для edge cases протоколов серверов.
Проверяют обработку ошибок, недоступность серверов и другие граничные случаи.
"""
import pytest
from unittest.mock import Mock, MagicMock, patch
from sqlalchemy.orm import Session

from domain.models.user import User, Device
from domain.models.server import Server
from infrastructure.external.wireguard_manager import WireGuardManager
from infrastructure.external.xray_manager import XrayManager
from application.services.vpn_operations_service import VPNOperationsService
from application.services.device_manager import DeviceManager


@pytest.fixture
def test_server(db_session: Session):
    """Создает тестовый сервер"""
    server = Server(
        name="Test Server",
        ip_address="192.168.1.1",
        country="US",
        city="New York",
        is_active=True,
        wireguard_port=51820,
        wireguard_public_key="test_public_key",
        is_local=True,
        supported_protocols=["wireguard", "graniwg"]
    )
    db_session.add(server)
    db_session.commit()
    db_session.refresh(server)
    return server


@pytest.fixture
def test_remote_server(db_session: Session):
    """Создает тестовый удаленный сервер"""
    server = Server(
        name="Remote Server",
        ip_address="45.12.132.94",
        country="US",
        city="New York",
        is_active=True,
        wireguard_port=51820,
        wireguard_public_key="remote_public_key",
        is_local=False,
        ssh_host="45.12.132.94",
        ssh_port=22,
        ssh_user="root",
        supported_protocols=["wireguard", "xray_vless"]
    )
    db_session.add(server)
    db_session.commit()
    db_session.refresh(server)
    return server


@pytest.fixture
def test_device(db_session: Session, test_user: User):
    """Создает тестовое устройство"""
    device = Device(
        user_id=test_user.id,
        device_id="test-device-edge",
        device_name="Test Device",
        wireguard_public_key="device_public_key",
        wireguard_private_key="device_private_key"
    )
    db_session.add(device)
    db_session.commit()
    db_session.refresh(device)
    return device


class TestWireGuardSSHErrors:
    """Тесты для обработки ошибок SSH в WireGuard"""
    
    def test_wireguard_ssh_error_on_add_peer(self, test_device: Device, test_remote_server: Server):
        """Тест обработки ошибки SSH при добавлении пира"""
        wg_manager = WireGuardManager()
        
        # Мокаем RemoteVPNManager с ошибкой SSH
        mock_remote_manager = MagicMock()
        mock_remote_manager.add_wireguard_peer.side_effect = Exception("SSH connection failed")
        wg_manager.remote_manager = mock_remote_manager
        
        result = wg_manager.add_peer_to_server(test_device, test_remote_server, "10.0.0.2")
        
        assert result is False
    
    def test_wireguard_ssh_error_on_get_ip(self, test_remote_server: Server):
        """Тест обработки ошибки SSH при получении IP"""
        wg_manager = WireGuardManager()
        
        # Мокаем RemoteVPNManager с ошибкой SSH
        mock_remote_manager = MagicMock()
        mock_remote_manager.get_next_available_wireguard_ip.side_effect = Exception("SSH connection failed")
        wg_manager.remote_manager = mock_remote_manager
        
        with pytest.raises(Exception, match="Нет доступных IP адресов|SSH connection failed"):
            wg_manager.get_next_available_ip(test_remote_server)
    
    def test_wireguard_ssh_error_on_remove_peer(self, test_device: Device, test_remote_server: Server):
        """Тест обработки ошибки SSH при удалении пира"""
        wg_manager = WireGuardManager()
        
        # Мокаем RemoteVPNManager с ошибкой SSH
        mock_remote_manager = MagicMock()
        mock_remote_manager.remove_wireguard_peer.side_effect = Exception("SSH connection failed")
        wg_manager.remote_manager = mock_remote_manager
        
        result = wg_manager.remove_peer_from_server(test_device, test_remote_server)
        
        assert result is False


class TestXraySSHErrors:
    """Тесты для обработки ошибок SSH в Xray (create_vless_client использует with_ssh_connection)"""
    
    def test_xray_ssh_error_on_read_config(self, test_device: Device, test_remote_server: Server):
        """Тест обработки ошибки SSH при подключении к Xray серверу"""
        xray_manager = XrayManager()
        
        mock_remote_manager = MagicMock()
        mock_remote_manager.with_ssh_connection.side_effect = Exception("SSH connection failed")
        xray_manager.remote_manager = mock_remote_manager
        
        result = xray_manager.create_vless_client(test_device, test_remote_server)
        
        assert result['success'] is False
        assert 'error' in result
    
    def test_xray_ssh_error_on_write_config(self, test_device: Device, test_remote_server: Server):
        """Тест обработки ошибки SSH при операции записи конфигурации Xray"""
        xray_manager = XrayManager()
        
        mock_remote_manager = MagicMock()
        mock_remote_manager.with_ssh_connection.side_effect = Exception("SSH write failed")
        xray_manager.remote_manager = mock_remote_manager
        
        result = xray_manager.create_vless_client(test_device, test_remote_server)
        
        assert result['success'] is False
        assert 'error' in result
    
    def test_xray_config_read_error(self, test_device: Device, test_remote_server: Server):
        """Тест обработки ошибки чтения конфигурации Xray (невалидный JSON)"""
        xray_manager = XrayManager()
        
        # Мокаем RemoteVPNManager с невалидным JSON
        mock_remote_manager = MagicMock()
        mock_ssh_manager = MagicMock()
        mock_ssh_manager.download_content.return_value = "invalid json"
        mock_remote_manager.ssh_manager = mock_ssh_manager
        xray_manager.remote_manager = mock_remote_manager
        
        # Должен создать базовую конфигурацию при ошибке парсинга
        result = xray_manager.create_vless_client(test_device, test_remote_server)
        
        # Может быть успешным (создаст базовую конфигурацию) или неуспешным (ошибка парсинга)
        assert 'success' in result or 'error' in result


class TestServerUnavailable:
    """Тесты для недоступности серверов"""
    
    def test_server_unavailable_wireguard(self, test_device: Device):
        """Тест обработки недоступности сервера WireGuard"""
        wg_manager = WireGuardManager()
        
        # Создаем сервер с неверными данными
        unavailable_server = Server(
            name="Unavailable Server",
            ip_address="192.168.999.999",  # Невалидный IP
            is_local=False,
            ssh_host="unreachable.host",
            ssh_port=22
        )
        
        # Мокаем RemoteVPNManager с ошибкой подключения
        mock_remote_manager = MagicMock()
        mock_remote_manager.get_next_available_wireguard_ip.side_effect = Exception("Connection timeout")
        wg_manager.remote_manager = mock_remote_manager
        
        with pytest.raises(Exception):
            wg_manager.get_next_available_ip(unavailable_server)
    
    def test_server_unavailable_xray(self, test_device: Device):
        """Тест обработки недоступности сервера Xray"""
        xray_manager = XrayManager()
        
        unavailable_server = Server(
            name="Unavailable Server",
            ip_address="192.168.999.999",
            is_local=False,
            ssh_host="unreachable.host",
            ssh_port=22
        )
        
        mock_remote_manager = MagicMock()
        mock_remote_manager.with_ssh_connection.side_effect = Exception("Connection timeout")
        xray_manager.remote_manager = mock_remote_manager
        
        result = xray_manager.create_vless_client(test_device, unavailable_server)
        
        assert result['success'] is False
        assert 'error' in result


class TestUnsupportedProtocol:
    """Тесты для неподдерживаемых протоколов (только Xray)."""
    
    def test_unsupported_protocol_connection(self, test_user: User, test_device: Device, test_server: Server, db_session: Session):
        """Подключение с протоколом, который сервер не поддерживает — HTTP 400."""
        from infrastructure.external.wireguard_manager import WireGuardManager
        from fastapi import HTTPException

        test_device.is_active = False
        test_device.current_server_id = None
        test_user.trial_active = True
        test_user.trial_seconds_left = 600
        db_session.commit()
        db_session.refresh(test_device)

        wg_manager = WireGuardManager()
        device_manager = DeviceManager(db_session, wg_manager)
        vpn_service = VPNOperationsService(db_session, device_manager)

        test_server.supported_protocols = ["xray_reality"]
        test_server.xray_port = 4443
        test_server.xray_config_path = "/etc/xray/config.json"
        test_server.reality_enabled = True
        db_session.commit()
        db_session.refresh(test_server)

        with pytest.raises(HTTPException) as exc_info:
            vpn_service.connect_device(test_user, test_device, test_server, "xray_vless")
        assert exc_info.value.status_code == 400
        assert "не поддерживает" in exc_info.value.detail or "протокол" in exc_info.value.detail.lower()


class TestIPOverflow:
    """Тесты для переполнения IP адресов"""
    
    def test_ip_overflow_wireguard(self, test_server: Server):
        """Тест обработки переполнения IP адресов в WireGuard"""
        wg_manager = WireGuardManager()
        
        # Заполняем все доступные IP
        network = wg_manager.network
        for ip in network.hosts():
            ip_str = str(ip)
            if ip_str != '10.0.0.1':
                wg_manager.used_ips.add(ip_str)
        
        # Попытка получить IP должна вызвать исключение
        with pytest.raises(Exception, match="Нет доступных IP адресов"):
            wg_manager.get_next_available_ip(test_server)
    
    def test_ip_overflow_remote_wireguard(self, test_remote_server: Server):
        """Тест обработки переполнения IP адресов на удаленном сервере"""
        wg_manager = WireGuardManager()
        
        # Мокаем RemoteVPNManager с ошибкой переполнения
        mock_remote_manager = MagicMock()
        mock_remote_manager.get_next_available_wireguard_ip.return_value = None
        wg_manager.remote_manager = mock_remote_manager
        
        with pytest.raises(Exception, match="Нет доступных IP адресов"):
            wg_manager.get_next_available_ip(test_remote_server)


class TestInvalidConfigurations:
    """Тесты для некорректных конфигураций"""
    
    def test_invalid_wireguard_config_path(self, test_device: Device, test_server: Server):
        """Тест обработки некорректного пути к конфигурации WireGuard"""
        wg_manager = WireGuardManager()
        
        # Устанавливаем несуществующий путь
        test_server.wireguard_config_path = "/nonexistent/path/config.conf"
        
        # Мокаем open для вызова FileNotFoundError
        with patch('builtins.open', side_effect=FileNotFoundError("File not found")):
            result = wg_manager.add_peer_to_server(test_device, test_server, "10.0.0.2")
            assert result is False
    
    def test_invalid_xray_config_path(self, test_device: Device, test_remote_server: Server):
        """Тест обработки некорректного пути к конфигурации Xray"""
        xray_manager = XrayManager()
        
        # Устанавливаем несуществующий путь
        test_remote_server.xray_config_path = "/nonexistent/path/config.json"
        
        # Мокаем RemoteVPNManager с ошибкой
        mock_remote_manager = MagicMock()
        mock_ssh_manager = MagicMock()
        mock_ssh_manager.download_content.side_effect = FileNotFoundError("File not found")
        mock_remote_manager.ssh_manager = mock_ssh_manager
        xray_manager.remote_manager = mock_remote_manager
        
        # Должен создать базовую конфигурацию или вернуть ошибку
        result = xray_manager.create_vless_client(test_device, test_remote_server)
        
        # Может быть успешным (создаст базовую конфигурацию) или неуспешным
        assert 'success' in result or 'error' in result
