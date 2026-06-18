from datetime import datetime, timedelta
import base64
import hashlib
import json
import threading
import logging
import os
import uuid
import shlex
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel
from sqlalchemy import text
from sqlalchemy.orm import Session

from core.database import get_db
from models.client_log import ClientLog
from models.server import Server
from models.user import Device
from services.wireguard_manager import WireGuardManager
from services.remote_vpn_manager import RemoteVPNManager
from services.auth_service import AuthService
from services.trial_service import get_user_access_info
from services.simple_vpn_entitlement import ensure_device_server_peers_entitlement_columns, suspend_user_graniwg_access

router = APIRouter(prefix='/api/simple-vpn', tags=['simple-vpn'])
security = HTTPBearer()
logger = logging.getLogger(__name__)

_SIMPLE_CLIENT_LOG_EVENT_MAP = {
    'connect_tap': 'connection_start',
    'native_start_ok': 'connection_success',
    'vpn_data_verified': 'traffic_first_seen',
    'node_data_verified': 'traffic_first_seen',
    'client_runtime_verified': 'connection_success',
    'client_runtime_unverified': 'connection_error',
    'node_data_verify_failed': 'connection_error',
    'node_data_unverified': 'connection_error',
    'connect_failed': 'connection_error',
    'disconnect_ok': 'connection_end',
    'disconnect_failed': 'connection_error',
    'access_required_disconnect': 'connection_error',
}

# MVP invariant: this module must not call the legacy VPN operations pipeline.
# It only authenticates, returns a static Xray profile, and records simple events.
_session_state: Dict[str, Dict[str, Any]] = {}
_provision_locks: Dict[str, threading.Lock] = {}
_provision_locks_guard = threading.Lock()


class SimpleVpnConfigResponse(BaseModel):
    success: bool
    protocol: str
    config_type: str = 'xray'
    engine: str = 'xray'
    server: Dict[str, Any]
    config: str
    json_config: Dict[str, Any]
    config_revision: str
    message: str


class SimpleVpnStartRequest(BaseModel):
    device_id: Optional[str] = None
    protocol: Optional[str] = None
    server_id: Optional[int] = None


class SimpleVpnStartResponse(BaseModel):
    success: bool
    session_id: str
    status: str


class SimpleVpnStopRequest(BaseModel):
    device_id: Optional[str] = None
    session_id: Optional[str] = None
    reason: Optional[str] = None


class SimpleVpnStatusResponse(BaseModel):
    success: bool
    status: str
    session_id: Optional[str] = None
    updated_at: Optional[str] = None


class SimpleVpnVerifyRequest(BaseModel):
    device_id: Optional[str] = None
    session_id: Optional[str] = None
    server_id: Optional[int] = None
    protocol: Optional[str] = None


class SimpleVpnVerifyResponse(BaseModel):
    success: bool
    verified: bool
    status: str
    server_id: Optional[int] = None
    vpn_ip: Optional[str] = None
    handshake_age_sec: Optional[int] = None
    rx_bytes: Optional[int] = None
    tx_bytes: Optional[int] = None
    reason: Optional[str] = None
    details: Dict[str, Any] = {}


class SimpleVpnLogRequest(BaseModel):
    device_id: Optional[str] = None
    session_id: Optional[str] = None
    event: str
    level: str = 'info'
    details: Optional[Dict[str, Any]] = None


class SimpleVpnLogResponse(BaseModel):
    success: bool


class SimpleVpnProtocolResponse(BaseModel):
    success: bool
    default_protocol: str
    protocols: List[Dict[str, Any]]


class SimpleVpnServersResponse(BaseModel):
    success: bool
    default_server_id: Optional[int] = None
    servers: List[Dict[str, Any]]


def _current_user(credentials: HTTPAuthorizationCredentials, db: Session):
    return AuthService.get_current_user(credentials.credentials, db)


def _assert_access(user_id: int, db: Session) -> None:
    trial_seconds_left, has_active_subscription = get_user_access_info(user_id, db)
    if trial_seconds_left <= 0 and not has_active_subscription:
        try:
            suspend_user_graniwg_access(db, user_id, reason='access_check_failed')
            db.commit()
        except Exception:
            db.rollback()
            logger.exception('simple-vpn: failed to suspend access for user_id=%s', user_id)
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail='Нет активного VPN-доступа',
        )


def _simple_key(user_id: int, device_id: Optional[str]) -> str:
    value = (device_id or 'default').strip() or 'default'
    return f'{user_id}:{value}'


def _provision_lock_key(user_id: int, device_id: Optional[str]) -> str:
    return _simple_key(user_id, device_id)


def _get_provision_lock(user_id: int, device_id: Optional[str]) -> threading.Lock:
    key = _provision_lock_key(user_id, device_id)
    with _provision_locks_guard:
        lock = _provision_locks.get(key)
        if lock is None:
            lock = threading.Lock()
            _provision_locks[key] = lock
        return lock


def _ensure_device_server_peers_table(db: Session) -> None:
    ensure_device_server_peers_entitlement_columns(db)


def _get_prepared_peer(db: Session, device: Device, server: Server) -> Optional[Dict[str, Any]]:
    _ensure_device_server_peers_table(db)
    row = db.execute(
        text("""
            SELECT id, device_id, server_id, protocol, public_key, vpn_ip, preshared_key,
                   config_revision, revoked_at, suspended_at, suspend_reason
            FROM device_server_peers
            WHERE device_id = :device_id
              AND server_id = :server_id
              AND protocol = 'graniwg'
              AND revoked_at IS NULL
            LIMIT 1
        """),
        {'device_id': device.id, 'server_id': server.id},
    ).mappings().first()
    return dict(row) if row else None


