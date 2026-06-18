"""
Unit-тесты для XrayManager.
Проверяют работу с Xray протоколами (VLESS, VMESS, REALITY).
"""
import pytest
import json
import uuid
from unittest.mock import Mock, MagicMock, patch
from sqlalchemy.orm import Session

from domain.models.user import User, Device
from domain.models.server import Server
from infrastructure.external.xray_manager import XrayManager


@pytest.fixture
def xray_manager():
    """Создает XrayManager для тестирования"""
    return XrayManager()


@pytest.fixture
def test_server(db_session: Session):
    """Создает тестовый сервер с SSH конфигурацией"""
    server = Server(
        name="Test Xray Server",
        ip_address="45.12.132.94",
        country="US",
        city="New York",
        is_active=True,
        xray_config_path="/usr/local/etc/xray/config.json",
        ssh_host="45.12.132.94",
        ssh_port=22,
        ssh_user="root",
        ssh_key_path="/path/to/key",
        supported_protocols=["xray_vless", "xray_vmess", "xray_reality"],
        reality_enabled=True,
        reality_public_key="test_reality_public_key",
        reality_short_id="test_short_id",
        reality_sni="google.com",
        reality_dest="google.com:443",
        reality_private_key="test_reality_private_key"
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
        device_id="test-device-xray",
        device_name="Test Device"
    )
    db_session.add(device)
    db_session.commit()
    db_session.refresh(device)
    return device


@pytest.fixture
def mock_xray_config():
    """Базовая конфигурация Xray для тестов"""
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "tag": "vless-in",
                "protocol": "vless",
                "port": 4443,
                "settings": {
                    "clients": []
                },
                "streamSettings": {
                    "network": "tcp",
                    "security": "none"
                }
            }
        ],
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


_FIXED_CLIENT_UUID = uuid.UUID("12345678-1234-5678-1234-567812345678")


def test_generate_client_json_config_accepts_xray_prefixed_protocol(
    xray_manager: XrayManager,
    test_server: Server,
):
    """xray_* protocol names must map to correct non-REALITY ports."""
    cfg = xray_manager._generate_client_json_config(
        client_id="vless_1_1",
        server=test_server,
        protocol="xray_vless",
        uuid_str=str(_FIXED_CLIENT_UUID),
    )

    assert cfg is not None
    assert cfg["protocol"] == "vless"
    assert cfg["port"] == 4443
    assert cfg["tls"] == "none"


class TestCreateVLESSClient:
    """Тесты для создания VLESS клиентов"""
    
    @patch("infrastructure.external.xray_manager.uuid.uuid4", return_value=_FIXED_CLIENT_UUID)
    @patch.object(XrayManager, '_try_fast_path_return_config', return_value=None)
    @patch.object(XrayManager, '_update_xray_config')
    @patch.object(XrayManager, '_generate_vless_config_url')
    def test_create_vless_client(self, mock_generate_url, mock_update_config, _mock_fast, _mock_uuid,
                                  xray_manager: XrayManager, test_device: Device, test_server: Server):
        """Тест создания VLESS клиента"""
        mock_update_config.return_value = {"port": 4443, "settings": {"clients": []}}
        mock_generate_url.return_value = "vless://test-url"
        expected_uuid = str(_FIXED_CLIENT_UUID)
        
        result = xray_manager.create_vless_client(test_device, test_server)
        
        assert result['success'] is True
        assert 'client_id' in result
        assert 'config' in result
        assert 'uuid' in result
        assert result['config'] == "vless://test-url"
        assert result['uuid'] == expected_uuid
        assert result['ip_address'] == test_server.ip_address
        mock_update_config.assert_called_once()
        mock_generate_url.assert_called_with(expected_uuid, test_server, 4443)
    
    @patch("infrastructure.external.xray_manager.uuid.uuid4", return_value=_FIXED_CLIENT_UUID)
    @patch.object(XrayManager, '_try_fast_path_return_config', return_value=None)
    @patch.object(XrayManager, '_update_xray_config')
    @patch.object(XrayManager, '_generate_vless_config_url')
    def test_create_vless_client_existing_email(self, mock_generate_url, mock_update_config, _mock_fast, _mock_uuid,
                                                 xray_manager: XrayManager, test_device: Device, test_server: Server):
        """Тест создания VLESS клиента (ветка без fast-path; детали existing в update_fn не мокаются)."""
        mock_update_config.return_value = {"port": 4443, "settings": {"clients": []}}
        mock_generate_url.return_value = "vless://test-url"
        
        result = xray_manager.create_vless_client(test_device, test_server)
        
        assert result['success'] is True
        assert result['uuid'] == str(_FIXED_CLIENT_UUID)
        mock_update_config.assert_called_once()
    
    def test_create_vless_client_ssh_error(self, xray_manager: XrayManager,
                                            test_device: Device, test_server: Server):
        """Тест обработки ошибки SSH при создании VLESS клиента"""
        # Мокаем отсутствие RemoteVPNManager
        xray_manager.remote_manager = None
        
        result = xray_manager.create_vless_client(test_device, test_server)
        
        assert result['success'] is False
        assert 'error' in result


