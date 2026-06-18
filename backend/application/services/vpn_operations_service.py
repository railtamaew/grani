"""
Сервис для бизнес-логики VPN операций.
Только Xray: устройство + сервер -> конфиг. Без ConnectionOrchestrator/ConnectionMonitor.
"""
import hashlib
import json
import logging
import os
import time
import uuid
from dataclasses import dataclass
from typing import Dict, Any, Optional, List, Union
from datetime import datetime, timedelta
from sqlalchemy.orm import Session
from sqlalchemy import and_, func
from fastapi import HTTPException, status

from domain.models.user import User, Device
from domain.models.server import Server, ConnectionLog
from domain.models.edge_node_assignment import EdgeNodeAssignment
from core.config import settings
from core.error_types import AppException
from core.request_context import get_vpn_session_id
from application.services.device_manager import DeviceManager
from infrastructure.external.xray_manager import XrayManager
from infrastructure.external.wireguard_manager import WireGuardManager
from infrastructure.repositories.device_repository import DeviceRepository
from infrastructure.repositories.server_repository import ServerRepository
from infrastructure.repositories.user_vpn_connection_repository import UserVpnConnectionRepository
from domain.models.user_vpn_connection import UserVpnConnection
from application.services.trial_service import has_active_subscription

logger = logging.getLogger(__name__)


def _xray_json_config_revision(json_config: Optional[Dict[str, Any]]) -> str:
    """
    Стабильный отпечаток json_config для клиента (кэш, сравнение с локальным кэшем).
    Меняется при любом изменении полей конфига на сервере.
    """
    if not json_config:
        return ""
    try:
        blob = json.dumps(json_config, sort_keys=True, ensure_ascii=False).encode("utf-8")
        return "sha256:" + hashlib.sha256(blob).hexdigest()
    except Exception:
        return ""


def _active_config_hash_from_apply_state(apply_state: Optional[Dict[str, Any]]) -> str:
    if not apply_state or not isinstance(apply_state, dict):
        return ""
    return str(apply_state.get("config_sha256") or "")


def _node_health_from_apply_status(status_value: str) -> str:
    status_norm = (status_value or "").lower()
    if status_norm == "applied":
        return "healthy"
    if status_norm in {"failed", "error", "blocked", "stale"}:
        return "degraded"
    return "unknown"


def _normalize_protocol_name(protocol: str) -> str:
    if not protocol:
        return ""
    value = str(protocol).strip().lower()
    if value.startswith("xray_"):
        return value.replace("xray_", "", 1)
    return value


_XRAY_PROTOCOL_ALIASES = {
    "vless": "vless",
    "vmess": "vmess",
    "reality": "reality",
    "vless_ws_tls": "vless_ws_tls",
    "vless_grpc_tls": "vless_grpc_tls",
}


def _transport_overlay_for_protocol(protocol_normalized: str) -> Optional[Dict[str, Any]]:
    if protocol_normalized == "vless_ws_tls":
        return {
            "protocol": "vless",
            "port": 443,
            "net": "ws",
            "type": "none",
            "tls": "tls",
            "host": "api.granilink.com",
            "path": "/xray-vless-ws",
            "sni": "api.granilink.com",
        }
    if protocol_normalized == "vless_grpc_tls":
        return {
            "protocol": "vless",
            "port": 443,
            "net": "grpc",
            "type": "gun",
            "tls": "tls",
            "host": "api.granilink.com",
            "path": "xray-grpc",
            "sni": "api.granilink.com",
        }
    return None


def _safe_int(value: Any) -> Optional[int]:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _build_xray_runtime_contract(
    server: Server,
    protocol: str,
    json_config: Optional[Dict[str, Any]],
) -> Dict[str, Any]:
    protocol_normalized = _normalize_protocol_name(protocol)
    payload = json_config or {}
    payload_host = str(payload.get("add") or "")
    payload_port = _safe_int(payload.get("port"))
    payload_tls = str(payload.get("tls") or "")
    payload_sni = str(payload.get("sni") or "")
    payload_sid = str(payload.get("sid") or "")
    payload_pbk = str(payload.get("pbk") or "")
    payload_fp = str(payload.get("fp") or "")

    expected_port: Optional[int] = None
    expected_host: Optional[str] = None
    expected_tls: Optional[str] = None
    expected_sni: Optional[str] = None
    expected_sid: Optional[str] = None
    expected_pbk: Optional[str] = None
    expected_fp: Optional[str] = None

    if protocol_normalized == "reality":
        expected_host = str(getattr(server, "ip_address", "") or "")
        expected_port = int(getattr(server, "xray_port", 2053) or 2053)
        expected_tls = "reality"
        expected_sni = str(getattr(server, "reality_sni", None) or getattr(server, "reality_server_name", None) or "google.com")
        expected_sid = str(getattr(server, "reality_short_id", None) or "")
        expected_pbk = str(getattr(server, "reality_public_key", None) or "")
        expected_fp = "chrome"
    elif protocol_normalized == "vless":
        expected_host = str(getattr(server, "ip_address", "") or "")
        expected_port = 4443
        expected_tls = "none"
    elif protocol_normalized == "vmess":
        expected_host = str(getattr(server, "ip_address", "") or "")
        expected_port = 8443
        expected_tls = "none"
    elif protocol_normalized == "vless_ws_tls":
        expected_host = str(getattr(server, "ip_address", "") or "")
        expected_port = 443
        expected_tls = "tls"
        expected_sni = "api.granilink.com"
    elif protocol_normalized == "vless_grpc_tls":
        expected_host = str(getattr(server, "ip_address", "") or "")
        expected_port = 443
        expected_tls = "tls"
        expected_sni = "api.granilink.com"

    mismatches: Dict[str, bool] = {}
    if expected_host:
        mismatches["host"] = payload_host != expected_host
    if expected_port is not None:
        mismatches["port"] = payload_port != expected_port
    if expected_tls is not None:
        mismatches["tls"] = payload_tls != expected_tls
    if expected_sni is not None:
        mismatches["sni"] = payload_sni != expected_sni
    if expected_sid is not None:
        mismatches["sid"] = payload_sid != expected_sid
    if expected_pbk is not None:
        mismatches["pbk"] = payload_pbk != expected_pbk
    if expected_fp is not None:
        mismatches["fp"] = payload_fp != expected_fp

    mismatch_fields = sorted([name for name, flag in mismatches.items() if flag])
    return {
        "protocol": protocol_normalized,
        "server_expectation": {
            "host": getattr(server, "ip_address", ""),
            "port": expected_port,
            "tls": expected_tls,
            "sni": expected_sni,
            "sid": expected_sid,
            "pbk": expected_pbk,
            "fp": expected_fp,
        },
        "payload": {
            "host": payload.get("add"),
            "port": payload_port,
            "tls": payload_tls or None,
            "sni": payload_sni or None,
            "sid": payload_sid or None,
            "pbk": payload_pbk or None,
            "fp": payload_fp or None,
        },
        "mismatch_flags": mismatches,
        "mismatch_fields": mismatch_fields,
        "has_mismatch": bool(mismatch_fields),
    }


@dataclass
class ConnectionConfigView:
    """
    Представление соединения из user_vpn_connections для генерации конфига.
    Поддерживает duck typing с Device: vpn_client_id, current_server_id, vpn_protocol.
    Для WireGuard: connection_id, wireguard_public_key, wireguard_private_key, ip_address, protocol (wireguard/graniwg).
    """
    current_server_id: Optional[int]
    vpn_client_id: Optional[str] = None
    vpn_protocol: Optional[str] = None
    connection_id: Optional[str] = None
    wireguard_public_key: Optional[str] = None
    wireguard_private_key: Optional[str] = None
    ip_address: Optional[str] = None
    protocol: Optional[str] = None  # для WG: wireguard, graniwg