def _upsert_prepared_peer(
    db: Session,
    device: Device,
    server: Server,
    client_ip: str,
    revision: str,
    preshared_key: Optional[str] = None,
) -> None:
    _ensure_device_server_peers_table(db)
    db.execute(
        text("""
            INSERT INTO device_server_peers
                (device_id, server_id, protocol, public_key, vpn_ip, preshared_key, config_revision, created_at, updated_at, last_used_at)
            VALUES
                (:device_id, :server_id, 'graniwg', :public_key, :vpn_ip, :preshared_key, :revision, NOW(), NOW(), NOW())
            ON CONFLICT (device_id, server_id, protocol)
            DO UPDATE SET
                public_key = EXCLUDED.public_key,
                vpn_ip = EXCLUDED.vpn_ip,
                preshared_key = EXCLUDED.preshared_key,
                config_revision = EXCLUDED.config_revision,
                updated_at = NOW(),
                last_used_at = NOW(),
                revoked_at = NULL,
                suspended_at = NULL,
                suspend_reason = NULL
        """),
        {
            'device_id': device.id,
            'server_id': server.id,
            'public_key': device.wireguard_public_key,
            'vpn_ip': client_ip,
            'preshared_key': preshared_key,
            'revision': revision,
        },
    )


def _touch_prepared_peer(db: Session, peer_id: int) -> None:
    db.execute(
        text("""
            UPDATE device_server_peers
            SET last_used_at = NOW(), updated_at = NOW()
            WHERE id = :peer_id
        """),
        {'peer_id': peer_id},
    )


def _server_requires_graniwg_psk(server: Server) -> bool:
    try:
        specs = server.get_server_specs()
    except Exception:
        specs = {}
    raw = (specs or {}).get('graniwg_use_preshared_key')
    if isinstance(raw, bool):
        return raw
    if raw is None:
        return False
    return str(raw).strip().lower() in {'1', 'true', 'yes', 'on'}


def _generate_graniwg_preshared_key() -> str:
    return base64.b64encode(os.urandom(32)).decode('ascii')


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        return int(raw)
    except ValueError:
        logger.warning('simple-vpn: invalid integer env %s=%r, using %s', name, raw, default)
        return default


def _pick_server(db: Session, server_id: Optional[int] = None) -> Server:
    default_id = _env_int('SIMPLE_VPN_SERVER_ID', 1)
    selected_id = server_id or default_id
    server = db.query(Server).filter(Server.id == selected_id, Server.is_active == True).first()  # noqa: E712
    if server is None and server_id is not None and selected_id != default_id:
        logger.warning(
            'simple-vpn: requested server_id=%s is unavailable, falling back to default server_id=%s',
            selected_id,
            default_id,
        )
        server = db.query(Server).filter(Server.id == default_id, Server.is_active == True).first()  # noqa: E712
    if server is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f'Simple VPN server {selected_id} is not available',
        )
    return server


def _server_supported_simple_protocols(server: Server) -> List[str]:
    supported: List[str] = []
    try:
        raw = server.get_supported_protocols()
    except Exception:
        raw = server.supported_protocols or []
    if isinstance(raw, str):
        raw = [raw]
    if isinstance(raw, list):
        supported = [str(item).strip() for item in raw if str(item).strip()]
    ordered = ['vless_ws', 'hysteria2', 'graniwg']
    return [protocol for protocol in ordered if protocol in supported]


_SERVER_LOCATION_FALLBACKS: Dict[str, Dict[str, Any]] = {
    '13.140.9.211': {
        'country_code': 'SE',
        'city_code': 'STO',
        'country_localized': {'ru': 'Швеция', 'en': 'Sweden'},
        'city_localized': {'ru': 'Стокгольм', 'en': 'Stockholm'},
    },
    '81.27.101.191': {
        'country_code': 'PL',
        'city_code': 'WAW',
        'country_localized': {'ru': 'Польша', 'en': 'Poland'},
        'city_localized': {'ru': 'Варшава', 'en': 'Warsaw'},
    },
    '213.163.206.79': {
        'country_code': 'SG',
        'city_code': 'SIN',
        'country_localized': {'ru': 'Сингапур', 'en': 'Singapore'},
        'city_localized': {'ru': 'Сингапур', 'en': 'Singapore'},
    },
    '85.9.193.3': {
        'country_code': 'US',
        'city_code': 'NYC',
        'country_localized': {'ru': 'США', 'en': 'United States'},
        'city_localized': {'ru': 'Нью-Йорк', 'en': 'New York City'},
    },
}


def _locale_map(raw: Any, fallback: str = '') -> Dict[str, str]:
    if isinstance(raw, dict):
        result = {
            str(key).lower(): str(value)
            for key, value in raw.items()
            if value is not None and str(value).strip()
        }
        if result:
            return result
    fallback = str(fallback or '')
    return {'ru': fallback, 'en': fallback} if fallback else {}


def _server_location_metadata(server: Server) -> Dict[str, Any]:
    try:
        specs = server.get_server_specs()
    except Exception:
        specs = {}
    specs = specs or {}
    fallback = _SERVER_LOCATION_FALLBACKS.get(server.ip_address or '', {})

    country_localized = dict(fallback.get('country_localized') or {})
    country_localized.update(_locale_map(
        specs.get('country_localized')
        or specs.get('country_labels')
        or specs.get('localized_country')
    ))
    if not country_localized:
        country_localized = _locale_map(None, server.country or '')

    city_localized = dict(fallback.get('city_localized') or {})
    city_localized.update(_locale_map(
        specs.get('city_localized')
        or specs.get('city_labels')
        or specs.get('localized_city')
    ))
    if not city_localized:
        city_localized = _locale_map(None, server.city or '')

    return {
        'country_code': (
            specs.get('country_code')
            or specs.get('location_country_code')
            or fallback.get('country_code')
            or ''
        ),
        'city_code': (
            specs.get('city_code')
            or specs.get('location_city_code')
            or fallback.get('city_code')
            or ''
        ),
        'country_localized': country_localized,
        'city_localized': city_localized,
    }


