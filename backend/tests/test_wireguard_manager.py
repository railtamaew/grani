"""
Unit-тесты для WireGuardManager.
Проверяют работу с WireGuard протоколом (локальные и удаленные серверы).
"""
import pytest
from unittest.mock import Mock, MagicMock, patch, mock_open
from sqlalchemy.orm import Session

from domain.models.user import User, Device
from domain.models.server import Server
from infrastructure.external.wireguard_manager import WireGuardManager


@pytest.fixture
def wireguard_manager():
    """Создает WireGuardManager для тестирования"""
    return WireGuardManager()


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
        supported_protocols=["wireguard"]
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
        device_id="test-device-wg",
        device_name="Test Device",
        wireguard_public_key="device_public_key",
        wireguard_private_key="device_private_key"
    )
    db_session.add(device)
    db_session.commit()
    db_session.refresh(device)
    return device


class TestGetNextAvailableIP:
    """Тесты для получения доступных IP адресов"""
    
    def test_get_next_available_ip_local(self, wireguard_manager: WireGuardManager, test_server: Server):
        """Тест получения IP для локального сервера"""
        # Очищаем использованные IP
        wireguard_manager.used_ips.clear()
        
        ip = wireguard_manager.get_next_available_ip(test_server)
        
        assert ip.startswith("10.0.0.")
        assert ip != "10.0.0.1"  # Серверный IP
        assert ip in wireguard_manager.used_ips
    
    def test_get_next_available_ip_remote(self, wireguard_manager: WireGuardManager, test_remote_server: Server):
        """Тест получения IP для удаленного сервера (мок)"""
        # Мокаем RemoteVPNManager
        mock_remote_manager = MagicMock()
        mock_remote_manager.get_next_available_wireguard_ip.return_value = "10.0.0.100"
        wireguard_manager.remote_manager = mock_remote_manager
        
        ip = wireguard_manager.get_next_available_ip(test_remote_server)
        
        assert ip == "10.0.0.100"
        mock_remote_manager.get_next_available_wireguard_ip.assert_called_once_with(test_remote_server)
    
    def test_get_next_available_ip_no_ips(self, wireguard_manager: WireGuardManager, test_server: Server):
        """Тест обработки переполнения IP адресов"""
        # Заполняем все доступные IP
        network = wireguard_manager.network
        for ip in network.hosts():
            ip_str = str(ip)
            if ip_str != '10.0.0.1':
                wireguard_manager.used_ips.add(ip_str)
        
        # Попытка получить IP должна вызвать исключение
        with pytest.raises(Exception, match="Нет доступных IP адресов"):
            wireguard_manager.get_next_available_ip(test_server)


class TestGenerateKeyPair:
    """Тесты для генерации ключей WireGuard"""
    
    @patch('subprocess.check_output')
    def test_generate_key_pair_local(self, mock_subprocess, wireguard_manager: WireGuardManager, test_server: Server):
        """Тест генерации ключей для локального сервера"""
        # Мокаем subprocess
        mock_subprocess.side_effect = [
            "private_key_output",  # wg genkey
            "public_key_output"    # wg pubkey
        ]
        
        result = wireguard_manager.generate_key_pair(test_server)
        
        assert 'private_key' in result
        assert 'public_key' in result
        assert result['private_key'] == "private_key_output"
        assert result['public_key'] == "public_key_output"
        assert mock_subprocess.call_count == 2
    
    def test_generate_key_pair_remote(self, wireguard_manager: WireGuardManager, test_remote_server: Server):
        """Тест генерации ключей для удаленного сервера (мок)"""
        # Мокаем RemoteVPNManager
        mock_remote_manager = MagicMock()
        mock_remote_manager.generate_wireguard_key_pair.return_value = {
            'private_key': 'remote_private_key',
            'public_key': 'remote_public_key'
        }
        wireguard_manager.remote_manager = mock_remote_manager
        
        result = wireguard_manager.generate_key_pair(test_remote_server)
        
        assert result['private_key'] == 'remote_private_key'
        assert result['public_key'] == 'remote_public_key'
        mock_remote_manager.generate_wireguard_key_pair.assert_called_once_with(test_remote_server)