_VMess_UUID = uuid.UUID("aaaaaaaa-bbbb-cccc-dddd-111111111111")
_REALITY_UUID = uuid.UUID("aaaaaaaa-bbbb-cccc-dddd-222222222222")


class TestCreateVMESSClient:
    """Тесты для создания VMESS клиентов"""
    
    @patch("infrastructure.external.xray_manager.uuid.uuid4", return_value=_VMess_UUID)
    @patch.object(XrayManager, '_try_fast_path_return_config', return_value=None)
    @patch.object(XrayManager, '_update_xray_config')
    @patch.object(XrayManager, '_generate_vmess_config_url')
    def test_create_vmess_client(self, mock_generate_url, mock_update_config, _mock_fast, _mock_uuid,
                                  xray_manager: XrayManager, test_device: Device, test_server: Server):
        """Тест создания VMESS клиента"""
        mock_update_config.return_value = {"port": 8443, "settings": {"clients": []}}
        mock_generate_url.return_value = "vmess://test-url"
        expected_uuid = str(_VMess_UUID)
        
        result = xray_manager.create_vmess_client(test_device, test_server)
        
        assert result['success'] is True
        assert 'client_id' in result
        assert 'config' in result
        assert result['config'] == "vmess://test-url"
        assert result['uuid'] == expected_uuid
        assert result['ip_address'] == test_server.ip_address
        mock_update_config.assert_called_once()
        mock_generate_url.assert_called_with(expected_uuid, test_server, 8443)


class TestCreateREALITYClient:
    """Тесты для создания REALITY клиентов"""
    
    @patch.object(XrayManager, '_read_xray_config')
    @patch.object(XrayManager, '_reload_xray', return_value=True)
    @patch("infrastructure.external.xray_manager.uuid.uuid4", return_value=_REALITY_UUID)
    @patch.object(XrayManager, '_try_fast_path_return_config', return_value=None)
    @patch.object(XrayManager, '_update_xray_config')
    @patch.object(XrayManager, '_generate_reality_config_url')
    def test_create_reality_client(
        self,
        mock_generate_url,
        mock_update_config,
        _mock_fast,
        _mock_uuid,
        _mock_reload,
        mock_read_config,
        xray_manager: XrayManager,
        test_device: Device,
        test_server: Server,
    ):
        """Тест создания REALITY клиента"""
        expected_uuid = str(_REALITY_UUID)
        mock_update_config.return_value = {
            "port": 2053,
            "streamSettings": {"security": "reality"},
            "settings": {"clients": [{"id": expected_uuid}]},
        }
        mock_read_config.return_value = {
            "inbounds": [
                {
                    "protocol": "vless",
                    "port": 2053,
                    "streamSettings": {"security": "reality"},
                    "settings": {"clients": [{"id": expected_uuid, "email": "1_1@granivpn.com"}]},
                }
            ]
        }
        mock_generate_url.return_value = "vless://reality-url"
        
        result = xray_manager.create_reality_client(test_device, test_server)
        
        assert result['success'] is True
        assert 'client_id' in result
        assert 'config' in result
        assert result['config'] == "vless://reality-url"
        assert result['uuid'] == expected_uuid
        assert result['ip_address'] == test_server.ip_address
        mock_update_config.assert_called_once()
        mock_generate_url.assert_called_with(expected_uuid, test_server, 2053)