def _simple_server_payload(server: Server) -> Dict[str, Any]:
    supported = _server_supported_simple_protocols(server)
    if not supported and server.graniwg_enabled:
        supported = ['graniwg']
    location = _server_location_metadata(server)
    return {
        'id': server.id,
        'name': server.name,
        'country': server.country,
        'city': server.city,
        'country_code': location['country_code'],
        'city_code': location['city_code'],
        'country_localized': location['country_localized'],
        'city_localized': location['city_localized'],
        'ip_address': server.ip_address,
        'wireguard_port': server.wireguard_port,
        'current_users': server.current_users or 0,
        'max_users': server.max_users or 100,
        'ping_ms': server.ping_ms,
        'graniwg_enabled': bool(server.graniwg_enabled),
        'supported_protocols': supported,
    }



def _parse_wg_dump(stdout: str, public_key: str) -> Optional[Dict[str, Any]]:
    for raw_line in (stdout or '').splitlines():
        parts = raw_line.strip().split('\t')
        if len(parts) < 8:
            continue
        if parts[0] != public_key:
            continue
        allowed_ips = parts[3]
        try:
            latest_handshake = int(parts[4])
        except (TypeError, ValueError):
            latest_handshake = 0
        try:
            rx_bytes = int(parts[5])
        except (TypeError, ValueError):
            rx_bytes = 0
        try:
            tx_bytes = int(parts[6])
        except (TypeError, ValueError):
            tx_bytes = 0
        age = int(datetime.utcnow().timestamp()) - latest_handshake if latest_handshake > 0 else None
        return {
            'public_key': parts[0],
            'endpoint': parts[2],
            'allowed_ips': allowed_ips,
            'latest_handshake': latest_handshake,
            'handshake_age_sec': age,
            'rx_bytes': rx_bytes,
            'tx_bytes': tx_bytes,
            'persistent_keepalive': parts[7],
        }
    return None


def _verify_graniwg_node_traffic(server: Server, public_key: str, expected_vpn_ip: str) -> Dict[str, Any]:
    if not public_key:
        return {'verified': False, 'reason': 'missing_public_key'}
    if not expected_vpn_ip:
        return {'verified': False, 'reason': 'missing_vpn_ip'}

    rm = RemoteVPNManager()
    if not getattr(rm, 'ssh_manager', None):
        return {'verified': False, 'reason': 'ssh_manager_unavailable'}
    cfg = rm.get_ssh_config(server)
    if not cfg:
        return {'verified': False, 'reason': 'ssh_config_unavailable'}

    command = (
        'if command -v awg >/dev/null 2>&1; then '
        'awg show wg0 dump; '
        'else wg show wg0 dump; fi '
        '| grep -F -- ' + shlex.quote(public_key) + ' || true'
    )
    result = rm.ssh_manager.execute_command(
        cfg['host'],
        command,
        cfg['port'],
        cfg['username'],
        cfg.get('key_path'),
        cfg.get('key_content'),
        cfg.get('password'),
    )
    stdout = result.get('stdout') or ''
    if not result.get('success'):
        return {'verified': False, 'reason': 'node_command_failed', 'ssh_error': result.get('stderr')}
    peer = _parse_wg_dump(stdout, public_key)
    if not peer:
        return {'verified': False, 'reason': 'peer_not_found'}

    expected_allowed = f'{expected_vpn_ip}/32'
    allowed_ok = expected_allowed in str(peer.get('allowed_ips') or '').split(',')
    handshake_age = peer.get('handshake_age_sec')
    handshake_ok = isinstance(handshake_age, int) and handshake_age <= 60
    traffic_ok = int(peer.get('rx_bytes') or 0) > 0 and int(peer.get('tx_bytes') or 0) > 0
    verified = bool(allowed_ok and handshake_ok and traffic_ok)
    reason = None
    if not verified:
        if not allowed_ok:
            reason = 'allowed_ip_mismatch'
        elif not handshake_ok:
            reason = 'stale_or_missing_handshake'
        elif not traffic_ok:
            reason = 'traffic_counters_empty'
    return {
        'verified': verified,
        'reason': reason,
        'expected_allowed_ip': expected_allowed,
        **peer,
    }



def _runtime_allowed_ip_from_verify(details: Dict[str, Any]) -> Optional[str]:
    allowed = str(details.get('allowed_ips') or '').strip()
    if not allowed:
        return None
    parts = [p.strip() for p in allowed.split(',') if p.strip()]
    if len(parts) != 1:
        return None
    value = parts[0]
    if not value.endswith('/32'):
        return None
    ip = value[:-3].strip()
    return ip or None


def _reconcile_prepared_peer_with_runtime(
    db: Session,
    device: Device,
    server: Server,
    prepared: Dict[str, Any],
) -> Dict[str, Any]:
    client_ip = str(prepared.get('vpn_ip') or '').strip()
    details = _verify_graniwg_node_traffic(
        server,
        device.wireguard_public_key or '',
        client_ip,
    )
    if details.get('reason') != 'allowed_ip_mismatch':
        return prepared

    runtime_ip = _runtime_allowed_ip_from_verify(details)
    if not runtime_ip or runtime_ip == client_ip:
        return prepared

    revision = (
        f'simple-vpn:{server.id}:amneziawg:device:{device.id}:{runtime_ip}'
        f':reconciled:{int(datetime.utcnow().timestamp())}'
    )
    _upsert_prepared_peer(db, device, server, runtime_ip, revision)
    db.commit()
    reconciled = _get_prepared_peer(db, device, server) or dict(prepared)
    logger.warning(
        'simple-vpn prepared peer reconciled user_id=%s device_pk=%s server_id=%s old_vpn_ip=%s runtime_vpn_ip=%s reason=%s',
        device.user_id,
        device.wireguard_public_key,
        server.id,
        client_ip,
        runtime_ip,
        details.get('reason'),
    )
    return reconciled


def _restore_prepared_peer_if_missing(
    db: Session,
    wg: WireGuardManager,
    device: Device,
    server: Server,
    prepared: Dict[str, Any],
    revision: str,
    preshared_key: Optional[str] = None,
) -> bool:
    client_ip = str(prepared.get('vpn_ip') or '').strip()
    details = _verify_graniwg_node_traffic(
        server,
        device.wireguard_public_key or '',
        client_ip,
    )
    if details.get('reason') != 'peer_not_found':
        return False

    logger.warning(
        'simple-vpn prepared peer missing on node; restoring user_id=%s device_pk=%s server_id=%s vpn_ip=%s',
        device.user_id,
        device.wireguard_public_key,
        server.id,
        client_ip,
    )
    if not wg.add_peer_to_server(device, server, client_ip, preshared_key=preshared_key):
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail='Failed to restore missing AmneziaWG peer on server',
        )
    _upsert_prepared_peer(db, device, server, client_ip, revision, preshared_key=preshared_key)
    return True


