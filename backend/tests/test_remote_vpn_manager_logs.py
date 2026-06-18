"""
Unit-тесты для получения логов с VPN серверов через RemoteVPNManager.
Проверяют работу методов get_xray_logs и get_wireguard_logs.
"""
import pytest
from unittest.mock import Mock, MagicMock, patch
from sqlalchemy.orm import Session

from domain.models.server import Server
from services.remote_vpn_manager import RemoteVPNManager


@pytest.fixture
def remote_vpn_manager():
    """Создает RemoteVPNManager для тестирования"""
    with patch('services.remote_vpn_manager.SSH_MANAGER_AVAILABLE', True):
        with patch('services.remote_vpn_manager.SSHManager'):
            manager = RemoteVPNManager()
            manager.ssh_manager = MagicMock()
            return manager


@pytest.fixture
def test_server(db_session: Session):
    """Создает тестовый сервер с SSH конфигурацией"""
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
        ssh_key_path="/path/to/key",
        supported_protocols=["wireguard", "xray_vless", "xray_vmess", "xray_reality"]
    )
    db_session.add(server)
    db_session.commit()
    db_session.refresh(server)
    return server


class TestGetXrayLogs:
    """Тесты для получения логов XRay"""
    
    def test_get_xray_access_logs_success(
        self, 
        remote_vpn_manager: RemoteVPNManager, 
        test_server: Server
    ):
        """Тест успешного получения access логов XRay"""
        # Настраиваем мок SSH команды
        mock_result = {
            'success': True,
            'stdout': '2024-01-20 10:00:00 INFO: Connection established\n2024-01-20 10:01:00 INFO: Client connected',
            'stderr': ''
        }
        remote_vpn_manager.ssh_manager.execute_command.return_value = mock_result
        
        # Вызываем метод
        result = remote_vpn_manager.get_xray_logs(
            test_server, 
            log_type="access", 
            lines=100
        )
        
        # Проверяем результат
        assert result['success'] is True
        assert result['log_type'] == 'access'
        assert result['server_id'] == test_server.id
        assert result['lines_count'] == 2
        assert len(result['logs']) == 2
        assert 'Connection established' in result['logs'][0]
        
        # Проверяем, что SSH команда была вызвана правильно
        remote_vpn_manager.ssh_manager.execute_command.assert_called_once()
        call_args = remote_vpn_manager.ssh_manager.execute_command.call_args
        assert 'tail -n 100 /var/log/xray/access.log' in call_args[0][1]
    
    def test_get_xray_error_logs_success(
        self, 
        remote_vpn_manager: RemoteVPNManager, 
        test_server: Server
    ):
        """Тест успешного получения error логов XRay"""
        mock_result = {
            'success': True,
            'stdout': '2024-01-20 10:00:00 ERROR: Failed to connect\n2024-01-20 10:01:00 ERROR: Invalid config',
            'stderr': ''
        }
        remote_vpn_manager.ssh_manager.execute_command.return_value = mock_result
        
        result = remote_vpn_manager.get_xray_logs(
            test_server, 
            log_type="error", 
            lines=50
        )
        
        assert result['success'] is True
        assert result['log_type'] == 'error'
        assert result['lines_count'] == 2
        assert 'Failed to connect' in result['logs'][0]
        
        # Проверяем команду для error логов
        call_args = remote_vpn_manager.ssh_manager.execute_command.call_args
        assert 'tail -n 50 /var/log/xray/error.log' in call_args[0][1]
    
    def test_get_xray_journalctl_logs_success(
        self, 
        remote_vpn_manager: RemoteVPNManager, 
        test_server: Server
    ):
        """Тест успешного получения логов через journalctl"""
        mock_result = {
            'success': True,
            'stdout': 'Jan 20 10:00:00 server xray[1234]: Service started\nJan 20 10:01:00 server xray[1234]: Client connected',
            'stderr': ''
        }
        remote_vpn_manager.ssh_manager.execute_command.return_value = mock_result
        
        result = remote_vpn_manager.get_xray_logs(
            test_server, 
            log_type="journalctl", 
            lines=200
        )
        
        assert result['success'] is True
        assert result['log_type'] == 'journalctl'
        assert result['lines_count'] == 2
        
        # Проверяем команду для journalctl
        call_args = remote_vpn_manager.ssh_manager.execute_command.call_args
        assert 'journalctl -u xray-v2 -n 200 --no-pager' in call_args[0][1]
    
    def test_get_xray_logs_ssh_unavailable(
        self, 
        test_server: Server
    ):
        """Тест получения логов когда SSH недоступен"""
        manager = RemoteVPNManager()
        manager.ssh_manager = None
        
        result = manager.get_xray_logs(test_server, log_type="access", lines=100)
        
        assert result['success'] is False
        assert result['error'] == 'SSH недоступен'
        assert result['logs'] == []
    
    def test_get_xray_logs_ssh_error(
        self, 
        remote_vpn_manager: RemoteVPNManager, 
        test_server: Server
    ):
        """Тест обработки ошибки SSH"""
        mock_result = {
            'success': False,
            'stdout': '',
            'stderr': 'Connection refused'
        }
        remote_vpn_manager.ssh_manager.execute_command.return_value = mock_result
        
        result = remote_vpn_manager.get_xray_logs(test_server, log_type="access", lines=100)
        
        assert result['success'] is False
        assert 'Connection refused' in result['error']
        assert result['logs'] == []
    
    def test_get_xray_logs_exception(
        self, 
        remote_vpn_manager: RemoteVPNManager, 
        test_server: Server
    ):
        """Тест обработки исключения при получении логов"""
        remote_vpn_manager.ssh_manager.execute_command.side_effect = Exception("Unexpected error")
        
        result = remote_vpn_manager.get_xray_logs(test_server, log_type="access", lines=100)
        
        assert result['success'] is False
        assert 'Unexpected error' in result['error']
        assert result['logs'] == []
    
    def test_get_xray_logs_empty_output(
        self, 
        remote_vpn_manager: RemoteVPNManager, 
        test_server: Server
    ):
        """Тест обработки пустого вывода"""
        mock_result = {
            'success': True,
            'stdout': '',
            'stderr': ''
        }
        remote_vpn_manager.ssh_manager.execute_command.return_value = mock_result
        
        result = remote_vpn_manager.get_xray_logs(test_server, log_type="access", lines=100)
        
        assert result['success'] is True
        assert result['lines_count'] == 0
        assert result['logs'] == []