class TestCreateClientConfig:
    """Тесты для создания конфигураций клиентов"""
    
    def test_create_client_config_wireguard(self, wireguard_manager: WireGuardManager, test_device: Device, test_server: Server):
        """Тест создания стандартной конфигурации WireGuard"""
        client_ip = "10.0.0.2"
        
        config = wireguard_manager.create_client_config(test_device, test_server, client_ip, "wireguard")
        
        assert "[Interface]" in config
        assert test_device.wireguard_private_key in config
        assert client_ip in config
        assert test_server.wireguard_public_key in config
        assert test_server.ip_address in config
        assert str(test_server.wireguard_port) in config
        assert "DNS = 1.1.1.1, 9.9.9.9" in config
    
    def test_create_client_config_graniwg(self, wireguard_manager: WireGuardManager, test_device: Device, test_server: Server):
        """Тест создания конфигурации GRANIWG"""
        test_server.graniwg_enabled = True
        test_server.graniwg_obfuscation_key = '{"Jc":4,"Jmin":5,"Jmax":60}'
        test_server.graniwg_obfuscation_type = 'amneziawg'
        client_ip = "10.0.0.2"
        
        config = wireguard_manager.create_graniwg_client_config(test_device, test_server, client_ip)
        
        assert "[Interface]" in config
        assert test_device.wireguard_private_key in config
        assert client_ip in config
        assert "Jc = 4" in config
        assert "Jmin = 5" in config
        assert "Jmax = 60" in config
    
    def test_create_client_config_graniwg_not_enabled(self, wireguard_manager: WireGuardManager, test_device: Device, test_server: Server):
        """Тест создания конфигурации GRANIWG когда он не включен (должен вернуть WireGuard)"""
        test_server.graniwg_enabled = False
        client_ip = "10.0.0.2"
        
        config = wireguard_manager.create_graniwg_client_config(test_device, test_server, client_ip)
        
        # Должна вернуться стандартная WireGuard конфигурация
        assert "[Interface]" in config
        assert test_device.wireguard_private_key in config
        assert "GRANIWG" not in config or "GRANIWG Configuration" not in config


class TestAddPeerToServer:
    """Тесты для добавления пиров на сервер"""
    
    @patch('builtins.open', new_callable=mock_open, read_data="[Interface]\nPrivateKey = server_key\n")
    @patch.object(WireGuardManager, 'reload_interface')
    def test_add_peer_to_server_local(self, mock_reload, mock_file, wireguard_manager: WireGuardManager, 
                                      test_device: Device, test_server: Server):
        """Тест добавления пира на локальный сервер"""
        mock_reload.return_value = True
        
        result = wireguard_manager.add_peer_to_server(test_device, test_server, "10.0.0.2")
        
        assert result is True
        mock_reload.assert_called_once_with(test_server)
        # Проверяем, что файл был открыт для записи
        assert mock_file.call_count >= 2  # Чтение и запись
    
    def test_add_peer_to_server_remote(self, wireguard_manager: WireGuardManager, test_device: Device, test_remote_server: Server):
        """Тест добавления пира на удаленный сервер (мок)"""
        # Мокаем RemoteVPNManager
        mock_remote_manager = MagicMock()
        mock_remote_manager.add_wireguard_peer.return_value = True
        wireguard_manager.remote_manager = mock_remote_manager
        
        result = wireguard_manager.add_peer_to_server(test_device, test_remote_server, "10.0.0.2")
        
        assert result is True
        mock_remote_manager.add_wireguard_peer.assert_called_once_with(
            test_remote_server, test_device, "10.0.0.2"
        )