def _simple_xray_profile(server: Server, protocol: Optional[str] = None) -> Dict[str, Any]:
    protocol = (protocol or os.environ.get('SIMPLE_VPN_PROTOCOL', 'vless_ws')).strip() or 'vless_ws'
    if protocol not in {'vless_ws', 'xray_vless', 'xray_vmess', 'xray_reality'}:
        raise HTTPException(status_code=500, detail=f'Unsupported SIMPLE_VPN_PROTOCOL={protocol}')

    if protocol == 'vless_ws':
        default_port = 8080
        xray_protocol = 'vless'
        security = 'none'
        network = 'ws'
    elif protocol == 'xray_vmess':
        default_port = 8443
        xray_protocol = 'vmess'
        security = 'none'
        network = 'tcp'
    elif protocol == 'xray_reality':
        default_port = 2053
        xray_protocol = 'vless'
        security = 'reality'
        network = 'tcp'
    else:
        default_port = 4443
        xray_protocol = 'vless'
        security = 'none'
        network = 'tcp'

    address = os.environ.get('SIMPLE_VPN_ADDRESS') or server.ip_address
    port_default = default_port if protocol == 'vless_ws' else int(server.xray_port or default_port)
    port = _env_int('SIMPLE_VPN_PORT', port_default)
    try:
        server_specs = server.get_server_specs()
    except Exception:
        server_specs = {}
    client_id = os.environ.get('SIMPLE_VPN_CLIENT_ID') or (
        server_specs.get('vless_ws_client_id')
        or server_specs.get('simple_vless_ws_client_id')
        or server_specs.get('xray_client_id')
        or ''
    )
    if not client_id:
        client_id = (
            'b7f4087a-5eb5-4d5e-8d05-1d5ff93447a0'
            if protocol == 'vless_ws'
            else '31343a66-e3b5-41e3-99df-cd901f8e052b'
        )
    remark = os.environ.get('SIMPLE_VPN_REMARK') or (
        f'GRANI-{server.city or server.name}-VLESS-WS'
        if protocol == 'vless_ws'
        else f'GRANI Simple {server.name}'
    )
    ws_path = os.environ.get('SIMPLE_VLESS_WS_PATH') or '/grani-ws'

    json_config: Dict[str, Any] = {
        'ps': remark,
        'add': address,
        'port': str(port),
        'id': client_id,
        'aid': '0',
        'scy': 'none',
        'net': network,
        'type': 'none',
        'host': address if protocol == 'vless_ws' else '',
        'path': ws_path if protocol == 'vless_ws' else '',
        'tls': security,
        'sni': '',
        'alpn': '',
        'protocol': xray_protocol,
    }

    if protocol == 'xray_vmess':
        json_config['v'] = '2'
    if protocol == 'xray_reality':
        json_config['pbk'] = os.environ.get('SIMPLE_VPN_REALITY_PUBLIC_KEY') or server.reality_public_key or ''
        json_config['sid'] = os.environ.get('SIMPLE_VPN_REALITY_SHORT_ID') or server.reality_short_id or ''
        json_config['sni'] = os.environ.get('SIMPLE_VPN_REALITY_SNI') or server.reality_sni or server.reality_server_name or ''
        json_config['fp'] = os.environ.get('SIMPLE_VPN_REALITY_FP') or 'chrome'
        json_config['spx'] = os.environ.get('SIMPLE_VPN_REALITY_SPX') or '/'

    if protocol == 'vless_ws':
        query = f'type=ws&security=none&path={ws_path}&encryption=none'
    else:
        query = f'security={security}&type={network}'
    config = f'{xray_protocol}://{client_id}@{address}:{port}?{query}#{remark}'
    return {
        'protocol': protocol,
        'config_type': 'xray',
        'engine': 'xray',
        'config': config,
        'json_config': json_config,
        'revision': f'simple-vpn:{server.id}:{protocol}:{address}:{port}',
    }


def _simple_hysteria2_defaults(server: Server) -> Dict[str, str]:
    try:
        server_specs = server.get_server_specs()
    except Exception:
        server_specs = {}
    server_specs = server_specs or {}
    spec_domain = (
        server_specs.get('hysteria2_domain')
        or server_specs.get('hy2_domain')
        or server_specs.get('simple_hysteria2_domain')
    )
    spec_password = (
        server_specs.get('hysteria2_password')
        or server_specs.get('hy2_password')
        or server_specs.get('simple_hysteria2_password')
        or os.environ.get('SIMPLE_HY2_PASSWORD')
    )
    if spec_domain and spec_password:
        return {
            'domain': str(spec_domain),
            'password': str(spec_password),
            'obfs_type': str(
                server_specs.get('hysteria2_obfs')
                or server_specs.get('hysteria2_obfs_type')
                or server_specs.get('hy2_obfs')
                or 'salamander'
            ),
            'obfs_password': str(
                server_specs.get('hysteria2_obfs_password')
                or server_specs.get('hy2_obfs_password')
                or os.environ.get('SIMPLE_HY2_OBFS_PASSWORD')
                or ''
            ),
        }

    tokens = {
        str(getattr(server, 'id', '') or '').lower(),
        (getattr(server, 'country', '') or '').lower(),
        (getattr(server, 'city', '') or '').lower(),
        (getattr(server, 'name', '') or '').lower(),
        (getattr(server, 'ip_address', '') or '').lower(),
    }
    joined = ' '.join(tokens)

    if (
        str(getattr(server, 'id', '') or '') == '5'
        or '13.140.9.211' in tokens
        or 'sweden' in joined
        or 'stockholm' in joined
        or 'se' in tokens
    ):
        return {
            'domain': 'hy2-se.granilink.com',
            'password': 'GRANI-SE-HY2-domain-20260611',
            'obfs_type': 'salamander',
            'obfs_password': 'GRANI-SE-HY2-salamander-20260611',
        }

    if (
        '81.27.101.191' in tokens
        or 'poland' in joined
        or 'warsaw' in joined
        or 'waw' in joined
        or 'pl' in tokens
    ):
        return {
            'domain': 'hy2-pl.granilink.com',
            'password': 'GRANI-PL-HY2-domain-20260617',
            'obfs_type': 'salamander',
            'obfs_password': 'GRANI-PL-HY2-salamander-20260617',
        }

    code = (server.country or server.name or 'server')[:2].lower()
    return {
        'domain': f'hy2-{code}.granilink.com',
        'password': os.environ.get('SIMPLE_HY2_PASSWORD') or 'GRANI-SE-HY2-domain-20260611',
        'obfs_type': 'salamander',
        'obfs_password': os.environ.get('SIMPLE_HY2_OBFS_PASSWORD') or '',
    }


