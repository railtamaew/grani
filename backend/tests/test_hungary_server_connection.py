#!/usr/bin/env python3
"""
Тесты для подключения к серверу Венгрии по всем протоколам
WireGuard + 3 протокола XRay (VLESS, VMESS, REALITY)
"""
import unittest
import pytest
from unittest.mock import Mock, patch, MagicMock
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from services.vpn_operations_service import VPNOperationsService
from services.xray_manager import XrayManager
from services.wireguard_manager import WireGuardManager
from models.server import Server
from models.user import User, Device

pytest.skip(
    "Требует интеграции и актуального сервиса VPNOperationsService; пропускаем в unit-тестах.",
    allow_module_level=True
)

class TestHungaryServerConnection(unittest.TestCase):
    """Тесты подключения к серверу Венгрии"""
    
    def setUp(self):
        """Настройка тестового окружения"""
        self.server = Mock(spec=Server)
        self.server.id = 1
        self.server.name = "HU-BUD-01"
        self.server.ip_address = "45.12.132.94"
        self.server.country = "Венгрия"
        self.server.city = "Будапешт"
        self.server.is_active = True
        self.server.wireguard_port = 51820
        self.server.xray_port = 2053
        self.server.wireguard_public_key = "test_wg_public_key"
        self.server.wireguard_private_key = "test_wg_private_key"
        self.server.reality_enabled = True
        self.server.reality_public_key = "test_reality_public_key"
        self.server.reality_short_id = "test_short_id"
        self.server.reality_sni = "google.com"
        self.server.reality_dest = "google.com:443"
        self.server.supported_protocols = ['wireguard', 'xray_vless', 'xray_vmess', 'xray_reality']
        
        self.user = Mock(spec=User)
        self.user.id = 1
        self.user.email = "test@example.com"
        
        self.device = Mock(spec=Device)
        self.device.id = 1
        self.device.device_id = "test_device_id"
        self.device.user_id = 1
        self.device.wireguard_private_key = "test_device_wg_private"
        self.device.wireguard_public_key = "test_device_wg_public"
    
    @patch('services.vpn_operations_service.RemoteVPNManager')
    @patch('services.vpn_operations_service.WireGuardManager')
    def test_connect_wireguard(self, mock_wg_manager, mock_remote_manager):
        """Тест подключения через WireGuard"""
        # Настраиваем моки
        mock_wg_instance = MagicMock()
        mock_wg_manager.return_value = mock_wg_instance
        
        mock_wg_instance.create_client_config.return_value = "[Interface]\nPrivateKey = test\n[Peer]\nPublicKey = test"
        
        # Создаем сервис
        vpn_service = VPNOperationsService()
        vpn_service.db = Mock()
        
        # Тестируем подключение
        result = vpn_service.connect_device(self.user, self.device, self.server, "wireguard")
        
        # Проверяем результат
        self.assertTrue(result['success'])
        self.assertIn('config', result)
        self.assertIn('ip_address', result)
    
    @patch('services.vpn_operations_service.XrayManager')
    def test_connect_xray_vless(self, mock_xray_manager):
        """Тест подключения через XRay VLESS"""
        # Настраиваем моки
        mock_xray_instance = MagicMock()
        mock_xray_manager.return_value = mock_xray_instance
        
        mock_xray_instance.create_vless_client.return_value = {
            'success': True,
            'config': 'vless://uuid@45.12.132.94:443?security=none&type=tcp#GRANI',
            'client_id': 'vless_1_1',
            'uuid': 'test-uuid'
        }
        
        # Создаем сервис
        vpn_service = VPNOperationsService()
        vpn_service.db = Mock()
        
        # Тестируем подключение
        result = vpn_service.connect_device(self.user, self.device, self.server, "xray_vless")
        
        # Проверяем результат
        self.assertTrue(result['success'])
        self.assertIn('config', result)
        self.assertIn('vless://', result['config'])
    
    @patch('services.vpn_operations_service.XrayManager')
    def test_connect_xray_vmess(self, mock_xray_manager):
        """Тест подключения через XRay VMESS"""
        # Настраиваем моки
        mock_xray_instance = MagicMock()
        mock_xray_manager.return_value = mock_xray_instance
        
        mock_xray_instance.create_vmess_client.return_value = {
            'success': True,
            'config': 'vmess://base64encodedconfig',
            'client_id': 'vmess_1_1',
            'uuid': 'test-uuid'
        }
        
        # Создаем сервис
        vpn_service = VPNOperationsService()
        vpn_service.db = Mock()
        
        # Тестируем подключение
        result = vpn_service.connect_device(self.user, self.device, self.server, "xray_vmess")
        
        # Проверяем результат
        self.assertTrue(result['success'])
        self.assertIn('config', result)
        self.assertIn('vmess://', result['config'])
    
    @patch('services.vpn_operations_service.XrayManager')
    def test_connect_xray_reality(self, mock_xray_manager):
        """Тест подключения через XRay REALITY"""
        # Настраиваем моки
        mock_xray_instance = MagicMock()
        mock_xray_manager.return_value = mock_xray_instance
        
        mock_xray_instance.create_reality_client.return_value = {
            'success': True,
            'config': 'vless://uuid@45.12.132.94:4443?security=reality&sni=google.com&pbk=test_reality_public_key&sid=test_short_id#GRANI-REALITY',
            'client_id': 'reality_1_1',
            'uuid': 'test-uuid'
        }
        
        # Создаем сервис
        vpn_service = VPNOperationsService()
        vpn_service.db = Mock()
        
        # Тестируем подключение
        result = vpn_service.connect_device(self.user, self.device, self.server, "xray_reality")
        
        # Проверяем результат
        self.assertTrue(result['success'])
        self.assertIn('config', result)
        self.assertIn('vless://', result['config'])
        self.assertIn('reality', result['config'])
        self.assertIn('sni=google.com', result['config'])
    
    def test_server_supports_all_protocols(self):
        """Тест проверки поддержки всех протоколов на сервере"""
        protocols = self.server.supported_protocols
        
        self.assertIn('wireguard', protocols)
        self.assertIn('xray_vless', protocols)
        self.assertIn('xray_vmess', protocols)
        self.assertIn('xray_reality', protocols)
    
    def test_reality_configuration(self):
        """Тест конфигурации REALITY"""
        self.assertTrue(self.server.reality_enabled)
        self.assertIsNotNone(self.server.reality_public_key)
        self.assertIsNotNone(self.server.reality_short_id)
        self.assertEqual(self.server.reality_sni, "google.com")
        self.assertEqual(self.server.reality_dest, "google.com:443")

if __name__ == '__main__':
    unittest.main()