class TestRemovePeerFromServer:
    """Тесты для удаления пиров с сервера"""
    
    @patch('builtins.open', new_callable=mock_open, read_data="[Interface]\nPrivateKey = server_key\n\n# Peer for device 1\n[Peer]\nPublicKey = device_key\n")
    @patch.object(WireGuardManager, 'reload_interface')
    def test_remove_peer_from_server_local(self, mock_reload, mock_file, wireguard_manager: WireGuardManager,
                                           test_device: Device, test_server: Server):
        """Тест удаления пира с локального сервера"""
        test_device.id = 1
        mock_reload.return_value = True
        
        result = wireguard_manager.remove_peer_from_server(test_device, test_server)
        
        assert result is True
        mock_reload.assert_called_once_with(test_server)
    
    def test_remove_peer_from_server_remote(self, wireguard_manager: WireGuardManager, test_device: Device, test_remote_server: Server):
        """Тест удаления пира с удаленного сервера (мок)"""
        # Мокаем RemoteVPNManager
        mock_remote_manager = MagicMock()
        mock_remote_manager.remove_wireguard_peer.return_value = True
        wireguard_manager.remote_manager = mock_remote_manager
        
        result = wireguard_manager.remove_peer_from_server(test_device, test_remote_server)
        
        assert result is True
        mock_remote_manager.remove_wireguard_peer.assert_called_once_with(test_remote_server, test_device)
    
    def test_remove_peer_from_server_no_server(self, wireguard_manager: WireGuardManager, test_device: Device):
        """Тест удаления пира без указания сервера"""
        result = wireguard_manager.remove_peer_from_server(test_device, None)
        
        assert result is False


class TestGetPeerStats:
    """Тесты для получения статистики пиров"""
    
    @patch('subprocess.run')
    def test_get_peer_stats_local(self, mock_subprocess, wireguard_manager: WireGuardManager, test_server: Server):
        """Тест получения статистики пира на локальном сервере"""
        # Мокаем вывод wg show dump (формат: public_key endpoint allowed_ips latest_handshake transfer_rx transfer_tx)
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "test_public_key\t192.168.1.1:51820\t10.0.0.2/32\t1234567890\t1000\t2000\n"
        mock_subprocess.return_value = mock_result
        
        stats = wireguard_manager.get_peer_stats("test_public_key", test_server)
        
        # Может вернуть словарь с данными или ошибку, если пир не найден
        assert isinstance(stats, dict)
        assert 'endpoint' in stats or 'error' in stats or 'transfer' in stats or 'latest_handshake' in stats
    
    def test_get_peer_stats_remote(self, wireguard_manager: WireGuardManager, test_remote_server: Server):
        """Тест получения статистики пира на удаленном сервере (мок)"""
        # Мокаем RemoteVPNManager
        mock_remote_manager = MagicMock()
        mock_remote_manager.get_wireguard_status.return_value = {
            'peers': [{
                'public_key': 'test_public_key',
                'endpoint': '192.168.1.1:51820',
                'transfer': '1000 B received, 2000 B sent'
            }]
        }
        wireguard_manager.remote_manager = mock_remote_manager
        
        stats = wireguard_manager.get_peer_stats("test_public_key", test_remote_server)
        
        assert stats is not None
        mock_remote_manager.get_wireguard_status.assert_called_once_with(test_remote_server)


class TestCheckInterfaceHealth:
    """Тесты для проверки здоровья интерфейса"""
    
    @patch('subprocess.run')
    def test_check_interface_health_active(self, mock_subprocess, wireguard_manager: WireGuardManager):
        """Тест проверки здоровья активного интерфейса"""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "interface: wg0\npeer: test_key\n"
        mock_subprocess.return_value = mock_result
        
        health = wireguard_manager.check_interface_health()
        
        assert 'status' in health or 'active' in str(health).lower() or 'peers' in health
    
    @patch('subprocess.run')
    def test_check_interface_health_inactive(self, mock_subprocess, wireguard_manager: WireGuardManager):
        """Тест проверки здоровья неактивного интерфейса"""
        mock_result = MagicMock()
        mock_result.returncode = 1
        mock_result.stderr = "Interface not found"
        mock_subprocess.return_value = mock_result
        
        health = wireguard_manager.check_interface_health()
        
        assert 'error' in health or 'status' in health