def _simple_hysteria2_profile(server: Server) -> Dict[str, Any]:
    defaults = _simple_hysteria2_defaults(server)
    domain = os.environ.get('SIMPLE_HY2_DOMAIN') or defaults['domain']
    password = os.environ.get('SIMPLE_HY2_PASSWORD') or defaults['password']
    obfs_type = os.environ.get('SIMPLE_HY2_OBFS_TYPE') or defaults.get('obfs_type', '')
    obfs_password = os.environ.get('SIMPLE_HY2_OBFS_PASSWORD') or defaults.get('obfs_password', '')
    remark = os.environ.get('SIMPLE_VPN_REMARK') or f'GRANI-{server.city or server.name}-HY2'
    hy2_outbound = {
        'type': 'hysteria2',
        'tag': 'proxy',
        'server': domain,
        'server_port': 443,
        'password': password,
        'tls': {
            'enabled': True,
            'server_name': domain,
        },
    }
    if obfs_type and obfs_password:
        hy2_outbound['obfs'] = {
            'type': obfs_type,
            'password': obfs_password,
        }
    singbox_config = {
        'log': {
            'level': 'info',
            'timestamp': True,
        },
        'dns': {
            'servers': [
                {
                    'tag': 'cloudflare',
                    'address': '1.1.1.1',
                },
                {
                    'tag': 'google',
                    'address': '8.8.8.8',
                },
            ],
            'final': 'cloudflare',
            'strategy': 'ipv4_only',
        },
        'inbounds': [
            {
                'type': 'tun',
                'tag': 'tun-in',
                'address': [
                    '172.19.0.1/30',
                ],
                'auto_route': True,
                'strict_route': True,
                'mtu': 1280,
                'stack': 'system',
            },
        ],
        'outbounds': [
            hy2_outbound,
            {
                'type': 'direct',
                'tag': 'direct',
            },
        ],
        'route': {
            'auto_detect_interface': True,
            'final': 'proxy',
        },
    }
    config = json.dumps(singbox_config, separators=(',', ':'))
    return {
        'protocol': 'hysteria2',
        'config_type': 'sing-box',
        'engine': 'hysteria2',
        'config': config,
        'json_config': {
            'format': 'sing-box-json',
            'server': domain,
            'server_port': 443,
            'password': password,
            'sni': domain,
            'obfs_type': obfs_type or None,
            'obfs_password': bool(obfs_password),
            'runtime': 'hysteria2-process',
            'remark': remark,
        },
        'revision': f'simple-vpn:{server.id}:hysteria2:{domain}:443:obfs:{obfs_type or "none"}',
    }


def _env_multiline(name: str) -> str:
    value = os.environ.get(name, '')
    return value.replace('\\n', '\n').strip()