class TestGetWireguardLogs:
    """Тесты для получения логов WireGuard"""
    
    def test_get_wireguard_logs_success(
        self, 
        remote_vpn_manager: RemoteVPNManager, 
        test_server: Server
    ):
        """Тест успешного получения логов WireGuard"""
        mock_result = {
            'success': True,
            'stdout': 'Jan 20 10:00:00 server wg-quick[1234]: Starting WireGuard\nJan 20 10:01:00 server wg-quick[1234]: Peer added',
            'stderr': ''
        }
        remote_vpn_manager.ssh_manager.execute_command.return_value = mock_result
        
        result = remote_vpn_manager.get_wireguard_logs(test_server, lines=100)
        
        assert result['success'] is True
        assert result['log_type'] == 'wireguard'
        assert result['server_id'] == test_server.id
        assert result['interface'] == 'wg0'
        assert result['lines_count'] == 2
        assert len(result['logs']) == 2
        assert 'Starting WireGuard' in result['logs'][0]
        
        # Проверяем команду
        call_args = remote_vpn_manager.ssh_manager.execute_command.call_args
        assert 'journalctl -u wg-quick@wg0' in call_args[0][1]
    
    def test_get_wireguard_logs_custom_interface(
        self, 
        remote_vpn_manager: RemoteVPNManager, 
        test_server: Server
    ):
        """Тест получения логов с кастомным интерфейсом"""
        mock_result = {
            'success': True,
            'stdout': 'Jan 20 10:00:00 server wg-quick[1234]: Starting WireGuard',
            'stderr': ''
        }
        remote_vpn_manager.ssh_manager.execute_command.return_value = mock_result
        
        result = remote_vpn_manager.get_wireguard_logs(test_server, lines=50, interface="wg1")
        
        assert result['success'] is True
        assert result['interface'] == 'wg1'
        
        # Проверяем команду с кастомным интерфейсом
        call_args = remote_vpn_manager.ssh_manager.execute_command.call_args
        assert 'journalctl -u wg-quick@wg1' in call_args[0][1]
    
    def test_get_wireguard_logs_ssh_unavailable(
        self, 
        test_server: Server
    ):
        """Тест получения логов когда SSH недоступен"""
        manager = RemoteVPNManager()
        manager.ssh_manager = None
        
        result = manager.get_wireguard_logs(test_server, lines=100)
        
        assert result['success'] is False
        assert result['error'] == 'SSH недоступен'
        assert result['logs'] == []
    
    def test_get_wireguard_logs_ssh_error(
        self, 
        remote_vpn_manager: RemoteVPNManager, 
        test_server: Server
    ):
        """Тест обработки ошибки SSH"""
        mock_result = {
            'success': False,
            'stdout': '',
            'stderr': 'Service not found'
        }
        remote_vpn_manager.ssh_manager.execute_command.return_value = mock_result
        
        result = remote_vpn_manager.get_wireguard_logs(test_server, lines=100)
        
        assert result['success'] is False
        assert 'Service not found' in result['error']
        assert result['logs'] == []
    
    def test_get_wireguard_logs_exception(
        self, 
        remote_vpn_manager: RemoteVPNManager, 
        test_server: Server
    ):
        """Тест обработки исключения"""
        remote_vpn_manager.ssh_manager.execute_command.side_effect = Exception("Network error")
        
        result = remote_vpn_manager.get_wireguard_logs(test_server, lines=100)
        
        assert result['success'] is False
        assert 'Network error' in result['error']
        assert result['logs'] == []


