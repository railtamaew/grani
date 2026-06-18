#!/usr/bin/env python3
"""
Тесты для сервиса установки и настройки XRay
"""
import unittest
from unittest.mock import Mock, patch, MagicMock
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from services.xray_provisioning_service import XrayProvisioningService
from models.server import Server

class TestXrayProvisioningService(unittest.TestCase):
    """Тесты для XrayProvisioningService"""
    
    def setUp(self):
        """Настройка тестового окружения"""
        self.server = Mock(spec=Server)
        self.server.id = 1
        self.server.ip_address = "45.12.132.94"
        self.server.xray_port = 443
        self.server.xray_config_path = "/usr/local/etc/xray/config.json"
        self.server.ssh_host = None
        self.server.ssh_port = 22
        self.server.ssh_user = "root"
        self.server.ssh_password = "test_password"
        self.server.is_local = False
        self.server.reality_enabled = False
        self.server.reality_public_key = None
        self.server.reality_short_id = None
        self.server.reality_sni = None
        self.server.reality_dest = None
        
    @patch('services.xray_provisioning_service.RemoteVPNManager')
    def test_install_xray_already_installed(self, mock_remote_manager):
        """Тест установки XRay когда он уже установлен"""
        # Настраиваем моки
        mock_ssh_manager = MagicMock()
        mock_remote_manager_instance = MagicMock()
        mock_remote_manager_instance.ssh_manager = mock_ssh_manager
        mock_remote_manager.return_value = mock_remote_manager_instance
        
        # Мок SSH конфигурации
        mock_remote_manager_instance.get_ssh_config.return_value = {
            'host': '45.12.132.94',
            'port': 22,
            'username': 'root',
            'password': 'test_password'
        }
        
        # Мок проверки установки XRay
        mock_ssh_manager.execute_command.return_value = {
            'success': True,
            'stdout': '/usr/local/bin/xray\nXray 1.8.0',
            'stderr': ''
        }
        
        # Создаем сервис и тестируем
        service = XrayProvisioningService()
        result = service.install_xray(self.server)
        
        # Проверяем результат
        self.assertTrue(result['success'])
        self.assertTrue(result['installed'])
        self.assertIn('version', result)
        
    @patch('services.xray_provisioning_service.RemoteVPNManager')
    def test_setup_base_xray_config(self, mock_remote_manager):
        """Тест настройки базовой конфигурации XRay"""
        # Настраиваем моки
        mock_ssh_manager = MagicMock()
        mock_remote_manager_instance = MagicMock()
        mock_remote_manager_instance.ssh_manager = mock_ssh_manager
        mock_remote_manager.return_value = mock_remote_manager_instance
        
        mock_remote_manager_instance.get_ssh_config.return_value = {
            'host': '45.12.132.94',
            'port': 22,
            'username': 'root',
            'password': 'test_password'
        }
        
        # Мок XrayManager
        with patch('services.xray_provisioning_service.XrayManager') as mock_xray_manager:
            mock_xray_instance = MagicMock()
            mock_xray_manager.return_value = mock_xray_instance
            
            # Мок чтения конфигурации
            mock_xray_instance._read_xray_config.return_value = {
                "log": {"loglevel": "warning"},
                "inbounds": [],
                "outbounds": [
                    {"protocol": "freedom", "settings": {}},
                    {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
                ],
                "routing": {
                    "rules": [
                        {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"}
                    ]
                }
            }
            
            # Мок записи конфигурации
            mock_xray_instance._write_xray_config.return_value = True
            mock_xray_instance._reload_xray.return_value = True
            
            # Создаем сервис и тестируем
            service = XrayProvisioningService()
            result = service.setup_base_xray_config(self.server, port=443)
            
            # Проверяем результат
            self.assertTrue(result['success'])
            self.assertEqual(result['port'], 443)
            self.assertTrue(result['vless_configured'])
            
            # Проверяем, что конфигурация была записана
            mock_xray_instance._write_xray_config.assert_called_once()
            mock_xray_instance._reload_xray.assert_called_once()
    
    @patch('services.xray_provisioning_service.RemoteVPNManager')
    def test_setup_reality(self, mock_remote_manager):
        """Тест настройки REALITY протокола"""
        # Настраиваем моки
        mock_ssh_manager = MagicMock()
        mock_remote_manager_instance = MagicMock()
        mock_remote_manager_instance.ssh_manager = mock_ssh_manager
        mock_remote_manager.return_value = mock_remote_manager_instance
        
        mock_remote_manager_instance.get_ssh_config.return_value = {
            'host': '45.12.132.94',
            'port': 22,
            'username': 'root',
            'password': 'test_password'
        }
        
        # Мок генерации ключей REALITY
        mock_ssh_manager.execute_command.return_value = {
            'success': True,
            'stdout': 'Private key: test_private_key_12345\nPublic key: test_public_key_67890',
            'stderr': ''
        }
        
        # Мок XrayManager
        with patch('services.xray_provisioning_service.XrayManager') as mock_xray_manager:
            mock_xray_instance = MagicMock()
            mock_xray_manager.return_value = mock_xray_instance
            
            # Мок чтения конфигурации
            mock_xray_instance._read_xray_config.return_value = {
                "log": {"loglevel": "warning"},
                "inbounds": [],
                "outbounds": [
                    {"protocol": "freedom", "settings": {}}
                ],
                "routing": {
                    "rules": []
                }
            }
            
            # Мок записи конфигурации
            mock_xray_instance._write_xray_config.return_value = True
            mock_xray_instance._reload_xray.return_value = True
            
            # Создаем сервис и тестируем
            service = XrayProvisioningService()
            result = service.setup_reality(self.server, sni="google.com", dest="google.com:443")
            
            # Проверяем результат
            self.assertTrue(result['success'])
            self.assertIn('private_key', result)
            self.assertIn('public_key', result)
            self.assertIn('short_id', result)
            self.assertEqual(result['sni'], "google.com")
            self.assertEqual(result['dest'], "google.com:443")
            
            # Проверяем, что конфигурация была записана
            mock_xray_instance._write_xray_config.assert_called_once()
            mock_xray_instance._reload_xray.assert_called_once()
    
    @patch('services.xray_provisioning_service.RemoteVPNManager')
    def test_provision_server(self, mock_remote_manager):
        """Тест полной настройки сервера"""
        # Настраиваем моки
        mock_ssh_manager = MagicMock()
        mock_remote_manager_instance = MagicMock()
        mock_remote_manager_instance.ssh_manager = mock_ssh_manager
        mock_remote_manager.return_value = mock_remote_manager_instance
        
        mock_remote_manager_instance.get_ssh_config.return_value = {
            'host': '45.12.132.94',
            'port': 22,
            'username': 'root',
            'password': 'test_password'
        }
        
        # Мок установки XRay
        mock_ssh_manager.execute_command.return_value = {
            'success': True,
            'stdout': '/usr/local/bin/xray\nXray 1.8.0',
            'stderr': ''
        }
        
        # Мок XrayManager
        with patch('services.xray_provisioning_service.XrayManager') as mock_xray_manager:
            mock_xray_instance = MagicMock()
            mock_xray_manager.return_value = mock_xray_instance
            
            mock_xray_instance._read_xray_config.return_value = {
                "log": {"loglevel": "warning"},
                "inbounds": [],
                "outbounds": [{"protocol": "freedom", "settings": {}}],
                "routing": {"rules": []}
            }
            
            mock_xray_instance._write_xray_config.return_value = True
            mock_xray_instance._reload_xray.return_value = True
            
            # Создаем сервис и тестируем
            service = XrayProvisioningService()
            
            # Мокируем методы установки
            with patch.object(service, 'install_xray') as mock_install, \
                 patch.object(service, 'setup_base_xray_config') as mock_setup_config, \
                 patch.object(service, 'setup_reality') as mock_setup_reality:
                
                mock_install.return_value = {'success': True, 'installed': True, 'version': '1.8.0'}
                mock_setup_config.return_value = {'success': True, 'port': 443, 'vless_configured': True}
                mock_setup_reality.return_value = {
                    'success': True,
                    'private_key': 'test_private',
                    'public_key': 'test_public',
                    'short_id': 'test_short_id',
                    'sni': 'google.com',
                    'dest': 'google.com:443',
                    'port': 4443
                }
                
                protocols = ['wireguard', 'xray_vless', 'xray_vmess', 'xray_reality']
                result = service.provision_server(self.server, protocols)
                
                # Проверяем результат
                self.assertTrue(result['success'])
                self.assertEqual(result['server_id'], 1)
                self.assertEqual(result['server_ip'], "45.12.132.94")
                self.assertEqual(result['protocols'], protocols)
                self.assertIn('steps', result)
                
                # Проверяем, что все методы были вызваны
                mock_install.assert_called_once()
                mock_setup_config.assert_called_once()
                mock_setup_reality.assert_called_once()

if __name__ == '__main__':
    unittest.main()