def _truthy_env(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {'1', 'true', 'yes', 'on'}


def _generate_wireguard_key_pair_local() -> Dict[str, str]:
    """Generate WireGuard-compatible Curve25519 keys without SSHing to a VPN node."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import x25519

    private_bytes = bytearray(os.urandom(32))
    private_bytes[0] &= 248
    private_bytes[31] &= 127
    private_bytes[31] |= 64
    private_key = x25519.X25519PrivateKey.from_private_bytes(bytes(private_bytes))
    public_key = private_key.public_key()
    public_bytes = public_key.public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return {
        'private_key': base64.b64encode(bytes(private_bytes)).decode('ascii'),
        'public_key': base64.b64encode(public_bytes).decode('ascii'),
    }


def _simple_device(db: Session, user_id: int, device_id: Optional[str]) -> Device:
    stable_device_id = (device_id or '').strip()
    if not stable_device_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={
                'error': {
                    'code': 'DEVICE_REQUIRED',
                    'message': 'Device registration is required before Simple VPN config',
                }
            },
        )
    device = (
        db.query(Device)
        .filter(Device.user_id == user_id, Device.device_id == stable_device_id)
        .order_by(
            Device.is_active.desc(),
            Device.last_connected.desc().nullslast(),
            Device.id.desc(),
        )
        .first()
    )
    if device is not None:
        return device
    device = Device(
        user_id=user_id,
        device_id=stable_device_id,
        device_name='Android Device',
        device_type='android',
        platform='android',
        is_active=True,
        is_vpn_enabled=False,
        created_at=datetime.utcnow(),
    )
    db.add(device)
    db.commit()
    db.refresh(device)
    logger.warning(
        'simple-vpn auto-created missing device user_id=%s device_id=%s',
        user_id,
        stable_device_id,
    )
    return device


def _record_simple_client_log(
    db: Session,
    *,
    user_id: int,
    device_id: Optional[str],
    event: str,
    level: str = 'info',
    session_id: Optional[str] = None,
    server_id: Optional[int] = None,
    protocol: Optional[str] = None,
    details: Optional[Dict[str, Any]] = None,
) -> None:
    stable_device_id = (device_id or '').strip()
    if not stable_device_id:
        return
    try:
        device = (
            db.query(Device)
            .filter(Device.user_id == user_id, Device.device_id == stable_device_id)
            .order_by(Device.id.desc())
            .first()
        )
        if device is None:
            return
        log_details = dict(details or {})
        log_details['simple_event'] = event
        log_details['simple_level'] = level
        if session_id:
            log_details['connection_session_id'] = session_id
        mapped_event = _SIMPLE_CLIENT_LOG_EVENT_MAP.get(event, 'connection_stage')
        existing_query = (
            db.query(ClientLog.id)
            .filter(
                ClientLog.user_id == user_id,
                ClientLog.device_id == device.id,
                ClientLog.event_type == mapped_event,
                ClientLog.message == event,
            )
        )
        if session_id:
            existing_query = existing_query.filter(ClientLog.vpn_session_id == session_id)
        else:
            existing_query = existing_query.filter(
                ClientLog.created_at >= datetime.utcnow() - timedelta(seconds=20)
            )
        if existing_query.first():
            return
        db.add(
            ClientLog(
                user_id=user_id,
                device_id=device.id,
                server_id=server_id,
                event_type=mapped_event,
                protocol=protocol or log_details.get('protocol') or 'graniwg',
                message=event,
                error_code=(
                    f'simple_vpn_{event}'
                    if mapped_event == 'connection_error'
                    else None
                ),
                error_details=log_details,
                app_version=log_details.get('app_version'),
                platform=log_details.get('platform'),
                os_version=log_details.get('os_version'),
                bytes_sent=log_details.get('tx_bytes'),
                bytes_received=log_details.get('rx_bytes'),
                vpn_session_id=session_id,
            )
        )
        db.commit()
    except Exception:
        db.rollback()
        logger.exception(
            'simple-vpn: failed to persist client log user_id=%s device_id=%s event=%s',
            user_id,
            stable_device_id,
            event,
        )


def _simple_log_server_id(details: Dict[str, Any]) -> Optional[int]:
    raw = details.get('server_id') or details.get('selected_server_id')
    try:
        return int(raw) if raw is not None else None
    except (TypeError, ValueError):
        return None


def _simple_amneziawg_profile(server: Server, user_id: int, db: Session, device_id: Optional[str] = None) -> Dict[str, Any]:
    static_config = _env_multiline('SIMPLE_AWG_CONFIG')
    if static_config:
        if '[Interface]' not in static_config or '[Peer]' not in static_config:
            raise HTTPException(status_code=500, detail='SIMPLE_AWG_CONFIG is not a WireGuard/AmneziaWG config')
        return {
            'protocol': 'graniwg',
            'config_type': 'amneziawg',
            'engine': 'amneziawg',
            'config': static_config,
            'json_config': {'format': 'amneziawg-quick', 'source': 'env'},
            'revision': f'simple-vpn:{server.id}:amneziawg:env:{hash(static_config)}',
        }

    if not _truthy_env('SIMPLE_AWG_PROVISION', True):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail='AmneziaWG provisioning disabled and SIMPLE_AWG_CONFIG is not configured',
        )
    if not server.graniwg_enabled:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f'Server {server.id} does not have graniwg_enabled=true',
        )
    if not server.wireguard_public_key or not server.wireguard_port:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f'Server {server.id} is missing WireGuard public key or port',
        )

    prepared = None
    profile_source = 'provisioned'
    requires_psk = _server_requires_graniwg_psk(server)
    preshared_key = None
    with _get_provision_lock(user_id, device_id):
        wg = WireGuardManager(server)
        device = _simple_device(db, user_id, device_id)
        changed = False
        if not device.wireguard_public_key or not device.wireguard_private_key:
            keys = _generate_wireguard_key_pair_local()
            device.wireguard_public_key = keys.get('public_key')
            device.wireguard_private_key = keys.get('private_key')
            db.commit()
            db.refresh(device)

        prepared = _get_prepared_peer(db, device, server)
        if prepared:
            profile_source = 'prepared-peer-cache'
            client_ip = str(prepared['vpn_ip']).strip()
            revision = prepared.get('config_revision') or f'simple-vpn:{server.id}:amneziawg:device:{device.id}:{client_ip}'
            preshared_key = (prepared.get('preshared_key') or '').strip() or None
            if requires_psk and not preshared_key:
                preshared_key = _generate_graniwg_preshared_key()
                if not wg.add_peer_to_server(device, server, client_ip, preshared_key=preshared_key):
                    db.rollback()
                    raise HTTPException(
                        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                        detail='Failed to update AmneziaWG peer preshared key on server',
                    )
                _upsert_prepared_peer(db, device, server, client_ip, revision, preshared_key=preshared_key)
                logger.warning(
                    'simple-vpn prepared peer psk enabled user_id=%s device_pk=%s server_id=%s vpn_ip=%s',
                    user_id,
                    device.wireguard_public_key,
                    server.id,
                    client_ip,
                )
            if prepared.get('suspended_at') is not None:
                if not wg.add_peer_to_server(device, server, client_ip, preshared_key=preshared_key):
                    db.rollback()
                    raise HTTPException(
                        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                        detail='Failed to restore suspended AmneziaWG peer on server',
                    )
                _upsert_prepared_peer(db, device, server, client_ip, revision, preshared_key=preshared_key)
                logger.warning(
                    'simple-vpn suspended peer restored user_id=%s device_pk=%s server_id=%s vpn_ip=%s reason=%s',
                    user_id,
                    device.wireguard_public_key,
                    server.id,
                    client_ip,
                    prepared.get('suspend_reason'),
                )
            else:
                restored = _restore_prepared_peer_if_missing(
                    db,
                    wg,
                    device,
                    server,
                    prepared,
                    revision,
                    preshared_key=preshared_key,
                )
                if restored:
                    profile_source = 'prepared-peer-restored'
                    changed = True
                _touch_prepared_peer(db, int(prepared['id']))
                logger.warning(
                    'simple-vpn prepared peer cache hit user_id=%s device_pk=%s server_id=%s vpn_ip=%s restored=%s',
                    user_id,
                    device.wireguard_public_key,
                    server.id,
                    client_ip,
                    restored,
                )
        else:
            profile_source = 'provisioned'
            client_ip = wg.get_next_available_ip(server)
            revision = f'simple-vpn:{server.id}:amneziawg:device:{device.id}:{client_ip}'
            preshared_key = _generate_graniwg_preshared_key() if requires_psk else None
            if not wg.add_peer_to_server(device, server, client_ip, preshared_key=preshared_key):
                db.rollback()
                raise HTTPException(
                    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                    detail='Failed to add AmneziaWG peer on server',
                )
            _upsert_prepared_peer(db, device, server, client_ip, revision, preshared_key=preshared_key)
            logger.warning(
                'simple-vpn prepared peer created user_id=%s device_pk=%s server_id=%s vpn_ip=%s',
                user_id,
                device.wireguard_public_key,
                server.id,
                client_ip,
            )
            changed = True

        device.ip_address = client_ip
        device.current_server_id = server.id
        device.vpn_protocol = 'graniwg'
        device.is_vpn_enabled = True
        device.is_active = True
        device.last_connected = datetime.utcnow()
        changed = True

        if changed:
            db.commit()
            db.refresh(device)
            try:
                from core.cache import cache_delete
                cache_delete(f"cache:devices:{user_id}")
            except Exception:
                logger.debug('simple-vpn: failed to invalidate devices cache', exc_info=True)

    config = wg.create_client_config(device, server, client_ip, protocol='graniwg', preshared_key=preshared_key)
    config_hash = hashlib.sha256(config.encode('utf-8')).hexdigest()[:12]
    return {
        'protocol': 'graniwg',
        'config_type': 'amneziawg',
        'engine': 'amneziawg',
        'config': config,
        'json_config': {
            'format': 'amneziawg-quick',
            'source': profile_source,
            'device_id': device.device_id,
            'vpn_ip': client_ip,
            'server_id': server.id,
            'prepared_peer': True,
            'preshared_key': bool(preshared_key),
        },
        'revision': f'{revision}:cfg:{config_hash}',
    }

def _simple_profile(
    server: Server,
    user_id: int,
    db: Session,
    device_id: Optional[str] = None,
    protocol: Optional[str] = None,
) -> Dict[str, Any]:
    requested = (protocol or os.environ.get('SIMPLE_VPN_PROTOCOL', 'graniwg')).strip() or 'graniwg'
    if requested in {'graniwg', 'amneziawg', 'awg'}:
        return _simple_amneziawg_profile(server, user_id, db, device_id)
    if requested in {'vless_ws', 'xray_vless', 'xray_vmess', 'xray_reality'}:
        return _simple_xray_profile(server, requested)
    if requested == 'hysteria2':
        return _simple_hysteria2_profile(server)
    raise HTTPException(status_code=400, detail=f'Unsupported simple VPN protocol: {requested}')


@router.get('/servers', response_model=SimpleVpnServersResponse)
async def get_simple_vpn_servers(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
):
    user = _current_user(credentials, db)
    _assert_access(user.id, db)
    servers = (
        db.query(Server)
        .filter(Server.is_active == True, Server.graniwg_enabled == True)  # noqa: E712
        .order_by(Server.id.asc())
        .all()
    )
    default_id = _env_int('SIMPLE_VPN_SERVER_ID', servers[0].id if servers else 1)
    return SimpleVpnServersResponse(
        success=True,
        default_server_id=default_id,
        servers=[_simple_server_payload(server) for server in servers],
    )


@router.get('/protocols', response_model=SimpleVpnProtocolResponse)
async def get_simple_vpn_protocols(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
):
    user = _current_user(credentials, db)
    _assert_access(user.id, db)
    default_protocol = os.environ.get('SIMPLE_VPN_PROTOCOL', 'graniwg').strip() or 'graniwg'
    return SimpleVpnProtocolResponse(
        success=True,
        default_protocol=default_protocol,
        protocols=[
            {
                'id': 'vless_ws',
                'engine': 'xray',
                'status': 'active',
                'role': 'fallback',
                'reason': 'VLESS WebSocket uses the embedded Xray runtime and the tested Sweden TCP 8080 profile.',
            },
            {
                'id': 'hysteria2',
                'engine': 'hysteria2',
                'status': 'active',
                'role': 'fallback',
                'reason': 'Hysteria 2 over sing-box/libbox runtime.',
            },
            {
                'id': 'graniwg',
                'engine': 'amneziawg',
                'status': 'active',
                'role': 'primary',
                'reason': 'Obfuscated WireGuard / AmneziaWG path.',
            },
        ],
    )


@router.get('/config', response_model=SimpleVpnConfigResponse)
async def get_simple_vpn_config(
    device_id: Optional[str] = None,
    server_id: Optional[int] = None,
    protocol: Optional[str] = None,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
):
    user = _current_user(credentials, db)
    _assert_access(user.id, db)
    server = _pick_server(db, server_id)
    profile = _simple_profile(server, user.id, db, device_id, protocol)
    logger.warning(
        'simple-vpn config issued user_id=%s server_id=%s protocol=%s',
        user.id,
        server.id,
        profile['protocol'],
    )
    return SimpleVpnConfigResponse(
        success=True,
        protocol=profile['protocol'],
        config_type=profile.get('config_type', 'xray'),
        engine=profile.get('engine', 'xray'),
        server=_simple_server_payload(server),
        config=profile['config'],
        json_config=profile['json_config'],
        config_revision=profile['revision'],
        message='Simple VPN config ready',
    )


@router.post('/session/start', response_model=SimpleVpnStartResponse)
async def start_simple_vpn_session(
    request: SimpleVpnStartRequest,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
):
    user = _current_user(credentials, db)
    _assert_access(user.id, db)
    session_id = str(uuid.uuid4())
    key = _simple_key(user.id, request.device_id)
    _session_state[key] = {
        'status': 'starting',
        'session_id': session_id,
        'updated_at': datetime.utcnow().isoformat(),
        'protocol': request.protocol or 'simple',
        'server_id': request.server_id,
    }
    logger.warning(
        'simple-vpn session start user_id=%s device_id=%s session_id=%s server_id=%s protocol=%s',
        user.id,
        request.device_id,
        session_id,
        request.server_id,
        request.protocol or 'simple',
    )
    return SimpleVpnStartResponse(success=True, session_id=session_id, status='starting')



@router.post('/session/verify', response_model=SimpleVpnVerifyResponse)
async def verify_simple_vpn_session(
    request: SimpleVpnVerifyRequest,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
):
    user = _current_user(credentials, db)
    _assert_access(user.id, db)
    device = _simple_device(db, user.id, request.device_id)
    key = _simple_key(user.id, request.device_id)
    session_state = _session_state.get(key, {})
    server_id = (
        request.server_id
        or session_state.get('server_id')
        or device.current_server_id
    )
    if not server_id:
        return SimpleVpnVerifyResponse(
            success=True,
            verified=False,
            status='unverified',
            reason='missing_server_id',
        )
    verify_protocol = (request.protocol or session_state.get('protocol') or device.vpn_protocol or 'graniwg').strip()
    server = _pick_server(db, int(server_id))
    if verify_protocol not in {'graniwg', 'amneziawg', 'awg'}:
        logger.warning(
            'simple-vpn client-side verify user_id=%s device_id=%s session_id=%s server_id=%s protocol=%s',
            user.id,
            request.device_id,
            request.session_id,
            server.id,
            verify_protocol,
        )
        return SimpleVpnVerifyResponse(
            success=True,
            verified=True,
            status='client_side',
            server_id=server.id,
            reason='server_side_node_verify_only_available_for_graniwg',
            details={'protocol': verify_protocol},
        )
    peer = _get_prepared_peer(db, device, server)
    vpn_ip = str(peer.get('vpn_ip') if peer else device.ip_address or '').strip()
    details = _verify_graniwg_node_traffic(server, device.wireguard_public_key or '', vpn_ip)
    verified = bool(details.get('verified'))
    status_value = 'verified' if verified else 'unverified'
    logger.warning(
        'simple-vpn node verify user_id=%s device_id=%s session_id=%s server_id=%s verified=%s reason=%s vpn_ip=%s handshake_age=%s rx=%s tx=%s',
        user.id,
        request.device_id,
        request.session_id,
        server.id,
        verified,
        details.get('reason'),
        vpn_ip,
        details.get('handshake_age_sec'),
        details.get('rx_bytes'),
        details.get('tx_bytes'),
    )
    verify_log_details = {
        **details,
        'source': 'simple_vpn_session_verify',
        'server_id': server.id,
        'vpn_ip': vpn_ip or None,
    }
    _record_simple_client_log(
        db,
        user_id=user.id,
        device_id=request.device_id,
        event='vpn_data_verified' if verified else 'node_data_verify_failed',
        level='info' if verified else 'warning',
        session_id=request.session_id,
        server_id=server.id,
        protocol=request.protocol or session_state.get('protocol') or 'graniwg',
        details=verify_log_details,
    )
    return SimpleVpnVerifyResponse(
        success=True,
        verified=verified,
        status=status_value,
        server_id=server.id,
        vpn_ip=vpn_ip or None,
        handshake_age_sec=details.get('handshake_age_sec'),
        rx_bytes=details.get('rx_bytes'),
        tx_bytes=details.get('tx_bytes'),
        reason=details.get('reason'),
        details=details,
    )


@router.post('/session/stop', response_model=SimpleVpnStatusResponse)
async def stop_simple_vpn_session(
    request: SimpleVpnStopRequest,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
):
    user = _current_user(credentials, db)
    key = _simple_key(user.id, request.device_id)
    state = _session_state.get(key, {})
    state.update({
        'status': 'stopped',
        'session_id': request.session_id or state.get('session_id'),
        'updated_at': datetime.utcnow().isoformat(),
        'reason': request.reason or 'user',
    })
    _session_state[key] = state
    if request.device_id:
        device = (
            db.query(Device)
            .filter(Device.user_id == user.id, Device.device_id == request.device_id.strip())
            .first()
        )
        if device is not None:
            device.is_active = False
            device.is_vpn_enabled = False
            device.current_server_id = None
            device.ip_address = None
            device.vpn_protocol = None
            db.commit()
            try:
                from core.cache import cache_delete
                cache_delete(f"cache:devices:{user.id}")
            except Exception:
                logger.debug('simple-vpn: failed to invalidate devices cache on stop', exc_info=True)
    logger.warning('simple-vpn session stop user_id=%s device_id=%s session_id=%s reason=%s', user.id, request.device_id, state.get('session_id'), state.get('reason'))
    return SimpleVpnStatusResponse(success=True, status='stopped', session_id=state.get('session_id'), updated_at=state.get('updated_at'))


@router.get('/session/status', response_model=SimpleVpnStatusResponse)
async def get_simple_vpn_status(
    device_id: Optional[str] = None,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
):
    user = _current_user(credentials, db)
    state = _session_state.get(_simple_key(user.id, device_id), {})
    return SimpleVpnStatusResponse(
        success=True,
        status=state.get('status', 'unknown'),
        session_id=state.get('session_id'),
        updated_at=state.get('updated_at'),
    )


@router.post('/logs', response_model=SimpleVpnLogResponse)
async def post_simple_vpn_log(
    request: SimpleVpnLogRequest,
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
):
    user = _current_user(credentials, db)
    logger.warning(
        'simple-vpn client-log user_id=%s device_id=%s session_id=%s level=%s event=%s details=%s',
        user.id,
        request.device_id,
        request.session_id,
        request.level,
        request.event,
        request.details or {},
    )
    details = dict(request.details or {})
    _record_simple_client_log(
        db,
        user_id=user.id,
        device_id=request.device_id,
        event=request.event,
        level=request.level,
        session_id=request.session_id,
        server_id=_simple_log_server_id(details),
        protocol=details.get('protocol') or details.get('selected_protocol') or 'graniwg',
        details=details,
    )
    return SimpleVpnLogResponse(success=True)