class TestRemoveClient:
    """Тесты для удаления клиентов"""
    
    @patch.object(XrayManager, '_reload_xray', return_value=True)
    @patch.object(XrayManager, '_update_xray_config')
    def test_remove_client(self, mock_update_config, _mock_reload, xray_manager: XrayManager, test_server: Server):
        """Тест удаления клиента"""
        xray_manager.server = test_server
        mock_update_config.return_value = True  # removed
        result = xray_manager.remove_client("vless_1_1")
        assert result is True
        mock_update_config.assert_called_once()
    
    @patch.object(XrayManager, '_reload_xray', return_value=True)
    @patch.object(XrayManager, '_update_xray_config')
    def test_remove_client_not_found(self, mock_update_config, _mock_reload, xray_manager: XrayManager, test_server: Server):
        """Тест удаления несуществующего клиента"""
        xray_manager.server = test_server
        mock_update_config.return_value = False  # not found
        result = xray_manager.remove_client("vless_999_999")
        assert result is False
        mock_update_config.assert_called_once()


class TestGetClientStats:
    """Тесты для получения статистики клиентов"""
    
    @patch.object(XrayManager, '_get_xray_stats_api')
    @patch.object(XrayManager, '_parse_client_email_from_client_id')
    def test_get_client_stats(self, mock_parse_email, mock_stats_api,
                               xray_manager: XrayManager, test_server: Server):
        """Тест получения статистики клиента"""
        client_id = "vless_1_1"
        mock_parse_email.return_value = "1_1@granivpn.com"
        mock_stats_api.side_effect = [
            {"stat": {"value": 1000}},
            {"stat": {"value": 2000}}
        ]
        
        stats = xray_manager.get_client_stats(client_id, test_server)
        
        assert stats is not None
        assert stats.get('uplink') == 1000
        assert stats.get('downlink') == 2000
    
    @patch.object(XrayManager, '_get_xray_stats_api')
    @patch.object(XrayManager, '_parse_client_email_from_client_id')
    def test_get_client_stats_error(self, mock_parse_email, mock_stats_api,
                                     xray_manager: XrayManager, test_server: Server):
        """Тест обработки ошибки при получении статистики"""
        mock_parse_email.return_value = "1_1@granivpn.com"
        mock_stats_api.return_value = None
        
        stats = xray_manager.get_client_stats("test_client", test_server)
        
        # Должен вернуть пустой словарь или словарь с ошибкой
        assert stats is not None


class TestGetServerStats:
    """Тесты для получения статистики сервера"""
    
    @patch.object(XrayManager, '_read_xray_config')
    @patch.object(XrayManager, '_get_xray_stats_api')
    def test_get_server_stats(self, mock_stats_api, mock_read,
                               xray_manager: XrayManager, test_server: Server):
        """Тест получения статистики сервера"""
        mock_stats_api.return_value = {
            "stat": [
                {"name": "user>>>user1@granivpn.com>>>uplink", "value": 1000},
                {"name": "user>>>user1@granivpn.com>>>downlink", "value": 2000}
            ]
        }
        mock_read.return_value = {"inbounds": [{"settings": {"clients": [{"id": "1"}]}}]}
        
        stats = xray_manager.get_server_stats(test_server)
        
        assert stats is not None
        assert 'total_uplink' in stats
        assert 'total_downlink' in stats
        assert 'total_clients' in stats