class TestGetLogsIntegration:
    """Интеграционные тесты для получения логов"""
    
    def test_get_logs_with_different_line_counts(
        self, 
        remote_vpn_manager: RemoteVPNManager, 
        test_server: Server
    ):
        """Тест получения разного количества строк"""
        # Тест с 10 строками
        mock_result_10 = {
            'success': True,
            'stdout': '\n'.join([f'Line {i}' for i in range(10)]),
            'stderr': ''
        }
        remote_vpn_manager.ssh_manager.execute_command.return_value = mock_result_10
        
        result = remote_vpn_manager.get_xray_logs(test_server, lines=10)
        assert result['lines_count'] == 10
        
        # Тест с 50 строками
        mock_result_50 = {
            'success': True,
            'stdout': '\n'.join([f'Line {i}' for i in range(50)]),
            'stderr': ''
        }
        remote_vpn_manager.ssh_manager.execute_command.return_value = mock_result_50
        
        result = remote_vpn_manager.get_xray_logs(test_server, lines=50)
        assert result['lines_count'] == 50
    
    def test_get_logs_ssh_config_usage(
        self, 
        remote_vpn_manager: RemoteVPNManager, 
        test_server: Server
    ):
        """Тест правильного использования SSH конфигурации"""
        mock_result = {
            'success': True,
            'stdout': 'Test log',
            'stderr': ''
        }
        remote_vpn_manager.ssh_manager.execute_command.return_value = mock_result
        
        remote_vpn_manager.get_xray_logs(test_server, lines=100)
        
        # Проверяем, что SSH команда вызвана с правильными параметрами
        call_args = remote_vpn_manager.ssh_manager.execute_command.call_args
        # execute_command принимает позиционные аргументы: host, command, port, username, ...
        assert call_args[0][0] == test_server.ssh_host or call_args[0][0] == test_server.ip_address
        assert call_args[0][2] == test_server.ssh_port or call_args[0][2] == 22
        assert call_args[0][3] == test_server.ssh_user or call_args[0][3] == 'root'