class VPNOperationsService:
    """Сервис для операций с VPN подключениями. Только Xray."""
    
    def __init__(
        self,
        db: Session,
        device_manager: DeviceManager,
    ):
        self.db = db
        self.device_manager = device_manager
        self.xray_manager = XrayManager()
        self.wireguard_manager = WireGuardManager()
        self.device_repo = DeviceRepository(db)
        self.server_repo = ServerRepository(db)
        self.connection_repo = UserVpnConnectionRepository(db)

    def _is_test_user(self, user: User) -> bool:
        email = getattr(user, 'email', None)
        return bool(email) and email in settings.test_user_emails
    
    def validate_and_get_device(
        self, 
        user: User, 
        device_id: str, 
        auto_register: bool = False,
        device_data: Optional[Dict[str, Any]] = None
    ) -> Device:
        """
        Валидация и получение устройства пользователя.
        
        Args:
            user: Пользователь
            device_id: ID устройства
            auto_register: Автоматически зарегистрировать, если не найдено
            device_data: Данные для регистрации (если auto_register=True)
        
        Returns:
            Device объект
        
        Raises:
            HTTPException: Если устройство не найдено и auto_register=False
        """
        device = self.device_repo.get_by_device_id(device_id, user.id)

        # Неактивная строка по этому device_id: новая запись для prepare/Xray (тот же UUID с клиента).
        if (
            device is not None
            and not getattr(device, "is_active", True)
            and auto_register
            and device_data
        ):
            merged = dict(device_data)
            if not (merged.get("fingerprint") or "").strip():
                fp_old = getattr(device, "device_fingerprint", None)
                if fp_old and str(fp_old).strip():
                    merged["fingerprint"] = str(fp_old).strip()
            logger.info(
                "Неактивное устройство по device_id, обновляем строку без INSERT дубля: user_id=%s row_id=%s device_id=%s",
                user.id,
                device.id,
                device_id,
            )
            try:
                device = self.device_manager.update_inactive_device_for_prepare(
                    user, device, merged
                )
            except AppException:
                raise
            except Exception as e:
                logger.error(
                    "Ошибка update_inactive_device_for_prepare: %s",
                    e,
                    exc_info=True,
                )
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=f"Не удалось зарегистрировать устройство для подключения: {str(e)}",
                ) from e
            return device
        
        if not device:
            if self._is_test_user(user):
                if not device_data:
                    device_data = {
                        'name': f"Test Device {device_id[:8]}",
                        'device_id': device_id,
                        'platform': 'test'
                    }
                logger.info(f"Test user bypass: авто-регистрация устройства: user_id={user.id}, device_id={device_id}")
                device = self.device_manager.register_device(user, device_data)
            elif auto_register and device_data:
                logger.info(f"Устройство не найдено, пытаемся зарегистрировать автоматически: user_id={user.id}, device_id={device_id}")
                try:
                    device = self.device_manager.register_device(user, device_data)
                    logger.info(f"Устройство автоматически зарегистрировано: device_id={device.id}, user_id={user.id}")
                except AppException:
                    raise  # Пробрасываем для general_exception_handler (сохраняет devices в ответе)
                except Exception as e:
                    logger.error(f"Ошибка автоматической регистрации устройства: {e}", exc_info=True)
                    raise HTTPException(
                        status_code=status.HTTP_400_BAD_REQUEST,
                        detail=f"Устройство не найдено и не удалось зарегистрировать автоматически. Пожалуйста, зарегистрируйте устройство через /vpn/device/register: {str(e)}"
                    )
            else:
                logger.warning(f"Устройство не найдено: user_id={user.id}, device_id={device_id}")
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail="Устройство не найдено"
                )
        
        logger.debug(f"Устройство найдено: device_id={device.id}, is_active={device.is_active}")
        return device
    
    def validate_and_get_server(self, server_id: int) -> Server:
        """
        Валидация и получение активного сервера.
        
        Args:
            server_id: ID сервера
        
        Returns:
            Server объект
        
        Raises:
            HTTPException: Если сервер не найден или неактивен
        """
        server = self.server_repo.get_active_by_id(server_id)
        
        if not server:
            logger.warning(f"Сервер не найден или неактивен: server_id={server_id}")
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Сервер не найден или неактивен. Пожалуйста, выберите другой сервер"
            )
        
        logger.debug(f"Сервер найден: server_id={server.id}, name={server.name}, is_active={server.is_active}")
        return server
    
    def normalize_protocol(self, protocol: str) -> str:
        """
        Нормализация протокола для проверки.
        
        Args:
            protocol: Протокол (может быть в формате xray_vless, vless, и т.д.)
        
        Returns:
            Нормализованный протокол
        """
        # Нормализуем Xray протоколы
        if protocol in ["vless", "vmess", "reality", "vless_ws_tls", "vless_grpc_tls"]:
            return f"xray_{protocol}"
        return protocol
    
    def get_supported_protocols(self, server: Server) -> List[str]:
        """
        Получение списка поддерживаемых протоколов сервера.
        
        Args:
            server: Сервер
        
        Returns:
            Список поддерживаемых протоколов
        """
        supported_protocols = server.supported_protocols or ["xray_vless"]
        if isinstance(supported_protocols, str):
            import json
            try:
                supported_protocols = json.loads(supported_protocols)
            except Exception:
                supported_protocols = ["xray_vless"]
        elif not isinstance(supported_protocols, list):
            supported_protocols = ["xray_vless"]
        protocols_set = set(supported_protocols) if isinstance(supported_protocols, list) else set(supported_protocols)
        if {"xray_vless", "xray_vmess", "xray_reality"} & protocols_set:
            protocols_set.add("xray_vless_ws_tls")
            protocols_set.add("xray_vless_grpc_tls")
        allowed_protocols = {
            "xray_vless",
            "xray_vmess",
            "xray_reality",
            "xray_vless_ws_tls",
            "xray_vless_grpc_tls",
            "graniwg",
        }
        filtered_protocols = [p for p in protocols_set if p in allowed_protocols]
        if not filtered_protocols:
            return ["xray_vless"]

        # Keep deterministic priority: VLESS first, REALITY as fallback.
        priority = [
            "xray_vless",
            "xray_vless_ws_tls",
            "xray_vless_grpc_tls",
            "xray_reality",
            "xray_vmess",
            "graniwg",
        ]
        ordered = [p for p in priority if p in filtered_protocols]
        tail = sorted([p for p in filtered_protocols if p not in ordered])
        return ordered + tail

    def validate_protocol_support(
        self, 
        server: Server, 
        protocol: str,
        allow_testing: bool = False
    ) -> None:
        """
        Валидация поддержки протокола сервером.
        
        Args:
            server: Сервер
            protocol: Протокол для проверки
            allow_testing: Разрешить подключение для тестирования даже если флаг не включен
        
        Raises:
            HTTPException: Если протокол не поддерживается
        """
        supported_protocols = self.get_supported_protocols(server)
        protocol_normalized = self.normalize_protocol(protocol)

        allowed = {
            "xray_vless",
            "xray_vmess",
            "xray_reality",
            "xray_vless_ws_tls",
            "xray_vless_grpc_tls",
            "graniwg",
        }
        if protocol_normalized not in allowed and protocol not in allowed:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Протокол временно отключен. Доступны: xray_reality, xray_vless, xray_vmess, xray_vless_ws_tls, xray_vless_grpc_tls, graniwg"
            )

        if allow_testing:
            return

        if protocol in ["xray_reality", "reality"] and not server.reality_enabled:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="REALITY не включен на этом сервере"
            )
        
        # Проверяем поддержку протокола
        if protocol_normalized not in supported_protocols:
            # Также проверяем альтернативные форматы
            alt_protocol = protocol.replace("xray_", "") if protocol.startswith("xray_") else f"xray_{protocol}"
            if alt_protocol not in supported_protocols and protocol not in supported_protocols:
                logger.warning(f"Сервер {server.id} не поддерживает протокол {protocol}. Поддерживаемые: {supported_protocols}")
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=f"Сервер не поддерживает протокол {protocol}. Доступные протоколы: {', '.join(supported_protocols)}"
                )
    
    def register_device(
        self, 
        user: User, 
        device_data: Dict[str, Any]
    ) -> Device:
        """
        Регистрация устройства пользователя.
        
        Args:
            user: Пользователь
            device_data: Данные устройства
        
        Returns:
            Зарегистрированное устройство
        """
        # Используем DeviceManager для регистрации устройства
        try:
            device = self.device_manager.register_device(user, device_data)
            logger.info(f"Устройство успешно зарегистрировано через DeviceManager: device_id={device.id}, user_id={user.id}")
            return device
        except Exception as e:
            logger.error(f"Ошибка регистрации устройства через DeviceManager: {e}", exc_info=True)
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Ошибка регистрации устройства: {str(e)}"
            )

    def resolve_device(
        self,
        user: User,
        fingerprint: str,
        name: Optional[str] = None,
        platform: Optional[str] = None,
    ) -> str:
        """
        Возвращает device_id по fingerprint (после переустановки/очистки).
        Если устройство с таким fingerprint уже есть — возвращает его device_id; иначе создаёт новое.
        """
        return self.device_manager.resolve_device(user, fingerprint, name=name, platform=platform)
    
    def connect_device(
        self,
        user: User,
        device: Device,
        server: Server,
        protocol: str
    ) -> Dict[str, Any]:
        """
        Подключение устройства к VPN серверу.
        Xray: создаёт Xray-клиента. GraniWG: создаёт WireGuard пир с обфускацией.
        """
        self.validate_protocol_support(server, protocol, allow_testing=self._is_test_user(user))
        if not self._is_test_user(user):
            if not has_active_subscription(user.id, self.db) and not getattr(user, "trial_active", False):
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail="Требуется активная подписка или триал",
                )
        protocol_normalized = self.normalize_xray_protocol(protocol)

        # Быстрый реконнект: если клиент уже создан для этого устройства/сервера/протокола,
        # не пересоздаём его, а переиспользуем существующий конфиг.
        existing_client_id = getattr(device, "vpn_client_id", None)
        existing_server_id = getattr(device, "current_server_id", None)
        existing_protocol = self.normalize_xray_protocol(getattr(device, "vpn_protocol", "") or "")
        is_xray_protocol = protocol_normalized in (
            "vless",
            "vmess",
            "reality",
            "vless_ws_tls",
            "vless_grpc_tls",
        )

        if is_xray_protocol and existing_client_id and existing_server_id == server.id and (
            not existing_protocol or existing_protocol == protocol_normalized
        ):
            logger.info(
                "Переиспользуем существующий Xray-клиент: user_id=%s device_id=%s client_id=%s server_id=%s protocol=%s",
                user.id,
                device.id,
                existing_client_id,
                server.id,
                protocol_normalized,
            )
            view = ConnectionConfigView(
                current_server_id=server.id,
                vpn_client_id=existing_client_id,
                vpn_protocol=protocol_normalized,
            )
            try:
                cfg = self.get_xray_config(user, view)
                if hasattr(device, "is_active"):
                    device.is_active = True
                if hasattr(device, "is_vpn_enabled"):
                    device.is_vpn_enabled = True
                if hasattr(device, "last_connected"):
                    device.last_connected = datetime.now()
                self.db.commit()
                return {
                    "success": True,
                    "ip_address": getattr(server, "ip_address", "") or "",
                    "config": cfg.get("config"),
                    "client_id": cfg.get("client_id"),
                    "json_config": cfg.get("json_config"),
                    "config_revision": cfg.get("config_revision") or _xray_json_config_revision(
                        cfg.get("json_config")
                    ),
                    "payload_fingerprint": cfg.get("config_revision") or _xray_json_config_revision(
                        cfg.get("json_config")
                    ),
                    "apply_state": cfg.get("apply_state"),
                    "apply_config_revision": (cfg.get("apply_state") or {}).get("config_revision"),
                    "apply_config_sha256": (cfg.get("apply_state") or {}).get("config_sha256"),
                    "active_config_hash": _active_config_hash_from_apply_state(cfg.get("apply_state")),
                    "server_info": {
                        "name": server.name,
                        "country": getattr(server, "country", ""),
                        "city": getattr(server, "city", ""),
                    },
                }
            except HTTPException as e:
                # Если клиент не найден на сервере, продолжаем обычным create-путём.
                if e.status_code != status.HTTP_404_NOT_FOUND:
                    raise
                logger.info(
                    "Существующий Xray-клиент не найден на сервере, создаём заново: device_id=%s client_id=%s",
                    device.id,
                    existing_client_id,
                )

        if device.is_active:
            # Для Xray делаем connect идемпотентным: не ломаем prewarm/повторные попытки
            # на "already connected", а допускаем восстановление/переcоздание клиента ниже.
            if is_xray_protocol:
                logger.info(
                    "Идемпотентный Xray connect для активного устройства: user_id=%s device_id=%s server_id=%s protocol=%s",
                    user.id,
                    device.id,
                    server.id,
                    protocol_normalized,
                )
            else:
                logger.warning(f"Попытка подключения уже подключенного устройства: device_id={device.id}")
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="Устройство уже подключено",
                )
        logger.info(f"Подключение устройства {device.id} к серверу {server.id} через протокол {protocol}")

        if protocol in ("graniwg", "wireguard"):
            return self._create_graniwg_connection(user, device, server, protocol)

        try:
            result = self.create_xray_client(user, device, server, protocol)
            client_ip = result.get("ip_address") or getattr(server, "ip_address", "")
            device.ip_address = client_ip
            device.last_connected = datetime.now()
            connection_log = ConnectionLog(
                user_id=user.id,
                device_id=device.id,
                server_id=server.id,
                connection_type="connect",
                ip_address=client_ip,
                connected_at=datetime.now(),
                vpn_session_id=get_vpn_session_id(),
            )
            self.db.add(connection_log)
            self.db.commit()
            try:
                from core.cache import invalidate_user_cache, cache_delete
                invalidate_user_cache(user.id)
                cache_delete(f"device_status:{device.id}")
            except Exception as cache_error:
                logger.warning(f"Не удалось инвалидировать кэш: {cache_error}")
            return {
                "success": True,
                "ip_address": client_ip,
                "config": result.get("config"),
                "client_id": result.get("client_id"),
                "json_config": result.get("json_config"),
                "config_revision": result.get("config_revision")
                or _xray_json_config_revision(result.get("json_config")),
                "payload_fingerprint": result.get("config_revision")
                or _xray_json_config_revision(result.get("json_config")),
                "apply_state": result.get("apply_state"),
                "apply_config_revision": (result.get("apply_state") or {}).get("config_revision"),
                "apply_config_sha256": (result.get("apply_state") or {}).get("config_sha256"),
                "active_config_hash": _active_config_hash_from_apply_state(result.get("apply_state")),
                "server_info": {
                    "name": server.name,
                    "country": getattr(server, "country", ""),
                    "city": getattr(server, "city", ""),
                },
            }
        except HTTPException:
            raise
        except Exception as e:
            self.db.rollback()
            logger.error(f"Ошибка подключения устройства {device.id}: {e}", exc_info=True)
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

    def _create_graniwg_connection(
        self,
        user: User,
        device: Device,
        server: Server,
        protocol: str
    ) -> Dict[str, Any]:
        """Создаёт подключение GraniWG (AmneziaWG): ключи, пир, конфиг."""
        wg = self.wireguard_manager
        if not server.wireguard_public_key:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Сервер не настроен для WireGuard/GraniWG",
            )
        if not device.wireguard_public_key or not device.wireguard_private_key:
            keys = wg.generate_key_pair(server)
            device.wireguard_public_key = keys.get("public_key")
            device.wireguard_private_key = keys.get("private_key")
            self.db.commit()
        client_ip = wg.get_next_available_ip(server)
        if not wg.add_peer_to_server(device, server, client_ip):
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Не удалось добавить пир на сервер",
            )
        config = wg.create_client_config(device, server, client_ip, protocol="graniwg")
        device.ip_address = client_ip
        device.current_server_id = server.id
        device.is_active = True
        if hasattr(device, "is_vpn_enabled"):
            device.is_vpn_enabled = True
        if hasattr(device, "vpn_protocol"):
            device.vpn_protocol = protocol
        device.last_connected = datetime.now()
        connection_log = ConnectionLog(
            user_id=user.id,
            device_id=device.id,
            server_id=server.id,
            connection_type="connect",
            ip_address=client_ip,
            connected_at=datetime.now(),
            vpn_session_id=get_vpn_session_id(),
        )
        self.db.add(connection_log)
        self.db.commit()
        try:
            from core.cache import invalidate_user_cache, cache_delete
            invalidate_user_cache(user.id)
            cache_delete(f"device_status:{device.id}")
        except Exception as cache_error:
            logger.warning(f"Не удалось инвалидировать кэш: {cache_error}")
        return {
            "success": True,
            "ip_address": client_ip,
            "config": config,
            "client_id": f"graniwg_{device.id}_{server.id}",
            "server_info": {
                "name": server.name,
                "country": getattr(server, "country", ""),
                "city": getattr(server, "city", ""),
            },
        }

    def disconnect_device(
        self,
        user: User,
        device: Device,
        force: bool = False
    ) -> Dict[str, Any]:
        """
        Отключение устройства от VPN. Только сброс состояния в БД (Xray-клиент на сервере не удаляем для быстрого реконнекта).
        """
        if not device.is_active:
            logger.info(f"Устройство {device.id} уже отключено")
            return {"message": "Устройство отключено", "force": force}
        server_id = device.current_server_id or 0
        server = self.db.query(Server).filter(Server.id == server_id).first() if server_id else None
        saved_ip = device.ip_address
        is_xray = bool(getattr(device, "vpn_client_id", None))
        try:
            device.is_active = False
            if hasattr(device, "is_vpn_enabled"):
                device.is_vpn_enabled = False
            if not is_xray:
                device.current_server_id = None
                if hasattr(device, "vpn_client_id"):
                    device.vpn_client_id = None
                if hasattr(device, "vpn_protocol"):
                    device.vpn_protocol = None
            self.db.commit()
            if server_id and server_id > 0:
                try:
                    last_connect = self.db.query(ConnectionLog).filter(
                        ConnectionLog.device_id == device.id,
                        ConnectionLog.server_id == server_id,
                        ConnectionLog.connection_type == "connect",
                        ConnectionLog.disconnected_at.is_(None),
                    ).order_by(ConnectionLog.connected_at.desc()).first()
                    if last_connect:
                        last_connect.disconnected_at = datetime.now()
                        if last_connect.connected_at:
                            last_connect.duration_seconds = int(
                                (last_connect.disconnected_at - last_connect.connected_at).total_seconds()
                            )
                        self.db.commit()
                    else:
                        log = ConnectionLog(
                            user_id=user.id,
                            device_id=device.id,
                            server_id=server_id,
                            connection_type="disconnect",
                            ip_address=saved_ip,
                            connected_at=datetime.now(),
                            disconnected_at=datetime.now(),
                            vpn_session_id=get_vpn_session_id(),
                        )
                        self.db.add(log)
                        self.db.commit()
                except Exception as log_err:
                    logger.warning(f"Не удалось обновить ConnectionLog: {log_err}")
                    try:
                        self.db.rollback()
                    except Exception:
                        pass
            try:
                from core.cache import invalidate_user_cache, cache_delete
                invalidate_user_cache(user.id)
                cache_delete(f"device_status:{device.id}")
            except Exception as cache_error:
                logger.warning(f"Не удалось инвалидировать кэш: {cache_error}")
            logger.info(f"Устройство {device.id} отключено в БД")
            return {"message": "Отключение выполнено", "force": force}
        except Exception as e:
            self.db.rollback()
            logger.error(f"Ошибка при отключении устройства {device.id}: {e}", exc_info=True)
            try:
                device.is_active = False
                if not is_xray:
                    device.current_server_id = None
                self.db.commit()
                return {"message": "Отключение выполнено (после ошибки)", "force": True}
            except Exception:
                raise HTTPException(
                    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                    detail=f"Ошибка отключения: {str(e)}",
                )

    def disconnect_by_client_id(
        self,
        user: User,
        client_id: str,
        force: bool = False,
    ) -> Dict[str, Any]:
        """
        Отключение по client_id (устройство или соединение из user_vpn_connections).
        Для соединения без устройства клиент на сервере не удаляется (быстрый реконнект).
        """
        device_or_view = self.get_device_by_client_id(user, client_id)
        if isinstance(device_or_view, Device):
            return self.disconnect_device(user, device_or_view, force=force)
        # ConnectionConfigView — соединение без устройства; на сервере не удаляем
        logger.info(f"Отключение по client_id (соединение без устройства): user_id={user.id}, client_id={client_id}")
        return {"message": "Отключено (соединение без устройства)", "force": False}

    def get_device_status(
        self,
        user: User,
        device: Device
    ) -> Dict[str, Any]:
        """
        Статус устройства по данным БД.

        Live-трафик через Xray Stats API на ноде (SSH + `xray api` к 127.0.0.1:10085) по умолчанию
        **отключён**: мобильный клиент сверяет только флаг `connected` (см. VpnService._syncConnectionState),
        а фоновый `/vpn/status` при этом не должен занимать десятки секунд. Подписка/trial — через `/auth/me`.

        Включить опрос stats (например, для отладки): `VPN_STATUS_REMOTE_XRAY_STATS=1`.
        """
        try:
            if not device.is_active:
                return {
                    "connected": False,
                    "ip_address": None,
                    "server": None,
                    "stats": None,
                    "connected_since": None,
                    "protocol": None,
                }
            server = None
            if device.current_server_id:
                server = self.db.query(Server).filter(Server.id == device.current_server_id).first()
            protocol = getattr(device, "vpn_protocol", None) or "reality"
            if isinstance(protocol, str) and protocol.startswith("xray_"):
                protocol = protocol.replace("xray_", "")
            stats = None
            remote_stats = os.getenv("VPN_STATUS_REMOTE_XRAY_STATS", "").lower() in (
                "1",
                "true",
                "yes",
            )
            if remote_stats and device.vpn_client_id and server:
                try:
                    xray_manager = XrayManager(server)
                    stats = xray_manager.get_client_stats(
                        device.vpn_client_id,
                        server,
                        stats_timeout_sec=2,
                        fast_fail=True,
                    )
                    if stats and "error" in stats:
                        stats = None
                except Exception as e:
                    logger.debug(f"Не удалось получить stats Xray для device {device.id}: {e}")
            return {
                "connected": True,
                "ip_address": device.ip_address,
                "server": {
                    "id": server.id,
                    "name": server.name,
                    "country": getattr(server, "country", ""),
                    "city": getattr(server, "city", ""),
                } if server else None,
                "stats": stats,
                "connected_since": device.last_connected.isoformat() if device.last_connected else None,
                "protocol": protocol,
            }
        except Exception as e:
            logger.error(f"Ошибка получения статуса: {e}", exc_info=True)
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=str(e),
            )

    def get_connection_stats(self, user: User, days: int = 7) -> Dict[str, Any]:
        """Статистика подключений пользователя за последние days дней."""
        try:
            since_date = datetime.now() - timedelta(days=days)
            daily_stats = self.db.query(
                func.date(ConnectionLog.connected_at).label("date"),
                func.count(ConnectionLog.id).label("connections"),
            ).filter(
                and_(
                    ConnectionLog.user_id == user.id,
                    ConnectionLog.connected_at >= since_date,
                )
            ).group_by(func.date(ConnectionLog.connected_at)).all()
            total_connections = self.db.query(ConnectionLog).filter(
                and_(
                    ConnectionLog.user_id == user.id,
                    ConnectionLog.connected_at >= since_date,
                )
            ).count()
            total_connection_time = (
                self.db.query(
                    func.sum(
                        func.extract("epoch", ConnectionLog.disconnected_at)
                        - func.extract("epoch", ConnectionLog.connected_at)
                    )
                )
                .filter(
                    and_(
                        ConnectionLog.user_id == user.id,
                        ConnectionLog.connection_type == "connect",
                        ConnectionLog.connected_at >= since_date,
                        ConnectionLog.disconnected_at.isnot(None),
                    )
                )
                .scalar()
                or 0
            )
            return {
                "period_days": days,
                "total_connections": total_connections,
                "total_connection_time_hours": round(total_connection_time / 3600, 2),
                "daily_stats": [
                    {"date": stat.date.isoformat(), "connections": stat.connections}
                    for stat in daily_stats
                ],
            }
        except Exception as e:
            logger.error(f"Ошибка получения статистики: {e}", exc_info=True)
            return {"error": str(e)}

    def get_system_stats(self) -> Dict[str, Any]:
        """Системная статистика (для админки)."""
        try:
            total_users = self.db.query(User).count()
            total_devices = self.db.query(Device).count()
            active_devices = self.db.query(Device).filter(Device.is_active == True).count()
            total_connections = self.db.query(ConnectionLog).count()
            last_24h = datetime.now() - timedelta(hours=24)
            connections_24h = self.db.query(ConnectionLog).filter(
                ConnectionLog.connected_at >= last_24h
            ).count()
            return {
                "wireguard_status": "deprecated",
                "total_users": total_users,
                "total_devices": total_devices,
                "active_devices": active_devices,
                "total_connections": total_connections,
                "connections_24h": connections_24h,
                "timestamp": datetime.now().isoformat(),
            }
        except Exception as e:
            logger.error(f"Ошибка системной статистики: {e}", exc_info=True)
            return {"error": str(e)}

    def cleanup_inactive_connections(self) -> int:
        """Сброс is_active для устройств, не подключавшихся более часа. Xray client_id не трогаем."""
        try:
            inactive_devices = self.db.query(Device).filter(
                and_(
                    Device.is_active == True,
                    Device.last_connected.isnot(None),
                    Device.last_connected < datetime.now() - timedelta(hours=1),
                )
            ).all()
            cleaned_count = 0
            for device in inactive_devices:
                device.is_active = False
                device.current_server_id = None
                cleaned_count += 1
            self.db.commit()
            logger.info(f"Очищено {cleaned_count} неактивных подключений")
            return cleaned_count
        except Exception as e:
            self.db.rollback()
            logger.error(f"Ошибка очистки неактивных подключений: {e}", exc_info=True)
            return 0

    def normalize_xray_protocol(self, protocol: str) -> str:
        """
        Нормализация Xray протокола.
        
        Args:
            protocol: Протокол (может быть в формате xray_vless, vless, и т.д.)
        
        Returns:
            Нормализованный протокол без префикса xray_
        """
        value = str(protocol or "").strip().lower()
        if value.startswith("xray_"):
            value = value.replace("xray_", "")
        return _XRAY_PROTOCOL_ALIASES.get(value, value)
    
    def get_device_by_client_id(
        self,
        user: User,
        client_id: str
    ) -> Union[Device, ConnectionConfigView]:
        """
        Получение устройства или соединения по client_id.
        Сначала поиск в devices по vpn_client_id, затем в user_vpn_connections по vpn_client_id или connection_id.
        
        Returns:
            Device или ConnectionConfigView (для конфига из user_vpn_connections).
        
        Raises:
            HTTPException: Если ни устройство, ни соединение не найдены.
        """
        device = self.device_repo.get_by_client_id(client_id, user.id)
        if device:
            return device

        connection = self.connection_repo.get_by_client_or_connection_id(client_id, user.id)
        if connection:
            return ConnectionConfigView(
                current_server_id=connection.server_id,
                vpn_client_id=connection.vpn_client_id,
                vpn_protocol=connection.vpn_protocol,
                connection_id=connection.connection_id,
                wireguard_public_key=connection.wireguard_public_key,
                wireguard_private_key=connection.wireguard_private_key,
                ip_address=connection.ip_address,
                protocol=connection.protocol,
            )

        logger.warning(f"Клиент не найден по client_id: user_id={user.id}, client_id={client_id}")
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Клиент не найден"
        )

    def get_or_create_connection(
        self,
        user: User,
        server: Server,
        protocol: str,
    ) -> Dict[str, Any]:
        """
        Единый алгоритм: получить или создать соединение по (user, server, protocol).
        Для XRay: один клиент на тройку; для WireGuard/GRANIWG: один пир на тройку.
        Возвращает тот же формат, что и connect: success, config, client_id, server_info, ip_address.
        """
        if not self._is_test_user(user):
            if not has_active_subscription(user.id, self.db) and not getattr(user, "trial_active", False):
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail="Требуется активная подписка или триал",
                )

        supported = self.get_supported_protocols(server)
        protocol_check = protocol if protocol.startswith("xray_") else f"xray_{protocol}"
        if protocol_check not in supported and protocol not in supported:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Сервер не поддерживает протокол {protocol}. Доступные: {', '.join(supported)}",
            )

        connection = self.connection_repo.get_by_user_server_protocol(user.id, server.id, protocol)
        if not connection:
            connection = self.connection_repo.create(
                user_id=user.id,
                server_id=server.id,
                protocol=protocol,
            )
            self.db.refresh(connection)

        protocol_normalized = self.normalize_xray_protocol(protocol) if protocol.startswith("xray_") else protocol

        # ---- XRay ----
        if protocol_normalized in (
            "vless",
            "vmess",
            "reality",
            "vless_ws_tls",
            "vless_grpc_tls",
        ):
            if connection.vpn_client_id:
                view = ConnectionConfigView(
                    current_server_id=connection.server_id,
                    vpn_client_id=connection.vpn_client_id,
                    vpn_protocol=connection.vpn_protocol,
                )
                try:
                    cfg = self.get_xray_config(user, view)
                    return {
                        "success": True,
                        "ip_address": getattr(server, "ip_address", None) or "",
                        "config": cfg.get("config"),
                        "client_id": cfg.get("client_id"),
                        "server_info": cfg.get("server", {}),
                        "json_config": cfg.get("json_config"),
                        "config_revision": cfg.get("config_revision")
                        or _xray_json_config_revision(cfg.get("json_config")),
                        "payload_fingerprint": cfg.get("config_revision")
                        or _xray_json_config_revision(cfg.get("json_config")),
                        "apply_state": cfg.get("apply_state"),
                        "apply_config_revision": (cfg.get("apply_state") or {}).get("config_revision"),
                        "apply_config_sha256": (cfg.get("apply_state") or {}).get("config_sha256"),
                        "active_config_hash": _active_config_hash_from_apply_state(cfg.get("apply_state")),
                        "correlation_id": (
                            str(get_vpn_session_id() or "")
                            or str(cfg.get("config_revision") or "")
                            or str(cfg.get("client_id") or "")
                        ),
                        "runtime_contract": _build_xray_runtime_contract(
                            server=server,
                            protocol=protocol_normalized,
                            json_config=cfg.get("json_config"),
                        ),
                    }
                except HTTPException as e:
                    if e.status_code == status.HTTP_404_NOT_FOUND:
                        logger.info("get_xray_config 404, клиент не найден на сервере, создаём нового")
                    else:
                        raise
            result = self.create_xray_client(user, connection, server, protocol)
            return {
                "success": result.get("success", True),
                "ip_address": result.get("ip_address", ""),
                "config": result.get("config"),
                "client_id": result.get("client_id"),
                "server_info": {"name": server.name, "country": getattr(server, "country", ""), "city": getattr(server, "city", "")},
                "json_config": result.get("json_config"),
                "config_revision": result.get("config_revision")
                or _xray_json_config_revision(result.get("json_config")),
                "payload_fingerprint": result.get("config_revision")
                or _xray_json_config_revision(result.get("json_config")),
                "apply_state": result.get("apply_state"),
                "apply_config_revision": (result.get("apply_state") or {}).get("config_revision"),
                "apply_config_sha256": (result.get("apply_state") or {}).get("config_sha256"),
                "active_config_hash": _active_config_hash_from_apply_state(result.get("apply_state")),
                "correlation_id": (
                    str(result.get("correlation_id") or "")
                    or str(get_vpn_session_id() or "")
                    or str(result.get("config_revision") or "")
                    or str(result.get("client_id") or "")
                ),
                "runtime_contract": result.get("runtime_contract") or _build_xray_runtime_contract(
                    server=server,
                    protocol=protocol_normalized,
                    json_config=result.get("json_config"),
                ),
            }

        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Неподдерживаемый протокол: {protocol}. Используйте xray_reality, xray_vless, xray_vmess, xray_vless_ws_tls, xray_vless_grpc_tls"
        )

    def get_existing_connection_config(
        self,
        user: User,
        server: Server,
        protocol: str,
        device_id: Optional[str] = None,
        device_fingerprint: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        Read-only выдача существующего Xray конфига без мутаций.
        Ничего не создает и не применяет на ноде.
        """
        protocol_normalized = self.normalize_xray_protocol(protocol)
        if protocol_normalized not in (
            "vless",
            "vmess",
            "reality",
            "vless_ws_tls",
            "vless_grpc_tls",
        ):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Поддерживаются только xray_reality, xray_vless, xray_vmess, xray_vless_ws_tls, xray_vless_grpc_tls",
            )

        if device_id and device_id.strip():
            normalized_device_id = device_id.strip()
            device_data = {
                "name": f"Device {normalized_device_id[:8]}",
                "device_id": normalized_device_id,
                "platform": "unknown",
            }
            if device_fingerprint and str(device_fingerprint).strip():
                device_data["fingerprint"] = str(device_fingerprint).strip()
            device = self.validate_and_get_device(
                user,
                normalized_device_id,
                auto_register=True,
                device_data=device_data,
            )
            if not getattr(device, "vpn_client_id", None):
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Нет существующего клиента для устройства. Используйте create-client/connect.",
                )
            if getattr(device, "current_server_id", None) != server.id:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Существующий клиент устройства привязан к другому серверу.",
                )
            existing_protocol = self.normalize_xray_protocol(
                getattr(device, "vpn_protocol", "") or ""
            )
            if existing_protocol and existing_protocol != protocol_normalized:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Существующий клиент устройства использует другой протокол.",
                )
            view: Union[Device, ConnectionConfigView] = device
        else:
            connection = self.connection_repo.get_by_user_server_protocol(
                user.id, server.id, protocol
            )
            if not connection or not connection.vpn_client_id:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Нет существующего клиента. Используйте create-client/connect.",
                )
            view = ConnectionConfigView(
                current_server_id=connection.server_id,
                vpn_client_id=connection.vpn_client_id,
                vpn_protocol=connection.vpn_protocol,
            )

        cfg = self.get_xray_config(user, view)
        apply_state = self.xray_manager.get_last_apply_state(server)
        runtime_contract = _build_xray_runtime_contract(
            server=server,
            protocol=protocol_normalized,
            json_config=cfg.get("json_config"),
        )
        return {
            "success": True,
            "ip_address": getattr(server, "ip_address", None) or "",
            "config": cfg.get("config"),
            "client_id": cfg.get("client_id"),
            "server_info": cfg.get("server", {}),
            "json_config": cfg.get("json_config"),
            "config_revision": cfg.get("config_revision")
            or _xray_json_config_revision(cfg.get("json_config")),
            "payload_fingerprint": cfg.get("config_revision")
            or _xray_json_config_revision(cfg.get("json_config")),
            "apply_state": apply_state,
            "apply_config_revision": (apply_state or {}).get("config_revision"),
            "apply_config_sha256": (apply_state or {}).get("config_sha256"),
            "active_config_hash": _active_config_hash_from_apply_state(apply_state),
            "correlation_id": (
                str(get_vpn_session_id() or "")
                or str(cfg.get("config_revision") or "")
                or str(cfg.get("client_id") or "")
            ),
            "runtime_contract": runtime_contract,
        }

    def _require_apply_confirmed(
        self,
        user: User,
        server: Server,
        apply_state: Optional[Dict[str, Any]],
        config_revision: str,
    ) -> None:
        """
        Для connect/create-client требуем подтвержденный apply.
        Если apply не подтвержден за таймаут — отдаем ошибку, чтобы UI не показывал connected.
        """
        if not config_revision:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Не удалось определить ревизию конфига для проверки apply.",
            )

        status_now = str((apply_state or {}).get("status") or "").lower()
        if status_now == "applied":
            return
        if status_now in {"failed", "error", "blocked"}:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail=f"Apply неуспешен: status={status_now}",
            )

        timeout_sec = max(1, int(getattr(settings, "xray_connect_apply_timeout_sec", 12) or 12))
        deadline = time.monotonic() + timeout_sec
        last_status = status_now or "unknown"
        while time.monotonic() < deadline:
            state = self.get_xray_apply_state(user, server.id, config_revision)
            last_status = str(state.get("status") or "unknown").lower()
            if state.get("is_applied"):
                return
            if last_status in {"failed", "error", "blocked"}:
                break
            time.sleep(0.25)

        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={
                "message": f"Apply не подтвержден за {timeout_sec}s (status={last_status})",
                "status": last_status,
                "phase": "await_apply_confirmation",
                "node_health": _node_health_from_apply_status(last_status),
                "retry_after": 3,
            },
        )

    def create_xray_client(
        self,
        user: User,
        device: Device,
        server: Server,
        protocol: str
    ) -> Dict[str, Any]:
        """
        Создание Xray клиента для устройства.
        
        Args:
            user: Пользователь
            device: Устройство
            server: Сервер
            protocol: Протокол (vless, vmess, reality)
        
        Returns:
            Результат создания клиента
        """
        # Нормализуем протокол
        protocol_normalized = self.normalize_xray_protocol(protocol)
        
        # Проверяем поддержку протокола
        supported_protocols = self.get_supported_protocols(server)
        protocol_check = (
            f"xray_{protocol_normalized}"
            if protocol_normalized in ["vless", "vmess", "reality", "vless_ws_tls", "vless_grpc_tls"]
            else protocol_normalized
        )
        
        if protocol_check not in supported_protocols:
            alt_protocols = [protocol_normalized, f"xray_{protocol_normalized}"]
            if not any(p in supported_protocols for p in alt_protocols):
                logger.warning(f"Сервер {server.id} не поддерживает протокол {protocol}. Поддерживаемые: {supported_protocols}")
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=f"Сервер не поддерживает протокол {protocol}. Доступные протоколы: {', '.join(supported_protocols)}"
                )
        
        # Для REALITY проверяем, что он включен на сервере
        if protocol_normalized == "reality" and not server.reality_enabled:
            logger.warning(f"REALITY запрошен, но не включен на сервере {server.id}")
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="REALITY не включен на этом сервере"
            )
        
        logger.info(f"Создание Xray клиента: user_id={user.id}, device_id={device.id}, server_id={server.id}, protocol={protocol_normalized}")
        _t0 = time.monotonic()

        # Xray create_client используется в идемпотентном connect-потоке:
        # активное устройство не блокируем, чтобы prewarm/reconnect не падали на 400.
        if getattr(device, "is_active", False):
            logger.info(
                "create-client for active device (idempotent path): device_id=%s user_id=%s server_id=%s",
                device.id,
                user.id,
                server.id,
            )
        
        # Создаем клиента в зависимости от протокола
        if protocol_normalized in {"vless", "vless_ws_tls", "vless_grpc_tls"}:
            result = self.xray_manager.create_vless_client(device, server)
        elif protocol_normalized == "vmess":
            result = self.xray_manager.create_vmess_client(device, server)
        elif protocol_normalized == "reality":
            result = self.xray_manager.create_reality_client(device, server)
        else:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Неподдерживаемый протокол: {protocol_normalized}. Поддерживаются: vless, vmess, reality, vless_ws_tls, vless_grpc_tls"
            )
        _t_remote = time.monotonic()
        logger.info(
            "create_xray_client stage=remote_ssh_xray user_id=%s server_id=%s protocol=%s elapsed_ms=%s",
            user.id,
            server.id,
            protocol_normalized,
            int((_t_remote - _t0) * 1000),
        )

        if not result.get("success"):
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"Ошибка создания Xray клиента: {result.get('error') or 'unknown error'}"
            )

        # Глобально только одна активная строка на device_id (ux_devices_device_id_active).
        did = getattr(device, "device_id", None)
        if did and getattr(device, "id", None) is not None:
            self.db.query(Device).filter(
                Device.device_id == did,
                Device.id != device.id,
                Device.is_active == True,
            ).update(
                {
                    Device.is_active: False,
                    Device.current_server_id: None,
                    Device.ip_address: None,
                    Device.vpn_protocol: None,
                    Device.vpn_client_id: None,
                },
                synchronize_session=False,
            )
        
        # Обновляем информацию об устройстве или user_vpn_connection
        if hasattr(device, "vpn_protocol"):
            device.vpn_protocol = protocol_normalized
        if hasattr(device, "vpn_client_id"):
            device.vpn_client_id = result.get("client_id")
        if hasattr(device, "is_vpn_enabled"):
            device.is_vpn_enabled = True
        if hasattr(device, "is_active"):
            device.is_active = True
        if hasattr(device, "current_server_id"):
            device.current_server_id = server.id
        self.db.commit()
        
        logger.info(f"Xray клиент успешно создан: client_id={result.get('client_id')}, protocol={protocol_normalized}")
        
        # Генерируем JSON конфигурацию для мобильного приложения
        json_config = None
        try:
            client_id = result.get('client_id')
            if client_id:
                json_config = self.xray_manager._generate_client_json_config(
                    client_id,
                    server,
                    "vless" if protocol_normalized in {"vless_ws_tls", "vless_grpc_tls"} else protocol_normalized,
                    uuid_str=result.get("uuid")
                )
                overlay = _transport_overlay_for_protocol(protocol_normalized)
                if json_config and overlay:
                    json_config = {**json_config, **overlay}
                logger.info(f"JSON конфигурация сгенерирована для клиента {client_id}")
        except Exception as e:
            logger.warning(f"Не удалось сгенерировать JSON конфигурацию: {e}")

        if json_config:
            self._validate_xray_json_config(json_config, protocol_normalized)

        if not result.get("config") and not json_config:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Сервер не вернул конфигурацию для Xray клиента"
            )
        _t_done = time.monotonic()
        logger.info(
            "create_xray_client stage=after_json user_id=%s server_id=%s json_build_ms=%s total_ms=%s",
            user.id,
            server.id,
            int((_t_done - _t_remote) * 1000),
            int((_t_done - _t0) * 1000),
        )

        response = {
            "success": True,
            "client_id": result.get('client_id'),
            "config": result.get('config'),
            "json_config": json_config,
            "config_revision": _xray_json_config_revision(json_config),
            "payload_fingerprint": _xray_json_config_revision(json_config),
            "apply_state": result.get("apply_state"),
            "apply_config_revision": (result.get("apply_state") or {}).get("config_revision"),
            "apply_config_sha256": (result.get("apply_state") or {}).get("config_sha256"),
            "active_config_hash": _active_config_hash_from_apply_state(result.get("apply_state")),
            "protocol": protocol_normalized,
            "server_name": server.name,
            "ip_address": result.get('ip_address', server.ip_address),
            "message": "Xray клиент успешно создан"
        }
        response["correlation_id"] = (
            str(get_vpn_session_id() or "")
            or str(response.get("config_revision") or "")
            or str(response.get("client_id") or "")
        )
        response["runtime_contract"] = _build_xray_runtime_contract(
            server=server,
            protocol=protocol_normalized,
            json_config=json_config,
        )
        apply_required = bool(result.get("apply_required", True))
        response["apply_required"] = apply_required
        require_apply_confirmed = bool(
            getattr(settings, "xray_connect_require_apply_confirmed", False)
        )
        if apply_required and require_apply_confirmed:
            self._require_apply_confirmed(
                user=user,
                server=server,
                apply_state=response.get("apply_state"),
                config_revision=str(response.get("apply_config_revision") or response.get("config_revision") or ""),
            )
            response["phase"] = "applied"
            response["node_health"] = "healthy"
            response["retry_after"] = 0
        elif not apply_required:
            # Идемпотентный fast-path: клиент и конфиг уже существуют, mutation/apply не запускались.
            response["phase"] = "applied_cached"
            response["node_health"] = "healthy"
            response["retry_after"] = 0
        else:
            status_now = str((response.get("apply_state") or {}).get("status") or "").lower()
            if status_now == "applied":
                response["phase"] = "applied"
                response["node_health"] = "healthy"
                response["retry_after"] = 0
            elif status_now in {"failed", "error", "blocked"}:
                response["phase"] = "failed"
                response["node_health"] = "degraded"
                response["retry_after"] = 2
            else:
                # Неблокирующий hot path: apply идет асинхронно, клиент может дополливать apply-state.
                response["phase"] = "await_apply_confirmation"
                response["node_health"] = "unknown"
                response["retry_after"] = 2
        return response

    def get_xray_apply_state(
        self,
        user: User,
        server_id: int,
        config_revision: str,
    ) -> Dict[str, Any]:
        """
        Возвращает состояние применения Xray-конфига по revision для мобильного ACK-поллинга.
        """
        if not config_revision or not config_revision.strip():
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="config_revision обязателен",
            )

        server = self.validate_and_get_server(server_id)
        apply_state = self.xray_manager.get_last_apply_state(server) or {}
        requested_revision = config_revision.strip()

        state_revision = str(apply_state.get("config_revision") or "")
        state_sha256 = str(apply_state.get("config_sha256") or "")
        matched = bool(
            state_revision and (
                state_revision == requested_revision
                or state_sha256 == requested_revision
                or state_sha256.startswith(requested_revision)
            )
        )

        response: Dict[str, Any] = {
            "server_id": server.id,
            "requested_config_revision": requested_revision,
            "matched": matched,
            "is_applied": False,
            "apply_state": apply_state or None,
            "partial_ack_state": None,
            "pending_reason": None,
            "pending_flags": [],
        }

        if not matched:
            response["status"] = "unknown"
            return response

        status_value = str(apply_state.get("status") or "unknown")
        ack_mode = str(apply_state.get("ack_mode") or "none")
        reason_code = str(apply_state.get("reason_code") or "")
        edge_assignment_id = apply_state.get("edge_assignment_id")
        edge_row: Optional[EdgeNodeAssignment] = None

        if ack_mode == "edge_assignment" and edge_assignment_id:
            edge_row = (
                self.db.query(EdgeNodeAssignment)
                .filter(
                    EdgeNodeAssignment.id == edge_assignment_id,
                    EdgeNodeAssignment.server_id == server.id,
                )
                .first()
            )
            if edge_row:
                response["edge_assignment"] = {
                    "id": edge_row.id,
                    "status": edge_row.status,
                    "result_status": edge_row.result_status,
                    "result_message": edge_row.result_message,
                    "applied_config_hash": edge_row.applied_config_hash,
                    "completed_at": edge_row.completed_at.isoformat() + "Z" if edge_row.completed_at else None,
                }
                if edge_row.status == "pending":
                    status_value = "queued"
                elif edge_row.status == "dispatched":
                    # Keep API status stable for mobile polling: "queued" + reason_code.
                    status_value = "queued"
                elif edge_row.status == "applying":
                    status_value = "applying"
                elif edge_row.status == "completed" and edge_row.result_status == "ok":
                    status_value = "applied"
                elif edge_row.status in {"failed", "cancelled"} or edge_row.result_status in {"error", "failed"}:
                    status_value = "failed"
                else:
                    status_value = "stale"

        from services.edge_enqueue import count_active_xray_sessions_for_server

        active_xray = count_active_xray_sessions_for_server(self.db, server.id)
        response["active_xray_sessions"] = active_xray
        if edge_row is not None:
            if edge_row.status == "pending" and active_xray > 0:
                response["reason_code"] = "deferred_active_sessions"
            elif edge_row.status == "dispatched":
                response["reason_code"] = "node_applying_config"
        elif reason_code:
            response["reason_code"] = reason_code

        response["status"] = status_value
        if status_value == "applied" and ack_mode != "edge_assignment":
            # Guard against false-positive apply: dataplane must be active and listening.
            runtime_ready = self.xray_manager.check_server_runtime_ready(server)
            response["runtime_ready"] = runtime_ready
            if not runtime_ready.get("ready"):
                status_value = "failed"
                response["status"] = status_value
                response["reason_code"] = "dataplane_not_ready_after_apply"
                response["runtime_guard_reason"] = runtime_ready.get("reason")
                response["missing_ports"] = runtime_ready.get("missing_ports") or []

        response["is_applied"] = status_value == "applied"
        response["phase"] = (
            "await_apply_confirmation"
            if status_value in {"queued", "dispatched", "applying"}
            else "applied"
            if status_value == "applied"
            else "failed"
        )
        response["node_health"] = _node_health_from_apply_status(status_value)
        response["retry_after"] = 2 if status_value in {"queued", "dispatched", "applying"} else 0
        if status_value in {"queued", "dispatched", "applying"}:
            pending_flags: List[str] = ["apply_not_confirmed"]
            reason = str(response.get("reason_code") or "").strip().lower()
            if reason:
                pending_flags.append(f"reason:{reason}")
            if active_xray > 0:
                pending_flags.append("active_sessions_present")
            response["partial_ack_state"] = "committed_dataplane"
            response["pending_reason"] = reason or "await_apply_confirmation"
            response["pending_flags"] = pending_flags
        elif status_value == "applied":
            response["partial_ack_state"] = "applied"
            response["pending_reason"] = None
            response["pending_flags"] = []
        else:
            response["partial_ack_state"] = "failed"
            response["pending_reason"] = str(response.get("reason_code") or "apply_failed")
            response["pending_flags"] = ["apply_failed"]
        return response
    
    def delete_xray_client(
        self,
        user: User,
        device_or_view: Union[Device, ConnectionConfigView]
    ) -> Dict[str, Any]:
        """
        Удаление Xray клиента.
        
        Args:
            user: Пользователь
            device_or_view: Устройство или представление соединения с клиентом
        
        Returns:
            Результат удаления
        """
        client_id = getattr(device_or_view, "vpn_client_id", None)
        if not client_id:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Устройство не имеет активного Xray клиента"
            )

        # Удаляем клиента из Xray (нужен сервер для SSH операции)
        server = None
        server_id = getattr(device_or_view, "current_server_id", None)
        if server_id:
            server = self.db.query(Server).filter(Server.id == server_id).first()

        if server:
            xray_manager = XrayManager(server)
            success = xray_manager.remove_client(client_id)
            if not success:
                raise HTTPException(
                    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                    detail="Ошибка удаления клиента"
                )
        else:
            logger.warning(
                "Не удалось определить сервер для удаления клиента: user_id=%s, client_id=%s",
                user.id,
                client_id,
            )

        if isinstance(device_or_view, Device):
            # Обновляем информацию об устройстве
            device_or_view.vpn_client_id = None
            device_or_view.vpn_protocol = None
            if hasattr(device_or_view, 'is_vpn_enabled'):
                device_or_view.is_vpn_enabled = False
            device_or_view.is_active = False
            device_or_view.current_server_id = None
            self.db.commit()
            logger.info("Xray клиент успешно удален: device_id=%s", device_or_view.id)
        else:
            # Для соединений без device_id очищаем запись user_vpn_connections
            connection = self.connection_repo.get_by_client_or_connection_id(client_id, user.id)
            if connection:
                connection.vpn_client_id = None
                connection.vpn_protocol = None
                self.db.commit()
                logger.info(
                    "Xray клиент успешно удален: connection_id=%s user_id=%s",
                    connection.id,
                    user.id,
                )
            else:
                logger.info(
                    "Xray клиент уже отсутствует в user_vpn_connections: client_id=%s user_id=%s",
                    client_id,
                    user.id,
                )
        
        return {
            "success": True,
            "message": "Xray клиент успешно удален"
        }
    
    def get_xray_config(
        self,
        user: User,
        device: Device
    ) -> Dict[str, Any]:
        """
        Получение конфигурации Xray клиента.
        
        Args:
            user: Пользователь
            device: Устройство с клиентом
        
        Returns:
            Конфигурация клиента
        """
        if not device.vpn_client_id:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Устройство не имеет активного Xray клиента"
            )
        
        # Получаем сервер
        server = None
        if device.current_server_id:
            server = self.server_repo.get_active_by_id(device.current_server_id)
        
        if not server:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Сервер не найден"
            )
        
        # Горячий путь: не делаем двойное чтение server config.
        # Раньше _generate_client_config() и _generate_client_json_config() вызывались подряд,
        # и каждый мог ходить в SSH/конфиг. Сначала строим json_config один раз.
        json_config = None
        try:
            protocol_for_config = self.normalize_xray_protocol(device.vpn_protocol)
            json_config = self.xray_manager._generate_client_json_config(
                device.vpn_client_id, server, protocol_for_config
            )
            overlay = _transport_overlay_for_protocol(protocol_for_config)
            if json_config and overlay:
                json_config = {**json_config, **overlay}
        except Exception as e:
            logger.warning("get_xray_config: не удалось сгенерировать json_config: %s", e)
        if json_config is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Xray клиент не найден на сервере. Выполните create-client для повторного подключения."
            )
        protocol_normalized = self.normalize_xray_protocol(device.vpn_protocol)
        uuid_value = str(json_config.get("id") or device.vpn_client_id)
        port_raw = json_config.get("port")
        try:
            port = int(port_raw)
        except (TypeError, ValueError):
            port = None
        if protocol_normalized == "reality":
            config = self.xray_manager._generate_reality_config_url(
                uuid_value,
                server,
                port=port,
            )
        elif protocol_normalized == "vmess":
            config = self.xray_manager._generate_vmess_config_url(
                uuid_value,
                server,
                port=port,
            )
        elif protocol_normalized == "vless_ws_tls":
            config = (
                f"vless://{uuid_value}@{server.ip_address}:443?"
                "security=tls&type=ws&host=api.granilink.com&path=%2Fxray-vless-ws&sni=api.granilink.com#GRANI-WS-TLS"
            )
        elif protocol_normalized == "vless_grpc_tls":
            config = (
                f"vless://{uuid_value}@{server.ip_address}:443?"
                "security=tls&type=grpc&serviceName=xray-grpc&sni=api.granilink.com#GRANI-gRPC-TLS"
            )
        else:
            config = self.xray_manager._generate_vless_config_url(
                uuid_value,
                server,
                port=port,
            )
        return {
            "client_id": device.vpn_client_id,
            "config": config,
            "json_config": json_config,
            "config_revision": _xray_json_config_revision(json_config),
            "protocol": device.vpn_protocol,
            "server": {
                "name": server.name,
                "country": server.country,
                "ip": server.ip_address
            }
        }

    def get_wireguard_config(
        self,
        user: User,
        view: ConnectionConfigView,
    ) -> Dict[str, Any]:
        """WireGuard/GRANIWG удалены — всегда 400."""
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Поддерживаются только xray_reality, xray_vless, xray_vmess, xray_vless_ws_tls, xray_vless_grpc_tls",
        )

    def get_xray_stats(
        self,
        server: Optional[Server] = None
    ) -> Dict[str, Any]:
        """
        Получение статистики Xray сервера.
        
        Args:
            server: Сервер (если None, берется первый активный)
        
        Returns:
            Статистика сервера
        """
        if not server:
            server = self.server_repo.get_first_active()
        
        if not server:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Активные серверы не найдены"
            )
        
        stats = self.xray_manager.get_server_stats(server)
        
        if 'error' in stats:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=stats['error']
            )
        
        return {
            "total_uplink": stats.get('total_uplink', 0),
            "total_downlink": stats.get('total_downlink', 0),
            "active_clients": stats.get('active_clients', 0),
            "total_clients": stats.get('total_clients', 0),
            "timestamp": stats.get('timestamp', ''),
            "protocol": "xray",
            "server_id": server.id,
            "server_name": server.name
        }

    def _validate_xray_json_config(self, json_config: Dict[str, Any], protocol: str) -> None:
        if not isinstance(json_config, dict):
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Невалидная JSON конфигурация Xray"
            )

        address = json_config.get("add")
        client_id = json_config.get("id")
        port_value = json_config.get("port")

        if not isinstance(address, str) or not address.strip():
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="JSON конфигурация Xray не содержит адрес сервера"
            )

        if not isinstance(client_id, str) or not client_id.strip():
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="JSON конфигурация Xray не содержит client id"
            )

        try:
            port = int(port_value)
        except (TypeError, ValueError):
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="JSON конфигурация Xray содержит невалидный порт"
            )

        if port <= 0:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="JSON конфигурация Xray содержит невалидный порт"
            )

        if protocol == "reality":
            if json_config.get("tls") != "reality":
                raise HTTPException(
                    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                    detail="JSON конфигурация Xray для REALITY не содержит tls=reality"
                )
            if not json_config.get("pbk"):
                raise HTTPException(
                    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                    detail="JSON конфигурация Xray для REALITY не содержит public key"
                )
    
    def get_xray_client_stats(
        self,
        user: User,
        device: Device
    ) -> Dict[str, Any]:
        """
        Получение статистики конкретного Xray клиента.
        
        Args:
            user: Пользователь
            device: Устройство с клиентом
        
        Returns:
            Статистика клиента
        """
        if not device.vpn_client_id:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Устройство не имеет активного Xray клиента"
            )
        
        # Получаем сервер
        server = None
        if device.current_server_id:
            server = self.server_repo.get_active_by_id(device.current_server_id)
        
        if not server:
            server = self.server_repo.get_first_active()
        
        if not server:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Сервер не найден"
            )
        
        stats = self.xray_manager.get_client_stats(device.vpn_client_id, server)
        
        if 'error' in stats:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=stats['error']
            )
        
        return {
            "client_id": device.vpn_client_id,
            "stats": stats,
            "timestamp": datetime.now().isoformat()
        }