class TestCheckServerHealth:
    """Тесты для проверки здоровья сервера"""
    
    def test_check_server_health_ok(self, xray_manager: XrayManager, test_server: Server):
        """Тест проверки здоровья сервера (OK)"""
        mock_remote_manager = MagicMock()
        mock_ssh_manager = MagicMock()
        mock_remote_manager.ssh_manager = mock_ssh_manager
        xray_manager.remote_manager = mock_remote_manager
        mock_ssh_manager.execute_command.return_value = {"success": True, "stdout": "active", "stderr": ""}
        xray_manager._get_ssh_config = MagicMock(return_value={
            "host": "127.0.0.1",
            "port": 22,
            "username": "root",
            "key_path": None,
            "key_content": None,
            "password": None
        })
        
        health = xray_manager.check_server_health(test_server)
        
        assert health is not None
        assert 'status' in health or 'healthy' in str(health).lower() or 'ok' in str(health).lower()
    
    def test_check_server_health_error(self, xray_manager: XrayManager, test_server: Server):
        """Тест проверки здоровья сервера (ошибка)"""
        mock_remote_manager = MagicMock()
        mock_ssh_manager = MagicMock()
        mock_remote_manager.ssh_manager = mock_ssh_manager
        xray_manager.remote_manager = mock_remote_manager
        mock_ssh_manager.execute_command.side_effect = Exception("Connection error")
        xray_manager._get_ssh_config = MagicMock(return_value={
            "host": "127.0.0.1",
            "port": 22,
            "username": "root",
            "key_path": None,
            "key_content": None,
            "password": None
        })
        
        health = xray_manager.check_server_health(test_server)
        
        assert health is not None
        assert 'error' in health or 'status' in health


class TestApplyStatePipeline:
    """Тесты единого apply-state/ack pipeline."""

    @patch("infrastructure.external.xray_manager._try_enqueue_edge_apply")
    def test_apply_state_edge_when_no_celery(
        self,
        mock_try_edge,
        xray_manager: XrayManager,
        test_server: Server,
    ):
        mock_try_edge.return_value = "assign-123"

        state = xray_manager._apply_config_with_ack(
            test_server,
            {"inbounds": []},
            celery_ok=False,
        )

        assert state["status"] == "queued"
        assert state["ack_mode"] == "edge_assignment"
        assert state["apply_branch"] == "edge_no_celery"
        assert state["edge_assignment_id"] == "assign-123"
        assert state.get("config_revision")

    @patch("infrastructure.external.xray_manager._try_enqueue_edge_apply")
    @patch("services.tasks.vpn_tasks.apply_xray_config_to_vpn.delay")
    def test_apply_state_celery_async(
        self,
        mock_delay,
        mock_try_edge,
        xray_manager: XrayManager,
        test_server: Server,
    ):
        mock_try_edge.return_value = None
        mock_delay.return_value = Mock(id="task-abc")

        state = xray_manager._apply_config_with_ack(
            test_server,
            {"inbounds": [{"tag": "vless"}]},
            celery_ok=True,
        )

        assert state["status"] == "queued"
        assert state["ack_mode"] == "celery_task"
        assert state["apply_branch"] == "celery_async"
        assert state["celery_task_id"] == "task-abc"
        assert state.get("config_revision")


def test_commit_staged_config_applies_staged_payload(
    xray_manager: XrayManager,
    test_server: Server,
):
    staged_config = {"inbounds": [{"protocol": "vless"}]}
    xray_manager.set_staged_config(test_server, staged_config)
    with patch.object(XrayManager, "_apply_config_with_ack") as mock_apply:
        mock_apply.return_value = {
            "status": "queued",
            "ack_mode": "celery_task",
            "config_revision": "rev1",
        }
        result = xray_manager.commit_staged_config(test_server)
    assert result["status"] == "queued"
    assert result["apply_branch"] == "commit_staged"
    mock_apply.assert_called_once()


def test_commit_staged_config_noop_when_missing(
    xray_manager: XrayManager,
    test_server: Server,
):
    with patch.object(XrayManager, "get_staged_config", return_value=None):
        result = xray_manager.commit_staged_config(test_server)
    assert result["status"] == "noop"
    assert result["reason_code"] == "no_staged_config"


def test_vless_update_stage_only_sets_staged_apply_state(
    xray_manager: XrayManager,
    test_server: Server,
    monkeypatch,
):
    initial_config = {
        "inbounds": [
            {
                "protocol": "vless",
                "port": 4443,
                "settings": {"clients": []},
                "streamSettings": {"security": "none"},
            }
        ]
    }
    monkeypatch.setattr("infrastructure.external.xray_manager.settings.xray_prepare_stage_only", True)
    monkeypatch.setattr("infrastructure.external.xray_manager.settings.xray_prepare_apply_enabled", True)
    with patch.object(XrayManager, "_get_cached_xray_config", return_value=initial_config):
        with patch("infrastructure.external.xray_manager._is_celery_worker_available", return_value=True):
            with patch.object(XrayManager, "_apply_config_with_ack") as mock_apply:
                def _update_fn(config):
                    config["inbounds"][0]["settings"]["clients"].append(
                        {"id": "uuid-vless-1", "email": "1_1@granivpn.com"}
                    )
                    return config["inbounds"][0]

                _ = xray_manager._update_xray_config_async(test_server, _update_fn)

    apply_state = xray_manager.get_last_apply_state(test_server)
    staged = xray_manager.get_staged_config(test_server)
    assert apply_state is not None
    assert apply_state["status"] == "staged"
    assert apply_state["apply_branch"] == "prepare_stage_only"
    assert staged is not None
    assert staged["config_revision"] == apply_state["config_revision"]
    assert staged["config"]["inbounds"][0]["settings"]["clients"][0]["id"] == "uuid-vless-1"
    mock_apply.assert_not_called()


def test_vless_update_apply_enabled_runs_apply_pipeline(
    xray_manager: XrayManager,
    test_server: Server,
    monkeypatch,
):
    initial_config = {
        "inbounds": [
            {
                "protocol": "vless",
                "port": 4443,
                "settings": {"clients": []},
                "streamSettings": {"security": "none"},
            }
        ]
    }
    monkeypatch.setattr("infrastructure.external.xray_manager.settings.xray_prepare_stage_only", False)
    monkeypatch.setattr("infrastructure.external.xray_manager.settings.xray_prepare_apply_enabled", True)
    with patch.object(XrayManager, "_get_cached_xray_config", return_value=initial_config):
        with patch("infrastructure.external.xray_manager._is_celery_worker_available", return_value=True):
            with patch.object(XrayManager, "_apply_config_with_ack") as mock_apply:
                mock_apply.return_value = {
                    "status": "queued",
                    "ack_mode": "celery_task",
                    "apply_branch": "celery_async",
                    "config_revision": "rev-vless",
                    "config_sha256": "sha-vless",
                }

                def _update_fn(config):
                    config["inbounds"][0]["settings"]["clients"].append(
                        {"id": "uuid-vless-2", "email": "2_2@granivpn.com"}
                    )
                    return config["inbounds"][0]

                _ = xray_manager._update_xray_config_async(test_server, _update_fn)

    apply_state = xray_manager.get_last_apply_state(test_server)
    assert apply_state is not None
    assert apply_state["status"] == "queued"
    assert apply_state["ack_mode"] == "celery_task"
    assert apply_state["apply_branch"] == "celery_async"
    mock_apply.assert_called_once()
