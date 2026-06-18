import logging
import json
import uuid
import requests
import time
import re
import hashlib
import threading
from typing import Dict, Any, Optional, List, Callable
from datetime import datetime

from core.cache import cache_get, cache_set
from core.config import settings
from core.database import SessionLocal
from urllib.parse import urlencode, quote
from domain.models.server import Server
from domain.models.user import Device
from core.config import settings
from core.constants import (
    XRAY_REALITY_DEFAULT_PORT,
    XRAY_DEFAULT_PORT,
    XRAY_VLESS_DEFAULT_PORT,
    XRAY_VMESS_DEFAULT_PORT,
)

# Опциональный импорт RemoteVPNManager
try:
    from infrastructure.external.remote_vpn_manager import RemoteVPNManager
    REMOTE_VPN_MANAGER_AVAILABLE = True
except ImportError as e:
    RemoteVPNManager = None
    REMOTE_VPN_MANAGER_AVAILABLE = False
    logging.warning(f"RemoteVPNManager недоступен: {e}")

logger = logging.getLogger(__name__)

# Guardrails for egress stability: block noisy scanner/p2p destinations.
_XRAY_BLOCKED_EGRESS_PORTS = [22, 23, 25, 110, 135, 137, 138, 139, 445, 554, 3389]
_XRAY_ACCESS_LOG_PATH = "/var/log/xray/access.log"
_XRAY_ERROR_LOG_PATH = "/var/log/xray/error.log"

# Блокировки по server_id для консистентности кэша при параллельных create-client
_xray_config_locks: Dict[int, threading.Lock] = {}
_xray_config_locks_mutex = threading.Lock()
_celery_health_cache = {"ok": False, "checked_at": 0.0}
_xray_apply_debounce_lock = threading.Lock()
_xray_apply_timers: Dict[int, threading.Timer] = {}
_xray_apply_pending: Dict[int, Dict[str, Any]] = {}
_xray_service_action_locks: Dict[int, threading.Lock] = {}
_xray_service_action_locks_mutex = threading.Lock()

def _server_lock(server_id: int) -> threading.Lock:
    with _xray_config_locks_mutex:
        if server_id not in _xray_config_locks:
            _xray_config_locks[server_id] = threading.Lock()
        return _xray_config_locks[server_id]


def _service_action_lock(server_id: int) -> threading.Lock:
    with _xray_service_action_locks_mutex:
        if server_id not in _xray_service_action_locks:
            _xray_service_action_locks[server_id] = threading.Lock()
        return _xray_service_action_locks[server_id]


def _stable_config_bytes(config: Dict[str, Any]) -> bytes:
    """Deterministic JSON bytes for semantic config comparison."""
    return json.dumps(config, indent=2, sort_keys=True).encode("utf-8")


def _sanitize_vless_reality_fallbacks(settings: Dict[str, Any], reality_dest: str) -> None:
    """
    Legacy templates used \"fallbacks\": [{\"dest\": 80}], which dials 127.0.0.1:80.
    Nothing listens there on typical nodes → connection refused and broken sessions.
    Replace with the same host:port as REALITY dest (camouflage forwarding).
    """
    if not settings or not isinstance(settings, dict):
        return
    fallbacks = settings.get("fallbacks")
    if not fallbacks or not reality_dest:
        return

    def _bad_dest(d: Any) -> bool:
        if isinstance(d, int):
            return True
        if not isinstance(d, str):
            return True
        s = d.strip().lower()
        if ":" not in s:
            return True
        if s.startswith("127.") or s.startswith("[::1]") or "localhost" in s:
            return True
        return False

    if any(isinstance(x, dict) and _bad_dest(x.get("dest")) for x in fallbacks):
        settings["fallbacks"] = [{"dest": reality_dest}]


def _ensure_xray_data_plane_guardrails(config: Dict[str, Any]) -> None:
    """
    Enforce minimal routing guardrails for outbound stability.
    The goal is to protect user web traffic from noisy scanner/p2p churn.
    """
    outbounds = list(config.get("outbounds") or [])
    has_blocked = any(str(o.get("tag") or "") == "blocked" for o in outbounds if isinstance(o, dict))
    if not has_blocked:
        outbounds.append({"protocol": "blackhole", "settings": {}, "tag": "blocked"})
    config["outbounds"] = outbounds

    routing = dict(config.get("routing") or {})
    rules = list(routing.get("rules") or [])

    def _has_rule(predicate: Callable[[Dict[str, Any]], bool]) -> bool:
        for rule in rules:
            if isinstance(rule, dict) and predicate(rule):
                return True
        return False

    if not _has_rule(
        lambda r: r.get("type") == "field"
        and r.get("outboundTag") == "blocked"
        and (r.get("ip") or []) == ["geoip:private"]
    ):
        rules.insert(0, {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"})

    blocked_ports = ",".join(str(p) for p in _XRAY_BLOCKED_EGRESS_PORTS)
    if not _has_rule(
        lambda r: r.get("type") == "field"
        and r.get("outboundTag") == "blocked"
        and str(r.get("network") or "") == "tcp,udp"
        and str(r.get("port") or "") == blocked_ports
    ):
        rules.append(
            {
                "type": "field",
                "network": "tcp,udp",
                "port": blocked_ports,
                "outboundTag": "blocked",
            }
        )

    if not _has_rule(
        lambda r: r.get("type") == "field"
        and r.get("outboundTag") == "blocked"
        and (r.get("protocol") or []) == ["bittorrent"]
    ):
        rules.append(
            {
                "type": "field",
                "protocol": ["bittorrent"],
                "outboundTag": "blocked",
            }
        )

    routing["rules"] = rules
    config["routing"] = routing


def _ensure_xray_transport_tuning(config: Dict[str, Any]) -> None:
    """
    Conservative transport tuning for long-lived mobile TCP flows.
    Keeps defaults stable but ensures minimal policy fields exist.
    """
    policy = config.get("policy")
    if not isinstance(policy, dict):
        policy = {}

    levels = policy.get("levels")
    if not isinstance(levels, dict):
        levels = {}
    level0 = levels.get("0")
    if not isinstance(level0, dict):
        level0 = {}

    # Do not overwrite explicit per-node tuning if already set.
    level0.setdefault("handshake", 8)
    level0.setdefault("connIdle", 300)
    level0.setdefault("uplinkOnly", 2)
    level0.setdefault("downlinkOnly", 5)
    levels["0"] = level0
    policy["levels"] = levels

    system = policy.get("system")
    if not isinstance(system, dict):
        system = {}
    system.setdefault("statsInboundUplink", False)
    system.setdefault("statsInboundDownlink", False)
    system.setdefault("statsOutboundUplink", False)
    system.setdefault("statsOutboundDownlink", False)
    policy["system"] = system

    # Stabilize baseline inbound vless@4443 for churn/idle behavior.
    for inbound in config.get("inbounds") or []:
        if not isinstance(inbound, dict):
            continue
        if inbound.get("protocol") != "vless":
            continue
        if int(inbound.get("port") or 0) != 4443:
            continue
        stream = inbound.get("streamSettings")
        if not isinstance(stream, dict):
            stream = {}
        if str(stream.get("security") or "none") != "none":
            continue
        stream.setdefault("network", "tcp")
        tcp_settings = stream.get("tcpSettings")
        if not isinstance(tcp_settings, dict):
            tcp_settings = {}
        tcp_settings.setdefault("acceptProxyProtocol", False)
        header = tcp_settings.get("header")
        if not isinstance(header, dict):
            header = {}
        header.setdefault("type", "none")
        tcp_settings["header"] = header
        stream["tcpSettings"] = tcp_settings
        sockopt = stream.get("sockopt")
        if not isinstance(sockopt, dict):
            sockopt = {}
        sockopt.setdefault("tcpFastOpen", True)
        sockopt.setdefault("tcpNoDelay", True)
        sockopt.setdefault("tcpKeepAliveIdle", 120)
        stream["sockopt"] = sockopt
        inbound["streamSettings"] = stream

        sniffing = inbound.get("sniffing")
        if not isinstance(sniffing, dict):
            sniffing = {}
        sniffing.setdefault("enabled", True)
        sniffing.setdefault("destOverride", ["http", "tls", "quic"])
        inbound["sniffing"] = sniffing

    config["policy"] = policy


def _ensure_xray_logging_contract(config: Dict[str, Any]) -> None:
    """
    Enforce stable Xray log sinks for diagnostics.
    Without explicit access/error paths, file-based observability can silently disappear.
    """
    log_section = config.get("log")
    if not isinstance(log_section, dict):
        log_section = {}
    loglevel = str(log_section.get("loglevel") or "warning").strip().lower()
    if loglevel not in {"debug", "info", "warning", "error", "none"}:
        loglevel = "warning"

    log_section["loglevel"] = loglevel
    log_section["access"] = _XRAY_ACCESS_LOG_PATH
    log_section["error"] = _XRAY_ERROR_LOG_PATH
    config["log"] = log_section


def _try_enqueue_edge_apply(server: Server, config: Dict[str, Any]) -> Optional[str]:
    """
    Ставит полный JSON-конфиг Xray в очередь edge-агента.
    Возвращает assignment_id при успехе; None — нет edge-токена или ошибка БД.
    """
    from services.edge_enqueue import try_commit_apply_xray_config_edge_with_id

    return try_commit_apply_xray_config_edge_with_id(server, config)


def _run_sync_apply_in_background(server: Server, config: Dict[str, Any], branch: str) -> None:
    """
    Последний fallback: запускаем sync SSH apply в daemon-потоке,
    чтобы не блокировать hot path create-client.
    """
    server_id = getattr(server, "id", None)
    cfg_copy = json.loads(json.dumps(config))

    def worker() -> None:
        try:
            db = SessionLocal()
            try:
                server_obj = db.query(Server).filter(Server.id == int(server_id or 0)).first()
                if not server_obj:
                    logger.error(
                        "xray background apply skipped: server not found server_id=%s",
                        server_id,
                    )
                    return
                from services.edge_enqueue import count_active_xray_sessions_for_server
                from services.tasks.vpn_tasks import apply_xray_config_to_vpn

                active = count_active_xray_sessions_for_server(db, int(server_id or 0))
                if active > 0:
                    retry_sec = max(5, int(getattr(settings, "xray_apply_retry_delay_sec", 60) or 60))
                    apply_xray_config_to_vpn.apply_async(
                        args=[int(server_id or 0), json.dumps(cfg_copy)],
                        countdown=retry_sec,
                    )
                    logger.warning(
                        "xray background apply deferred: server_id=%s branch=%s active_sessions=%s retry_sec=%s",
                        server_id,
                        branch,
                        active,
                        retry_sec,
                    )
                    return
            finally:
                try:
                    db.close()
                except Exception:
                    pass
            manager = XrayManager()
            started = time.monotonic()
            applied = manager.apply_config_to_server(server_obj, cfg_copy)
            apply_ms = int((time.monotonic() - started) * 1000)
            manager.set_last_apply_state(
                server_obj,
                {
                    "status": "applied" if applied else "failed",
                    "ack_mode": "sync_ssh_background" if applied else "none",
                    "apply_branch": branch,
                    "apply_duration_ms": apply_ms,
                    "updated_at": datetime.utcnow().isoformat() + "Z",
                },
            )
            logger.warning(
                "xray background apply finished: server_id=%s branch=%s applied=%s apply_ms=%s",
                server_id,
                branch,
                applied,
                apply_ms,
            )
        except Exception as exc:
            logger.error(
                "xray background apply failed: server_id=%s branch=%s err=%s",
                server_id,
                branch,
                exc,
                exc_info=True,
            )

    threading.Thread(
        target=worker,
        name=f"xray-apply-bg-{server_id}",
        daemon=True,
    ).start()


def warm_xray_config_cache_for_active_servers(db) -> None:
    """
    Прогревает кэш конфигов Xray для всех активных серверов.
    Вызывать при старте API (в фоне, с задержкой), чтобы первый create-client не ждал SSH.
    """
    try:
        from domain.models.server import Server
        servers = db.query(Server).filter(Server.is_active == True).all()
        if not servers:
            return
        manager = XrayManager()
        for server in servers:
            try:
                config = manager._read_xray_config(server)
                if config:
                    manager._set_cached_xray_config(server, config)
                    logger.info("Xray config cache warmed for server_id=%s", server.id)
            except Exception as e:
                logger.warning("Failed to warm xray config for server_id=%s: %s", server.id, e)
    except Exception as e:
        logger.warning("warm_xray_config_cache_for_active_servers: %s", e)


def _is_celery_worker_available(ttl_seconds: float = 10.0) -> bool:
    """
    Быстрая проверка доступности Celery worker с коротким кэшем.
    Нужна для fallback в синхронное применение Xray-конфига.
    timeout inspect слишком короткий (0.5s) давал ложные «worker недоступен» под нагрузкой.
    """
    now = time.time()
    if now - _celery_health_cache["checked_at"] < ttl_seconds:
        return bool(_celery_health_cache["ok"])
    try:
        from services.celery_app import celery_app

        inspector = celery_app.control.inspect(timeout=2.0)
        ping_result = inspector.ping() if inspector else None
        ok = bool(ping_result)
    except Exception:
        ok = False

    _celery_health_cache["ok"] = ok
    _celery_health_cache["checked_at"] = now
    return ok


def _parse_iso_utc(ts: Optional[str]) -> Optional[datetime]:
    if not ts:
        return None
    normalized = str(ts).strip()
    if not normalized:
        return None
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(normalized)
    except Exception:
        return None


def _schedule_debounced_apply(
    server: Server,
    config: Dict[str, Any],
    delay_sec: float,
) -> None:
    """
    Дебаунс применения Xray-конфига:
    - сохраняем только последнюю версию конфига на server_id
    - если таймер уже запущен, не создаем новый
    """
    server_id = int(getattr(server, "id", 0) or 0)
    if server_id <= 0:
        return

    pending_copy = json.loads(json.dumps(config))

    def _worker() -> None:
        with _xray_apply_debounce_lock:
            latest = _xray_apply_pending.pop(server_id, None)
            _xray_apply_timers.pop(server_id, None)

        if latest is None:
            return

        manager = XrayManager()
        try:
            started = time.monotonic()
            celery_ok = _is_celery_worker_available()
            apply_state = manager._apply_config_with_ack(server, latest, celery_ok=celery_ok)
            apply_state["apply_branch"] = "debounced_flush"
            apply_state["updated_at"] = datetime.utcnow().isoformat() + "Z"
            manager.set_last_apply_state(server, apply_state)
            manager._set_cached_xray_config(server, latest)
            logger.warning(
                "xray debounced apply flushed: server_id=%s status=%s ack_mode=%s apply_ms=%s",
                server_id,
                apply_state.get("status"),
                apply_state.get("ack_mode"),
                int((time.monotonic() - started) * 1000),
            )
        except Exception as exc:
            logger.error(
                "xray debounced apply failed: server_id=%s err=%s",
                server_id,
                exc,
                exc_info=True,
            )

    with _xray_apply_debounce_lock:
        _xray_apply_pending[server_id] = pending_copy
        timer = _xray_apply_timers.get(server_id)
        if timer and timer.is_alive():
            return
        new_timer = threading.Timer(max(delay_sec, 0.1), _worker)
        new_timer.daemon = True
        _xray_apply_timers[server_id] = new_timer
        new_timer.start()


def _apply_health_key(server_id: int) -> str:
    return f"xray_apply_health:server:{server_id}"


def _apply_block_key(server_id: int) -> str:
    return f"xray_apply_blocked:server:{server_id}"


class XrayManager:
    """Менеджер для работы с Xray"""
    
    def __init__(self, server: Optional[Server] = None):
        self.server = server
        if REMOTE_VPN_MANAGER_AVAILABLE and RemoteVPNManager:
            self.remote_manager = RemoteVPNManager()
        else:
            self.remote_manager = None
            logger.warning("XrayManager инициализирован без RemoteVPNManager. SSH функции недоступны.")
    
    def _get_ssh_config(self, server: Server) -> Dict[str, Any]:
        """Получает SSH конфигурацию из модели Server"""
        if not self.remote_manager:
            raise Exception("RemoteVPNManager недоступен")
        return self.remote_manager.get_ssh_config(server)
    
    def _get_xray_config_path(self, server: Server) -> str:
        """Получает путь к конфигурации Xray"""
        return server.xray_config_path or "/usr/local/etc/xray/config.json"

    def _xray_unit_candidates(self) -> List[str]:
        preferred = str(getattr(settings, "xray_systemd_unit", "") or "").strip()
        # xray-v2 is the only supported unit in production tunnel path.
        candidates: List[str] = ["xray-v2"]
        if preferred and preferred not in candidates:
            candidates.insert(0, preferred)
        return candidates

    def _exec_systemctl_with_fallback(
        self,
        ssh_config: Dict[str, Any],
        action: str,
    ) -> Dict[str, Any]:
        """
        Выполняет systemctl <action> для кандидатов unit'ов.
        Возвращает первый успешный результат или последний неуспешный.
        """
        last_result: Dict[str, Any] = {"success": False, "stderr": "unit not found"}
        for unit in self._xray_unit_candidates():
            actual_action = action
            cmd = f"systemctl {actual_action} {unit}"
            result = self.remote_manager.ssh_manager.execute_command(
                ssh_config["host"],
                cmd,
                ssh_config["port"],
                ssh_config["username"],
                ssh_config.get("key_path"),
                ssh_config.get("key_content"),
                ssh_config.get("password"),
            )
            result["unit"] = unit
            result["action"] = actual_action
            if result.get("success"):
                return result
            last_result = result
        return last_result

    def _exec_systemctl_with_fallback_in_session(
        self,
        client,
        action: str,
        timeout: int = 30,
    ) -> Dict[str, Any]:
        last = {"success": False, "exit_status": -1, "stderr": "unit not found", "unit": None}
        for unit in self._xray_unit_candidates():
            actual_action = action
            stdin, stdout, stderr = client.exec_command(
                f"systemctl {actual_action} {unit}",
                timeout=timeout,
            )
            exit_status = stdout.channel.recv_exit_status()
            stderr_text = stderr.read().decode("utf-8", errors="ignore").strip()
            stdout_text = stdout.read().decode("utf-8", errors="ignore").strip()
            if exit_status == 0:
                return {
                    "success": True,
                    "exit_status": 0,
                    "stderr": stderr_text,
                    "stdout": stdout_text,
                    "unit": unit,
                    "action": actual_action,
                }
            last = {
                "success": False,
                "exit_status": exit_status,
                "stderr": stderr_text,
                "stdout": stdout_text,
                "unit": unit,
                "action": actual_action,
            }
        return last

    def _reload_or_restart_in_session(
        self,
        client,
        server: Server,
        *,
        context: str,
    ) -> None:
        server_id = int(getattr(server, "id", 0) or 0)
        with _service_action_lock(server_id):
            reload_result = self._exec_systemctl_with_fallback_in_session(
                client,
                "reload",
                timeout=30,
            )
            reload_exit_raw = reload_result.get("exit_status")
            reload_exit = int(reload_exit_raw) if reload_exit_raw is not None else -1
            reload_err = str(reload_result.get("stderr") or "").strip()
            if reload_exit == 0:
                logger.info(
                    "%s: server_id=%s xray_action=reload exit=0 unit=%s",
                    context,
                    server_id,
                    reload_result.get("unit"),
                )
                return

            logger.warning(
                "%s: server_id=%s reload_failed exit=%s unit=%s stderr=%s; fallback=restart",
                context,
                server_id,
                reload_exit,
                reload_result.get("unit"),
                reload_err[:500] if reload_err else "",
            )
            restart_result = self._exec_systemctl_with_fallback_in_session(
                client,
                "restart",
                timeout=30,
            )
            restart_exit_raw = restart_result.get("exit_status")
            restart_exit = int(restart_exit_raw) if restart_exit_raw is not None else -1
            restart_err = str(restart_result.get("stderr") or "").strip()
            if restart_exit == 0:
                logger.info(
                    "%s: server_id=%s xray_action=restart_after_reload_fail exit=0 unit=%s",
                    context,
                    server_id,
                    restart_result.get("unit"),
                )
                return

            logger.error(
                "%s: server_id=%s restart_failed exit=%s unit=%s stderr=%s",
                context,
                server_id,
                restart_exit,
                restart_result.get("unit"),
                restart_err[:500] if restart_err else "",
            )
            raise RuntimeError(
                f"xray restart failed after config write: exit={restart_exit} err={restart_err[:300]}"
            )

    def _get_cached_xray_config(self, server: Server) -> Optional[Dict[str, Any]]:
        """Читает конфиг Xray из кэша (для быстрого пути create-client)."""
        key = f"xray_config:server:{server.id}"
        return cache_get(key)

    def _set_cached_xray_config(self, server: Server, config: Dict[str, Any], ttl: int = 1800) -> None:
        """Сохраняет конфиг Xray в кэш (TTL 30 мин)."""
        key = f"xray_config:server:{server.id}"
        cache_set(key, config, ttl=ttl)

    def _get_apply_state_cache_key(self, server: Server) -> str:
        return f"xray_apply_state:server:{server.id}"

    def _get_staged_config_cache_key(self, server: Server) -> str:
        return f"xray_staged_config:server:{server.id}"

    def _calc_config_revision(self, config: Dict[str, Any]) -> str:
        try:
            # Должно совпадать с сериализацией для edge expected_hash.
            payload = json.dumps(config, indent=2).encode("utf-8")
        except Exception:
            payload = str(config).encode("utf-8")
        return hashlib.sha256(payload).hexdigest()[:16]

    def _calc_config_sha256(self, config: Dict[str, Any]) -> str:
        try:
            payload = json.dumps(config, indent=2).encode("utf-8")
        except Exception:
            payload = str(config).encode("utf-8")
        return hashlib.sha256(payload).hexdigest()

    def _set_last_apply_state(self, server: Server, state: Dict[str, Any], ttl: int = 1800) -> None:
        cache_set(self._get_apply_state_cache_key(server), state, ttl=ttl)
        try:
            sid = getattr(server, "id", None)
            rev = str((state or {}).get("config_revision") or "")
            st = str((state or {}).get("status") or "").lower()
            if sid is not None and rev and st in ("applied", "failed", "error"):
                from core.xray_apply_notify import publish_xray_apply_state

                publish_xray_apply_state(int(sid), rev, st)
        except Exception:
            pass

    def set_last_apply_state(self, server: Server, state: Dict[str, Any], ttl: int = 1800) -> None:
        """Публичная обертка для обновления apply-state из внешних задач."""
        self._set_last_apply_state(server, state, ttl=ttl)

    def get_last_apply_state(self, server: Server) -> Optional[Dict[str, Any]]:
        return cache_get(self._get_apply_state_cache_key(server))

    def set_staged_config(self, server: Server, config: Dict[str, Any], ttl: int = 1800) -> Dict[str, Any]:
        payload = {
            "config": config,
            "config_revision": self._calc_config_revision(config),
            "config_sha256": self._calc_config_sha256(config),
            "updated_at": datetime.utcnow().isoformat() + "Z",
        }
        cache_set(self._get_staged_config_cache_key(server), payload, ttl=ttl)
        return payload

    def get_staged_config(self, server: Server) -> Optional[Dict[str, Any]]:
        return cache_get(self._get_staged_config_cache_key(server))

    def clear_staged_config(self, server: Server) -> None:
        cache_set(self._get_staged_config_cache_key(server), None, ttl=1)

    def _mark_apply_health(self, server_id: int, success: bool) -> None:
        now = time.time()
        key = _apply_health_key(server_id)
        bucket = cache_get(key) or {"events": []}
        events = list(bucket.get("events") or [])
        events.append({"ts": now, "ok": bool(success)})
        window_sec = max(30, int(getattr(settings, "xray_apply_autoblock_window_sec", 300) or 300))
        floor = now - window_sec
        events = [x for x in events if float(x.get("ts", 0)) >= floor]
        cache_set(key, {"events": events}, ttl=max(window_sec * 2, 600))

    def _should_block_apply(self, server_id: int) -> bool:
        if not bool(getattr(settings, "xray_apply_auto_block_enabled", True)):
            return False
        if cache_get(_apply_block_key(server_id)):
            return True
        bucket = cache_get(_apply_health_key(server_id)) or {}
        events = list(bucket.get("events") or [])
        if not events:
            return False
        min_events = max(1, int(getattr(settings, "xray_apply_autoblock_min_events", 5) or 5))
        if len(events) < min_events:
            return False
        failures = sum(1 for x in events if not bool(x.get("ok")))
        ratio = failures / max(len(events), 1)
        threshold = float(getattr(settings, "xray_apply_autoblock_error_ratio", 0.6) or 0.6)
        if ratio >= threshold:
            now = time.time()
            ttl = max(30, int(getattr(settings, "xray_apply_autoblock_ttl_sec", 180) or 180))
            cache_set(_apply_block_key(server_id), {"blocked_at": now}, ttl=ttl)
            return True
        return False

    def _apply_config_with_ack(
        self,
        server: Server,
        config: Dict[str, Any],
        *,
        celery_ok: bool,
    ) -> Dict[str, Any]:
        """
        Единая pipeline-модель применения Xray конфига:
        - queued/celery_task
        - queued/edge_assignment
        - applied/sync_ssh
        - failed/none
        """
        revision = self._calc_config_revision(config)
        full_sha256 = self._calc_config_sha256(config)
        now = datetime.utcnow().isoformat() + "Z"
        state: Dict[str, Any] = {
            "status": "failed",
            "ack_mode": "none",
            "apply_branch": "unknown",
            "config_revision": revision,
            "config_sha256": full_sha256,
            "updated_at": now,
        }

        server_id = int(getattr(server, "id", 0) or 0)
        if self._should_block_apply(server_id):
            state.update(
                {
                    "status": "blocked",
                    "ack_mode": "none",
                    "apply_branch": "autoblock",
                    "reason_code": "apply_autoblocked",
                }
            )
            return state

        # Emergency deterministic path: for connect reliability, apply synchronously and
        # return explicit applied/failed result without background queues.
        if bool(getattr(settings, "xray_force_sync_apply", False)):
            started = time.monotonic()
            success = self.apply_config_to_server(server, config)
            apply_ms = int((time.monotonic() - started) * 1000)
            state.update(
                {
                    "status": "applied" if success else "failed",
                    "ack_mode": "sync_ssh",
                    "apply_branch": "sync_inline_forced",
                    "apply_duration_ms": apply_ms,
                }
            )
            return state

        if not celery_ok:
            logger.warning(
                "Celery worker недоступен, применяем Xray конфиг через edge/SSH для server_id=%s",
                server.id,
            )
            assignment_id = _try_enqueue_edge_apply(server, config)
            if assignment_id:
                state.update(
                    {
                        "status": "queued",
                        "ack_mode": "edge_assignment",
                        "apply_branch": "edge_no_celery",
                        "edge_assignment_id": assignment_id,
                    }
                )
                return state

            state.update(
                {
                    "status": "queued",
                    "ack_mode": "background_thread",
                    "apply_branch": "sync_ssh_background_no_celery",
                }
            )
            _run_sync_apply_in_background(server, config, "sync_ssh_background_no_celery")
            return state

        try:
            from services.tasks.vpn_tasks import apply_xray_config_to_vpn

            task = apply_xray_config_to_vpn.delay(server.id, json.dumps(config))
            state.update(
                {
                    "status": "queued",
                    "ack_mode": "celery_task",
                    "apply_branch": "celery_async",
                    "celery_task_id": getattr(task, "id", None),
                }
            )
            return state
        except Exception as e:
            logger.warning("Фоновая задача Xray недоступна, fallback на edge/SSH: %s", e)
            assignment_id = _try_enqueue_edge_apply(server, config)
            if assignment_id:
                state.update(
                    {
                        "status": "queued",
                        "ack_mode": "edge_assignment",
                        "apply_branch": "edge_after_celery_fail",
                        "edge_assignment_id": assignment_id,
                    }
                )
                return state

            state.update(
                {
                    "status": "queued",
                    "ack_mode": "background_thread",
                    "apply_branch": "sync_ssh_background_after_celery_fail",
                }
            )
            _run_sync_apply_in_background(server, config, "sync_ssh_background_after_celery_fail")
            return state

    def apply_config_to_server(self, server: Server, config: Dict[str, Any]) -> bool:
        """
        Записывает конфиг на VPN-сервер и перезагружает Xray в одном SSH-сеансе.
        Вызывается из фоновой задачи после быстрого ответа create-client.
        """
        if not self.remote_manager or not self.remote_manager.ssh_manager:
            logger.warning("SSH недоступен для apply_config_to_server")
            self._mark_apply_health(int(getattr(server, "id", 0) or 0), False)
            return False
        _ensure_xray_data_plane_guardrails(config)
        config_path = self._get_xray_config_path(server)
        config_json = json.dumps(config, indent=2)

        def do_in_one_session(client):
            sftp = client.open_sftp()
            try:
                with sftp.file(config_path, "w") as f:
                    f.write(config_json)
            finally:
                sftp.close()
            stdin, stdout, stderr = client.exec_command(f"chmod 644 {config_path}", timeout=10)
            stdout.channel.recv_exit_status()
            self._reload_or_restart_in_session(
                client,
                server,
                context="apply_config_to_server",
            )

            # Post-apply guard: не оставляем ноду в inactive/port-down после reload.
            active_state = "unknown"
            active_unit = None
            for unit in self._xray_unit_candidates():
                stdin, stdout, stderr = client.exec_command(
                    f"systemctl is-active {unit} || true",
                    timeout=10,
                )
                state = stdout.read().decode("utf-8", errors="ignore").strip().lower()
                if state == "active":
                    active_state = state
                    active_unit = unit
                    break
            if active_state != "active":
                logger.warning(
                    "apply_config_to_server: server_id=%s xray_not_active_after_apply state=%s; forcing restart",
                    getattr(server, "id", None),
                    active_state or "unknown",
                )
                with _service_action_lock(int(getattr(server, "id", 0) or 0)):
                    restart_guard = self._exec_systemctl_with_fallback_in_session(
                        client,
                        "restart",
                        timeout=30,
                    )
                restart_after_guard_raw = restart_guard.get("exit_status")
                restart_after_guard_exit = (
                    int(restart_after_guard_raw) if restart_after_guard_raw is not None else -1
                )
                if restart_after_guard_exit != 0:
                    restart_after_guard_err = str(restart_guard.get("stderr") or "").strip()
                    raise RuntimeError(
                        f"xray restart failed in post-apply guard: exit={restart_after_guard_exit} err={restart_after_guard_err[:300]}"
                    )
                active_state = "unknown"
                active_unit = None
                for unit in self._xray_unit_candidates():
                    stdin, stdout, stderr = client.exec_command(
                        f"systemctl is-active {unit} || true",
                        timeout=10,
                    )
                    state = stdout.read().decode("utf-8", errors="ignore").strip().lower()
                    if state == "active":
                        active_state = state
                        active_unit = unit
                        break
                if active_state != "active":
                    raise RuntimeError(
                        f"xray not active after post-apply restart: state={active_state or 'unknown'}"
                    )
            if active_unit:
                logger.info(
                    "apply_config_to_server: server_id=%s active_unit=%s",
                    getattr(server, "id", None),
                    active_unit,
                )

            # Post-apply stabilization: проверяем, что все inbound порты реально слушаются.
            # Это закрывает окно, когда reload уже завершился, но data-plane еще не готов.
            ports: set[int] = set()
            try:
                for inbound in (config.get("inbounds") or []):
                    port_val = inbound.get("port")
                    if isinstance(port_val, int) and port_val > 0:
                        ports.add(port_val)
            except Exception:
                ports = set()
            if not ports:
                ports = {4443}

            max_attempts = 6
            check_delay_sec = 1.0
            last_missing: list[int] = []
            for _ in range(max_attempts):
                missing: list[int] = []
                for port in sorted(ports):
                    stdin, stdout, stderr = client.exec_command(
                        f"ss -ltn '( sport = :{port} )' | wc -l",
                        timeout=10,
                    )
                    listen_rows_raw = stdout.read().decode("utf-8", errors="ignore").strip()
                    try:
                        listen_rows = int(listen_rows_raw or "0")
                    except ValueError:
                        listen_rows = 0
                    if listen_rows < 2:
                        missing.append(port)
                if not missing:
                    break
                last_missing = missing
                time.sleep(check_delay_sec)
            if last_missing:
                raise RuntimeError(
                    f"xray inbound ports not listening after apply: {last_missing}"
                )
            return True

        try:
            self.remote_manager.with_ssh_connection(server, do_in_one_session)
            self._mark_apply_health(int(getattr(server, "id", 0) or 0), True)
            return True
        except Exception as e:
            logger.error("Ошибка применения конфига Xray на сервер %s: %s", server.id, e, exc_info=True)
            self._mark_apply_health(int(getattr(server, "id", 0) or 0), False)
            return False
    
    def _read_xray_config(self, server: Server) -> Dict[str, Any]:
        """Читает конфигурацию Xray с сервера"""
        if not self.remote_manager or not self.remote_manager.ssh_manager:
            raise Exception("SSH недоступен для чтения конфигурации")
        
        ssh_config = self._get_ssh_config(server)
        config_path = self._get_xray_config_path(server)
        
        config_content = self.remote_manager.ssh_manager.download_content(
            ssh_config['host'],
            config_path,
            ssh_config['port'],
            ssh_config['username'],
            ssh_config.get('key_path'),
            ssh_config.get('key_content'),
            ssh_config.get('password')
        )
        
        if not config_content:
            # Если конфигурации нет, создаем базовую
            config = {
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
            _ensure_xray_logging_contract(config)
            _ensure_xray_data_plane_guardrails(config)
            _ensure_xray_transport_tuning(config)
            return config

        config = json.loads(config_content)
        _ensure_xray_logging_contract(config)
        _ensure_xray_data_plane_guardrails(config)
        _ensure_xray_transport_tuning(config)
        return config

    def _acquire_config_lock(
        self,
        server: Server,
        lock_path: str,
        timeout_seconds: int = 20,
        poll_interval: float = 0.5
    ) -> bool:
        """Пытается получить блокировку конфигурации на сервере."""
        if not self.remote_manager or not self.remote_manager.ssh_manager:
            raise Exception("SSH недоступен для блокировки конфигурации")

        ssh_config = self._get_ssh_config(server)
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            result = self.remote_manager.ssh_manager.execute_command(
                ssh_config['host'],
                f"mkdir {lock_path}",
                ssh_config['port'],
                ssh_config['username'],
                ssh_config.get('key_path'),
                ssh_config.get('key_content'),
                ssh_config.get('password')
            )
            if result.get('success'):
                return True
            time.sleep(poll_interval)

        logger.warning(f"Не удалось получить блокировку Xray конфигурации на {server.id}")
        return False

    def _release_config_lock(self, server: Server, lock_path: str) -> None:
        """Освобождает блокировку конфигурации на сервере."""
        if not self.remote_manager or not self.remote_manager.ssh_manager:
            return

        ssh_config = self._get_ssh_config(server)
        self.remote_manager.ssh_manager.execute_command(
            ssh_config['host'],
            f"rmdir {lock_path} 2>/dev/null",
            ssh_config['port'],
            ssh_config['username'],
            ssh_config.get('key_path'),
            ssh_config.get('key_content'),
            ssh_config.get('password')
        )

    def _dedupe_xray_config(self, config: Dict[str, Any]) -> int:
        """Удаляет дубликаты клиентов по email внутри inbound."""
        removed = 0
        for inbound in config.get('inbounds', []):
            settings = inbound.get('settings') or {}
            clients = settings.get('clients')
            if not clients:
                continue

            seen_emails = set()
            deduped = []
            for client in clients:
                email = client.get('email')
                if email:
                    if email in seen_emails:
                        removed += 1
                        continue
                    seen_emails.add(email)
                deduped.append(client)

            inbound['settings'] = settings
            inbound['settings']['clients'] = deduped

        return removed

    def _update_xray_config_and_reload(
        self,
        server: Server,
        update_fn: Callable[[Dict[str, Any]], Any],
    ) -> Any:
        """
        Читает, обновляет, пишет конфигурацию Xray и перезагружает сервис в одном SSH-сеансе.
        Оптимизация: один TCP/SSH handshake вместо нескольких (lock, read, write, chmod, release, reload).
        """
        if not self.remote_manager or not self.remote_manager.ssh_manager:
            raise Exception("SSH недоступен для обновления конфигурации Xray")

        config_path = self._get_xray_config_path(server)
        lock_path = "/tmp/grani-xray-config.lock"
        timeout_seconds = 20
        poll_interval = 0.5
        deadline = time.time() + timeout_seconds

        def do_in_one_session(client):
            # 1. Acquire lock (retry loop)
            while time.time() < deadline:
                stdin, stdout, stderr = client.exec_command(f"mkdir {lock_path} 2>/dev/null", timeout=10)
                exit_status = stdout.channel.recv_exit_status()
                if exit_status == 0:
                    break
                time.sleep(poll_interval)
            else:
                raise Exception("Не удалось получить блокировку Xray конфигурации")

            try:
                # 2. Read config via SFTP
                sftp = client.open_sftp()
                try:
                    with sftp.file(config_path, "r") as f:
                        config_content = f.read().decode("utf-8", errors="ignore")
                except FileNotFoundError:
                    config_content = None
                finally:
                    sftp.close()

                if not config_content:
                    config = {
                        "log": {"loglevel": "warning"},
                        "inbounds": [],
                        "outbounds": [
                            {"protocol": "freedom", "settings": {}},
                            {"protocol": "blackhole", "settings": {}, "tag": "blocked"},
                        ],
                        "routing": {
                            "rules": [
                                {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"},
                            ]
                        },
                    }
                else:
                    config = json.loads(config_content)
                _ensure_xray_logging_contract(config)
                _ensure_xray_data_plane_guardrails(config)
                _ensure_xray_transport_tuning(config)

                # 3. Update and dedupe
                result = update_fn(config)
                removed = self._dedupe_xray_config(config)
                if removed:
                    logger.warning("Удалено дубликатов клиентов в конфигурации Xray: %s", removed)
                _ensure_xray_logging_contract(config)
                _ensure_xray_transport_tuning(config)

                config_json = json.dumps(config, indent=2)

                # 4. Write config via SFTP (no synchronous backup to save time)
                sftp = client.open_sftp()
                try:
                    with sftp.file(config_path, "w") as f:
                        f.write(config_json)
                finally:
                    sftp.close()

                # 5. Chmod
                stdin, stdout, stderr = client.exec_command(f"chmod 644 {config_path}", timeout=10)
                stdout.channel.recv_exit_status()

                # 6. Release lock
                stdin, stdout, stderr = client.exec_command(f"rmdir {lock_path} 2>/dev/null", timeout=5)
                stdout.channel.recv_exit_status()

                # 7. Prefer reload to avoid session drops, fallback to restart if needed.
                self._reload_or_restart_in_session(
                    client,
                    server,
                    context="_update_xray_config_and_reload",
                )

                return result
            except Exception:
                # Best-effort release lock on error
                try:
                    client.exec_command(f"rmdir {lock_path} 2>/dev/null", timeout=5)
                except Exception:
                    pass
                raise

        return self.remote_manager.with_ssh_connection(server, do_in_one_session)

    def _update_xray_config_async(
        self,
        server: Server,
        update_fn: Callable[[Dict[str, Any]], Any],
    ) -> Any:
        """
        Быстрый путь: конфиг из кэша (или один раз с VPN), обновление в памяти, ответ сразу,
        применение на VPN в фоне (Celery) или синхронно при недоступности очереди.
        """
        with _server_lock(server.id):
            t_block = time.monotonic()
            config = self._get_cached_xray_config(server)
            read_ms = 0
            if config is None:
                config_source = "ssh_read"
                t_read = time.monotonic()
                config = self._read_xray_config(server)
                read_ms = int((time.monotonic() - t_read) * 1000)
                self._set_cached_xray_config(server, config)
            else:
                config_source = "redis"

            before_bytes = _stable_config_bytes(config)

            t_uf = time.monotonic()
            result = update_fn(config)
            update_fn_ms = int((time.monotonic() - t_uf) * 1000)

            removed = self._dedupe_xray_config(config)
            if removed:
                logger.warning("Удалено дубликатов клиентов в конфигурации Xray: %s", removed)
            self._set_cached_xray_config(server, config)

            after_bytes = _stable_config_bytes(config)
            config_changed = before_bytes != after_bytes

            if config_changed:
                staged = self.set_staged_config(server, config)
                stage_only = bool(getattr(settings, "xray_prepare_stage_only", True))
                apply_enabled = bool(getattr(settings, "xray_prepare_apply_enabled", True))
                if stage_only or not apply_enabled:
                    apply_state = {
                        "status": "staged",
                        "ack_mode": "none",
                        "apply_branch": "prepare_stage_only",
                        "config_revision": staged.get("config_revision"),
                        "config_sha256": staged.get("config_sha256"),
                        "updated_at": datetime.utcnow().isoformat() + "Z",
                        "reason_code": "prepare_stage_only" if stage_only else "prepare_apply_disabled",
                    }
                    celery_ok = _is_celery_worker_available()
                    self._set_last_apply_state(server, apply_state)
                else:
                    min_interval_sec = float(
                        getattr(settings, "xray_apply_min_interval_sec", 0)
                        or 25
                    )
                    prev_state = self.get_last_apply_state(server) or {}
                    prev_updated = _parse_iso_utc(prev_state.get("updated_at"))
                    now_utc = datetime.utcnow()
                    elapsed_sec: Optional[float] = None
                    if prev_updated is not None:
                        try:
                            elapsed_sec = (now_utc - prev_updated.replace(tzinfo=None)).total_seconds()
                        except Exception:
                            elapsed_sec = None

                    prev_status = str(prev_state.get("status") or "")
                    can_debounce = (
                        min_interval_sec > 0
                        and elapsed_sec is not None
                        and elapsed_sec >= 0
                        and elapsed_sec < min_interval_sec
                        and prev_status in {"queued", "applied"}
                    )

                    if can_debounce:
                        delay_sec = max(min_interval_sec - elapsed_sec, 0.1)
                        _schedule_debounced_apply(server, config, delay_sec)
                        apply_state = {
                            "status": "queued",
                            "ack_mode": "throttled_debounce",
                            "apply_branch": "debounced_queue",
                            "config_revision": self._calc_config_revision(config),
                            "config_sha256": self._calc_config_sha256(config),
                            "updated_at": now_utc.isoformat() + "Z",
                            "scheduled_in_ms": int(delay_sec * 1000),
                            "previous_status": prev_status or None,
                        }
                        celery_ok = _is_celery_worker_available()
                        self._set_last_apply_state(server, apply_state)
                    else:
                        celery_ok = _is_celery_worker_available()
                        apply_state = self._apply_config_with_ack(server, config, celery_ok=celery_ok)
                        self._set_last_apply_state(server, apply_state)
            else:
                apply_state = self.get_last_apply_state(server) or {
                    "status": "applied",
                    "ack_mode": "none",
                    "apply_branch": "no_change_skip_apply",
                    "config_revision": self._calc_config_revision(config),
                    "config_sha256": self._calc_config_sha256(config),
                    "updated_at": datetime.utcnow().isoformat() + "Z",
                }
                celery_ok = _is_celery_worker_available()

            total_ms = int((time.monotonic() - t_block) * 1000)
            logger.info(
                "[xray_prepare_update] server_id=%s config_source=%s read_ms=%s update_fn_ms=%s "
                "config_changed=%s "
                "celery_ping_ok=%s apply_branch=%s apply_status=%s ack_mode=%s "
                "task_id=%s assignment_id=%s apply_extra_ms=%s config_revision=%s total_ms=%s",
                getattr(server, "id", None),
                config_source,
                read_ms,
                update_fn_ms,
                config_changed,
                celery_ok,
                apply_state.get("apply_branch"),
                apply_state.get("status"),
                apply_state.get("ack_mode"),
                apply_state.get("celery_task_id"),
                apply_state.get("edge_assignment_id"),
                apply_state.get("apply_duration_ms", 0),
                apply_state.get("config_revision"),
                total_ms,
            )
            return result

    def _update_xray_config(
        self,
        server: Server,
        update_fn: Callable[[Dict[str, Any]], Any]
    ) -> Any:
        """Читает, обновляет и пишет конфигурацию Xray. Использует кэш + асинхронное применение для быстрого ответа."""
        return self._update_xray_config_async(server, update_fn)

    def commit_staged_config(self, server: Server) -> Dict[str, Any]:
        """
        Phase-2 commit: применяет последний staged конфиг.
        Используется для поэтапного rollout, когда prepare работает в stage-only режиме.
        """
        staged = self.get_staged_config(server) or {}
        config = staged.get("config")
        if not isinstance(config, dict):
            return {
                "status": "noop",
                "reason_code": "no_staged_config",
            }
        celery_ok = _is_celery_worker_available()
        apply_state = self._apply_config_with_ack(server, config, celery_ok=celery_ok)
        apply_state["apply_branch"] = "commit_staged"
        self._set_last_apply_state(server, apply_state)
        return apply_state
    
    def _write_xray_config(self, server: Server, config: Dict[str, Any]) -> bool:
        """Записывает конфигурацию Xray на сервер (атомарно: .tmp → .bak → rename)."""
        if not self.remote_manager or not self.remote_manager.ssh_manager:
            raise Exception("SSH недоступен для записи конфигурации")

        server_id = getattr(server, "id", 0) or 0
        with _server_lock(server_id):
            ssh_config = self._get_ssh_config(server)
            config_path = self._get_xray_config_path(server)
            _ensure_xray_logging_contract(config)
            config_json = json.dumps(config, indent=2)
            success = self.remote_manager.ssh_manager.upload_content_atomic(
                ssh_config['host'],
                config_json,
                config_path,
                ssh_config['port'],
                ssh_config['username'],
                ssh_config.get('key_path'),
                ssh_config.get('key_content'),
                ssh_config.get('password'),
            )
            if success:
                self.remote_manager.ssh_manager.execute_command(
                    ssh_config['host'],
                    f"chmod 644 {config_path}",
                    ssh_config['port'],
                    ssh_config['username'],
                    ssh_config.get('key_path'),
                    ssh_config.get('key_content'),
                    ssh_config.get('password'),
                )
            return success
    
    def _reload_xray(self, server: Server) -> bool:
        """Перезагружает Xray на сервере (reload с fallback на restart)."""
        if not self.remote_manager or not self.remote_manager.ssh_manager:
            logger.warning("SSH недоступен, пропускаем перезагрузку Xray")
            return False
        
        ssh_config = self._get_ssh_config(server)
        
        with _service_action_lock(int(getattr(server, "id", 0) or 0)):
            result = self._exec_systemctl_with_fallback(ssh_config, "reload")
            exit_reload = result.get("exit_status")
            if result["success"]:
                logger.info(
                    "xray_reload: server_id=%s action=reload exit=%s unit=%s stderr_len=%s",
                    getattr(server, "id", None),
                    exit_reload,
                    result.get("unit"),
                    len((result.get("stderr") or "")),
                )
                return True

            stderr_reload = (result.get("stderr") or "").strip()
            logger.warning(
                "xray_reload: server_id=%s reload_failed exit=%s unit=%s stderr=%s; fallback=restart",
                getattr(server, "id", None),
                exit_reload,
                result.get("unit"),
                stderr_reload[:500] if stderr_reload else "",
            )
            restart_result = self._exec_systemctl_with_fallback(ssh_config, "restart")
            exit_restart = restart_result.get("exit_status")
            if restart_result["success"]:
                logger.info(
                    "xray_reload: server_id=%s action=restart_after_reload_fail exit=%s unit=%s stderr_len=%s",
                    getattr(server, "id", None),
                    exit_restart,
                    restart_result.get("unit"),
                    len((restart_result.get("stderr") or "")),
                )
                return True
            stderr_restart = (restart_result.get("stderr") or "").strip()
            logger.error(
                "xray_reload: server_id=%s restart_failed exit=%s unit=%s stderr=%s",
                getattr(server, "id", None),
                exit_restart,
                restart_result.get("unit"),
                stderr_restart[:500] if stderr_restart else "",
            )
            return False
    
    def _find_inbound(self, config: Dict[str, Any], protocol: str) -> Optional[Dict[str, Any]]:
        """Находит inbound для указанного протокола"""
        for inbound in config.get('inbounds', []):
            if inbound.get('protocol') == protocol:
                return inbound
        return None

    def _find_inbound_by_security(
        self,
        config: Dict[str, Any],
        protocol: str,
        security: Optional[str]
    ) -> Optional[Dict[str, Any]]:
        """Находит inbound по протоколу и security (если указано)."""
        for inbound in config.get('inbounds', []):
            if inbound.get('protocol') != protocol:
                continue
            if security is None:
                return inbound
            stream = inbound.get('streamSettings') or {}
            if stream.get('security') == security:
                return inbound
        return None

    def _has_client_uuid(
        self,
        config: Dict[str, Any],
        protocol: str,
        security: str,
        client_uuid: str,
    ) -> bool:
        """Проверяет, что UUID клиента присутствует в конфиге (после reload / verify)."""
        inbound = self._find_inbound_by_security(config, protocol, security)
        if not inbound:
            return False
        clients = (inbound.get("settings") or {}).get("clients") or []
        return any(c.get("id") == client_uuid for c in clients)

    def _get_default_inbound_port(self, protocol: str, server: Server, security: Optional[str]) -> int:
        """Возвращает дефолтный порт для inbound с учетом протокола и security."""
        # REALITY: server.xray_port или XRAY_REALITY_DEFAULT_PORT (443 часто под nginx API)
        if protocol == "vless" and security == "reality":
            return server.xray_port or XRAY_REALITY_DEFAULT_PORT
        # VLESS без обфускации — выделенный порт, чтобы не конфликтовать с REALITY
        if protocol == "vless":
            return XRAY_VLESS_DEFAULT_PORT
        # VMESS — отдельный порт, чтобы не конфликтовать с REALITY
        if protocol == "vmess":
            return XRAY_VMESS_DEFAULT_PORT
        return server.xray_port or XRAY_DEFAULT_PORT

    def _get_inbound_port(self, inbound: Optional[Dict[str, Any]], fallback: int) -> int:
        """Извлекает порт из inbound или использует fallback."""
        if inbound and isinstance(inbound.get('port'), int):
            return inbound['port']
        return fallback

    def _find_available_port(self, config: Dict[str, Any], desired: int) -> int:
        """Возвращает desired порт, если свободен; иначе первый свободный порт."""
        used = {ib.get('port') for ib in config.get('inbounds', []) if isinstance(ib.get('port'), int)}
        if desired not in used:
            return desired
        for p in range(desired + 1, desired + 100):
            if p not in used:
                logger.info(f"Порт {desired} занят, используем {p}")
                return p
        return desired + 1  # fallback

    def _get_or_create_inbound(
        self,
        config: Dict[str, Any],
        protocol: str,
        server: Server,
        security: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        Получает или создает inbound для указанного протокола и security.
        ВАЖНО: для VLESS передавать security ("none" или "reality"), иначе при наличии
        REALITY inbound plain-VLESS клиент может быть ошибочно добавлен в него.
        """
        if security is not None:
            inbound = self._find_inbound_by_security(config, protocol, security)
        else:
            inbound = self._find_inbound(config, protocol)

        if not inbound:
            # Создаем новый inbound
            effective_security = security or "none"
            desired_port = self._get_default_inbound_port(protocol, server, effective_security)
            port = self._find_available_port(config, desired_port)
            
            if protocol == "vless":
                inbound = {
                    "port": port,
                    "protocol": "vless",
                    "settings": {
                        "clients": [],
                        "decryption": "none"
                    },
                    "streamSettings": {
                        "network": "tcp",
                        "security": effective_security,
                        "tcpSettings": {
                            "acceptProxyProtocol": False
                        }
                    }
                }
            elif protocol == "vmess":
                inbound = {
                    "port": port,
                    "protocol": "vmess",
                    "settings": {
                        "clients": []
                    },
                    "streamSettings": {
                        "network": "tcp",
                        "security": "none"
                    }
                }
            else:
                raise Exception(f"Неподдерживаемый протокол для создания inbound: {protocol}")
            
            config.setdefault('inbounds', []).append(inbound)
        
        return inbound

    def _try_fast_path_return_config(
        self,
        server: Server,
        protocol_kind: str,
        security: str,
        device: Device,
        client_id: str,
    ) -> Optional[Dict[str, Any]]:
        """
        Быстрый путь: если клиент уже есть в кэшированном конфиге сервера,
        возвращаем конфиг без SSH/Celery. Иначе None.
        """
        config = self._get_cached_xray_config(server)
        if not config:
            return None
        inbound = self._find_inbound_by_security(config, protocol_kind, security)
        if not inbound:
            return None
        client_email = f"{device.user_id}_{device.id}@granivpn.com"
        clients = inbound.get('settings', {}).get('clients', [])
        existing = next((c for c in clients if c.get('email') == client_email), None)
        if not existing or not existing.get('id'):
            return None
        client_uuid = existing['id']
        default_port = (
            self._get_default_inbound_port("vless", server, "reality")
            if security == "reality"
            else self._get_default_inbound_port(protocol_kind, server, security)
        )
        port = self._get_inbound_port(inbound, default_port)
        if protocol_kind == "vless" and security == "reality":
            config_url = self._generate_reality_config_url(client_uuid, server, port)
        elif protocol_kind == "vless":
            config_url = self._generate_vless_config_url(client_uuid, server, port)
        elif protocol_kind == "vmess":
            config_url = self._generate_vmess_config_url(client_uuid, server, port)
        else:
            config_url = self._generate_reality_config_url(client_uuid, server, port)
        logger.info(f"Create-client fast path: клиент уже в кэше, client_id={client_id}")
        apply_state = self.get_last_apply_state(server)
        return {
            "client_id": client_id,
            "config": config_url,
            "ip_address": server.ip_address,
            "success": True,
            "uuid": client_uuid,
            "apply_state": apply_state,
            "apply_required": False,
        }

    def create_vless_client(self, device: Device, server: Server) -> Dict[str, Any]:
        """Создание VLESS клиента"""
        try:
            logger.info(f"Создание VLESS клиента для device_id={device.id}, server_id={server.id}")
            client_id = f"vless_{device.id}_{server.id}"
            fast = self._try_fast_path_return_config(server, "vless", "none", device, client_id)
            if fast:
                return fast

            # Генерируем UUID для клиента
            client_uuid = str(uuid.uuid4())
            client_email = f"{device.user_id}_{device.id}@granivpn.com"
            
            def update_config(config: Dict[str, Any]) -> Dict[str, Any]:
                nonlocal client_uuid
                # Находим или создаем VLESS inbound (security=none).
                # ВАЖНО: передаём security="none" в _get_or_create_inbound, иначе при наличии
                # REALITY inbound он вернёт его и plain-VLESS клиент попадёт в REALITY → connection reset.
                inbound = self._find_inbound_by_security(config, "vless", "none")
                if not inbound:
                    inbound = self._get_or_create_inbound(config, "vless", server, "none")

                # Проверяем, есть ли уже клиент с таким email
                clients = inbound.get('settings', {}).get('clients', [])
                existing_client = next(
                    (c for c in clients if c.get('email') == client_email),
                    None
                )

                if existing_client:
                    client_uuid = existing_client['id']
                    if existing_client.get('alterId') is None:
                        existing_client['alterId'] = 0
                    logger.info(f"Клиент уже существует: {client_uuid}")
                else:
                    # Добавляем нового клиента
                    clients.append({
                        'id': client_uuid,
                        'alterId': 0,
                        'level': 0,
                        'email': client_email
                    })
                    inbound['settings']['clients'] = clients

                return inbound

            inbound = self._update_xray_config(server, update_config)
            
            # Генерируем конфигурационный URL с учетом порта inbound
            port = self._get_inbound_port(
                inbound,
                self._get_default_inbound_port("vless", server, "none")
            )
            config_url = self._generate_vless_config_url(client_uuid, server, port)
            
            logger.info(f"VLESS клиент успешно создан: {client_id}, UUID: {client_uuid}")
            apply_state = self.get_last_apply_state(server)
            
            return {
                "client_id": client_id,
                "config": config_url,
                "ip_address": server.ip_address,
                "success": True,
                "uuid": client_uuid,
                "apply_state": apply_state,
                "apply_required": True,
            }
            
        except Exception as e:
            logger.error(f"Ошибка создания VLESS клиента: {e}", exc_info=True)
            return {
                "client_id": f"vless_{device.id}_{server.id}",
                "config": "",
                "ip_address": server.ip_address,
                "success": False,
                "error": str(e)
            }
    
    def create_vmess_client(self, device: Device, server: Server) -> Dict[str, Any]:
        """Создание VMESS клиента"""
        try:
            logger.info(f"Создание VMESS клиента для device_id={device.id}, server_id={server.id}")
            client_id = f"vmess_{device.id}_{server.id}"
            fast = self._try_fast_path_return_config(server, "vmess", "none", device, client_id)
            if fast:
                return fast

            # Генерируем UUID для клиента
            client_uuid = str(uuid.uuid4())
            client_email = f"{device.user_id}_{device.id}@granivpn.com"
            
            def update_config(config: Dict[str, Any]) -> Dict[str, Any]:
                nonlocal client_uuid
                # Находим или создаем VMESS inbound (security=none)
                inbound = self._find_inbound_by_security(config, "vmess", "none")
                if not inbound:
                    inbound = self._get_or_create_inbound(config, "vmess", server)
                self._ensure_vmess_inbound_settings(inbound)
                expected_port = self._get_default_inbound_port("vmess", server, "none")
                if inbound.get("port") != expected_port:
                    logger.info(
                        "VMESS inbound порт %s обновлен на %s",
                        inbound.get("port"),
                        expected_port
                    )
                    inbound["port"] = expected_port

                # Проверяем, есть ли уже клиент с таким email
                clients = inbound.get('settings', {}).get('clients', [])
                existing_client = next(
                    (c for c in clients if c.get('email') == client_email),
                    None
                )

                if existing_client:
                    client_uuid = existing_client['id']
                    if existing_client.get('alterId') is None:
                        existing_client['alterId'] = 0
                    if existing_client.get('security') is None:
                        existing_client['security'] = 'none'
                    logger.info(f"Клиент уже существует: {client_uuid}")
                else:
                    # Добавляем нового клиента
                    clients.append({
                        'id': client_uuid,
                        'alterId': 0,
                        'level': 0,
                        'security': 'none',
                        'email': client_email
                    })
                    inbound['settings']['clients'] = clients

                return inbound

            inbound = self._update_xray_config(server, update_config)
            
            # Генерируем конфигурационный URL с учетом порта inbound
            port = self._get_inbound_port(
                inbound,
                self._get_default_inbound_port("vmess", server, "none")
            )
            config_url = self._generate_vmess_config_url(client_uuid, server, port)
            
            logger.info(f"VMESS клиент успешно создан: {client_id}, UUID: {client_uuid}")
            apply_state = self.get_last_apply_state(server)
            
            return {
                "client_id": client_id,
                "config": config_url,
                "ip_address": server.ip_address,
                "success": True,
                "uuid": client_uuid,
                "apply_state": apply_state,
                "apply_required": True,
            }
            
        except Exception as e:
            logger.error(f"Ошибка создания VMESS клиента: {e}", exc_info=True)
            return {
                "client_id": f"vmess_{device.id}_{server.id}",
                "config": "",
                "ip_address": server.ip_address,
                "success": False,
                "error": str(e)
            }
    
    def create_reality_client(self, device: Device, server: Server) -> Dict[str, Any]:
        """Создание REALITY клиента"""
        try:
            logger.info(f"Создание REALITY клиента для device_id={device.id}, server_id={server.id}")
            
            if not server.reality_enabled:
                raise Exception("REALITY не включен на этом сервере")

            # REALITY требует корректных ключей на сервере
            if not getattr(server, "reality_private_key", None):
                raise Exception("REALITY на сервере не настроен: отсутствует reality_private_key")
            if not getattr(server, "reality_public_key", None):
                raise Exception("REALITY на сервере не настроен: отсутствует reality_public_key")
            if not getattr(server, "reality_short_id", None):
                raise Exception("REALITY на сервере не настроен: отсутствует reality_short_id")

            # Дополнительная валидация параметров REALITY
            self._validate_reality_server_params(server)
            default_sni = server.reality_sni or "google.com"
            dest = server.reality_dest or f"{default_sni}:443"
            logger.info(
                "REALITY параметры сервера: sni=%s dest=%s short_id_len=%s public_key_len=%s",
                default_sni,
                dest,
                len(server.reality_short_id or ""),
                len(server.reality_public_key or "")
            )
            client_id = f"reality_{device.id}_{server.id}"
            fast = self._try_fast_path_return_config(server, "vless", "reality", device, client_id)
            if fast:
                return fast

            # Генерируем UUID для клиента
            client_uuid = str(uuid.uuid4())
            client_email = f"{device.user_id}_{device.id}@granivpn.com"
            
            def update_config(config: Dict[str, Any]) -> Dict[str, Any]:
                nonlocal client_uuid
                # Находим или создаем VLESS inbound с REALITY
                inbound = self._find_inbound_by_security(config, "vless", "reality")
                if not inbound:
                    port = self._get_default_inbound_port("vless", server, "reality")
                    inbound = {
                        "port": port,
                        "protocol": "vless",
                        "settings": {
                            "clients": [],
                            "decryption": "none"
                        },
                        "streamSettings": {
                            "network": "tcp",
                            "security": "reality",
                            "realitySettings": {}
                        }
                    }
                    config.setdefault('inbounds', []).append(inbound)

                # Гарантируем корректные настройки REALITY (могли быть неполными)
                self._ensure_reality_inbound_settings(inbound, server)

                # Проверяем, есть ли уже клиент с таким email
                clients = inbound.get('settings', {}).get('clients', [])
                existing_client = next(
                    (c for c in clients if c.get('email') == client_email),
                    None
                )

                if existing_client:
                    client_uuid = existing_client['id']
                    # Не задаем flow для Reality, чтобы избежать несовместимости клиентов
                    logger.info(f"Клиент уже существует: {client_uuid}")
                else:
                    # Добавляем нового клиента
                    clients.append({
                        'id': client_uuid,
                        'level': 0,
                        'email': client_email
                    })
                    inbound['settings']['clients'] = clients

                return inbound

            inbound = self._update_xray_config(server, update_config)
            
            # Генерируем конфигурационный URL с учетом порта inbound
            port = self._get_inbound_port(
                inbound,
                self._get_default_inbound_port("vless", server, "reality")
            )
            config_url = self._generate_reality_config_url(client_uuid, server, port)
            
            logger.info(f"REALITY клиент успешно создан: {client_id}, UUID: {client_uuid}")
            apply_state = self.get_last_apply_state(server)
            
            return {
                "client_id": client_id,
                "config": config_url,
                "ip_address": server.ip_address,
                "success": True,
                "uuid": client_uuid,
                "apply_state": apply_state,
                "apply_required": True,
            }
            
        except Exception as e:
            logger.error(f"Ошибка создания REALITY клиента: {e}", exc_info=True)
            return {
                "client_id": f"reality_{device.id}_{server.id}",
                "config": "",
                "ip_address": server.ip_address,
                "success": False,
                "error": str(e)
            }

    def ensure_reality_server_config(self, server: Server) -> Dict[str, Any]:
        """Синхронизирует REALITY inbound и клиентов на сервере."""
        try:
            self._validate_reality_server_params(server)
            def update_config(config: Dict[str, Any]) -> Dict[str, Any]:
                inbound = self._find_inbound_by_security(config, "vless", "reality")
                created = False

                if not inbound:
                    port = self._get_default_inbound_port("vless", server, "reality")
                    inbound = {
                        "port": port,
                        "protocol": "vless",
                        "settings": {
                            "clients": [],
                            "decryption": "none"
                        },
                        "streamSettings": {
                            "network": "tcp",
                            "security": "reality",
                            "realitySettings": {}
                        }
                    }
                    config.setdefault('inbounds', []).append(inbound)
                    created = True

                updated_settings = self._ensure_reality_inbound_settings(inbound, server)
                clients = inbound.get('settings', {}).get('clients', [])
                updated_clients = 0
                for client in clients:
                    if 'flow' in client:
                        client.pop('flow', None)
                        updated_clients += 1

                inbound['settings']['clients'] = clients

                return {
                    "created": created,
                    "updated_settings": updated_settings,
                    "updated_clients": updated_clients,
                    "total_clients": len(clients)
                }

            update_result = self._update_xray_config(server, update_config)

            return {
                "success": True,
                "created_inbound": update_result["created"],
                "updated_inbound": update_result["updated_settings"],
                "updated_clients": update_result["updated_clients"],
                "total_clients": update_result["total_clients"],
            }
        except Exception as e:
            logger.error(f"Ошибка синхронизации REALITY на сервере {server.id}: {e}", exc_info=True)
            return {"success": False, "error": str(e)}

    def _ensure_reality_inbound_settings(self, inbound: Dict[str, Any], server: Server) -> bool:
        """Обновляет REALITY настройки inbound на основе данных сервера."""
        stream_settings = inbound.setdefault('streamSettings', {})
        stream_settings['network'] = 'tcp'
        stream_settings['security'] = 'reality'

        reality_settings = stream_settings.setdefault('realitySettings', {})
        default_sni = server.reality_sni or "google.com"
        reality_settings.update({
            "show": False,
            "dest": server.reality_dest or f"{default_sni}:443",
            "xver": 0,
            "serverNames": [default_sni],
            "privateKey": server.reality_private_key,
            "shortIds": [server.reality_short_id],
        })
        _sanitize_vless_reality_fallbacks(inbound.setdefault("settings", {}), reality_settings["dest"])

        # Возвращаем True если есть все обязательные поля
        required = ["dest", "serverNames", "privateKey", "shortIds"]
        return all(reality_settings.get(k) for k in required)

    def _ensure_vmess_inbound_settings(self, inbound: Dict[str, Any]) -> bool:
        """Обновляет VMESS настройки inbound до безопасных дефолтов."""
        stream_settings = inbound.setdefault('streamSettings', {})
        updated = False
        if stream_settings.get('network') != 'tcp':
            stream_settings['network'] = 'tcp'
            updated = True
        if stream_settings.get('security') != 'none':
            stream_settings['security'] = 'none'
            updated = True
        return updated

    def _is_valid_host_port(self, value: str) -> bool:
        """Проверяет строку host:port (поддерживает [IPv6]:port)."""
        if not value or not isinstance(value, str):
            return False
        value = value.strip()
        if value.startswith('['):
            match = re.match(r'^\[(.+)\]:(\d+)$', value)
            if not match:
                return False
            host, port_str = match.group(1), match.group(2)
        else:
            if ':' not in value:
                return False
            host, port_str = value.rsplit(':', 1)
        if not host:
            return False
        try:
            port = int(port_str)
        except ValueError:
            return False
        return 1 <= port <= 65535

    def _validate_reality_server_params(self, server: Server) -> None:
        """Валидирует параметры REALITY на сервере перед выдачей клиента."""
        default_sni = server.reality_sni or "google.com"
        dest = server.reality_dest or f"{default_sni}:443"
        if not self._is_valid_host_port(dest):
            raise Exception(f"REALITY dest должен быть в формате host:port (получено: {dest})")
        if not default_sni:
            raise Exception("REALITY serverNames/SNI пустой")
    
    def _generate_vless_config_url(self, uuid: str, server: Server, port: Optional[int] = None) -> str:
        """Генерирует VLESS URL конфигурацию"""
        port = port or self._get_default_inbound_port("vless", server, "none")
        address = server.ip_address
        
        params = {
            'security': 'none',
            'type': 'tcp'
        }
        
        query_string = urlencode(params)
        return f"vless://{uuid}@{address}:{port}?{query_string}#GRANI"
    
    def _generate_vmess_config_url(self, uuid: str, server: Server, port: Optional[int] = None) -> str:
        """Генерирует VMESS URL конфигурацию"""
        port = port or self._get_default_inbound_port("vmess", server, "none")
        address = server.ip_address
        
        params = {
            'v': '2',
            'add': address,
            'port': str(port),
            'id': uuid,
            'aid': '0',
            'scy': 'none',
            'net': 'tcp',
            'type': 'none',
            'host': '',
            'path': '',
            'tls': 'none'
        }
        
        # VMESS URL формат отличается - используем JSON в base64
        import base64
        vmess_config = {
            "v": "2",
            "ps": "GRANI",
            "add": address,
            "port": port,
            "id": uuid,
            "aid": 0,
            "scy": "none",
            "net": "tcp",
            "type": "none",
            "host": "",
            "path": "",
            "tls": "none"
        }
        config_json = json.dumps(vmess_config, separators=(',', ':'))
        config_b64 = base64.b64encode(config_json.encode('utf-8')).decode('utf-8')
        return f"vmess://{config_b64}"
    
    def _generate_reality_config_url(self, uuid: str, server: Server, port: Optional[int] = None) -> str:
        """Генерирует REALITY URL конфигурацию"""
        port = port or self._get_default_inbound_port("vless", server, "reality")
        address = server.ip_address
        
        params = {
            'security': 'reality',
            'type': 'tcp',
            'sni': server.reality_sni or 'google.com',
            'pbk': server.reality_public_key or '',
            'sid': server.reality_short_id or ''
        }
        
        # Удаляем пустые параметры
        params = {k: v for k, v in params.items() if v}
        query_string = urlencode(params)
        return f"vless://{uuid}@{address}:{port}?{query_string}#GRANI-REALITY"
    
    def remove_client(self, client_id: str) -> bool:
        """Удаление клиента из конфигурации XRay"""
        try:
            if not self.server:
                logger.error("XrayManager.remove_client: сервер не указан")
                return False
            
            logger.info(f"Удаление Xray клиента: client_id={client_id}, server_id={self.server.id}")
            
            # Парсим email из client_id
            client_email = self._parse_client_email_from_client_id(client_id, self.server)
            if not client_email:
                logger.warning(f"Не удалось найти email для client_id={client_id}, пробуем удалить по всем inbounds")
                # Если не удалось найти email, пробуем удалить по всем возможным форматам
                # client_id имеет формат: {protocol}_{device.id}_{server.id}
                # Но нам нужен device для получения email, поэтому используем альтернативный подход
                # Удаляем клиента из всех inbounds, проверяя все возможные email
                return self._remove_client_by_id_pattern(client_id, self.server)
            
            def update_config(config: Dict[str, Any]) -> bool:
                # Удаляем клиента из всех inbounds
                removed = False
                for inbound in config.get('inbounds', []):
                    clients = inbound.get('settings', {}).get('clients', [])
                    original_count = len(clients)
                    # Удаляем клиента по email
                    clients[:] = [c for c in clients if c.get('email') != client_email]
                    if len(clients) < original_count:
                        inbound['settings']['clients'] = clients
                        removed = True
                        logger.info(
                            f"Клиент {client_email} удален из inbound {inbound.get('protocol', 'unknown')}"
                        )
                return removed

            removed = self._update_xray_config(self.server, update_config)

            if not removed:
                logger.warning(f"Клиент {client_email} не найден в конфигурации")
                return False
            
            # Перезагружаем Xray
            if not self._reload_xray(self.server):
                logger.warning("Не удалось перезагрузить Xray после удаления клиента")
                # Не считаем это критичной ошибкой, клиент уже удален из конфигурации
            
            logger.info(f"Xray клиент {client_email} успешно удален")
            return True
            
        except Exception as e:
            logger.error(f"Ошибка удаления Xray клиента {client_id}: {e}", exc_info=True)
            return False
    
    def _remove_client_by_id_pattern(self, client_id: str, server: Server) -> bool:
        """Альтернативный метод удаления клиента по паттерну client_id"""
        try:
            # client_id имеет формат: {protocol}_{device.id}_{server.id}
            # Пробуем найти клиента, перебирая все inbounds и проверяя email
            def update_config(config: Dict[str, Any]) -> bool:
                removed = False
                for inbound in config.get('inbounds', []):
                    clients = inbound.get('settings', {}).get('clients', [])
                    original_count = len(clients)

                    # Пробуем найти клиента по паттерну в email
                    # Email имеет формат: {user_id}_{device.id}@granivpn.com
                    # client_id: {protocol}_{device.id}_{server.id}
                    # Извлекаем device.id из client_id
                    parts = client_id.split('_')
                    if len(parts) >= 2:
                        device_id_part = parts[1]  # device.id из client_id
                        # Ищем клиента, у которого в email есть этот device.id
                        clients[:] = [
                            c for c in clients
                            if not (
                                c.get('email', '').endswith('@granivpn.com') and
                                device_id_part in c.get('email', '').split('_')
                            )
                        ]
                        if len(clients) < original_count:
                            inbound['settings']['clients'] = clients
                            removed = True
                            logger.info(
                                f"Клиент удален из inbound {inbound.get('protocol', 'unknown')} по паттерну"
                            )
                return removed

            removed = self._update_xray_config(server, update_config)
            if removed:
                # Перезагружаем Xray
                self._reload_xray(server)

            return removed
            
        except Exception as e:
            logger.error(f"Ошибка удаления клиента по паттерну {client_id}: {e}", exc_info=True)
            return False
    
    def _get_xray_stats_api(
        self,
        server: Server,
        pattern: str = None,
        name: str = None,
        timeout_sec: Optional[int] = None,
        fast_fail: bool = False,
    ) -> Dict[str, Any]:
        """Получает статистику через Xray Stats API.
        Использует xray api statsquery/stats вместо curl: HTTP API возвращает HTTP/0.9,
        который curl отклоняет. xray api работает через gRPC и возвращает JSON."""
        if not self.remote_manager or not self.remote_manager.ssh_manager:
            logger.warning("SSH недоступен для получения статистики через Stats API")
            return None
        
        try:
            stats_port = 10085
            ssh_config = self._get_ssh_config(server)
            server_addr = f"127.0.0.1:{stats_port}"
            
            if name:
                # Статистика конкретного пользователя: xray api stats -name "user>>>email>>>traffic>>>uplink"
                command = f"xray api stats --server={server_addr} -name '{name}'"
            else:
                # Вся статистика: xray api statsquery -pattern ''
                command = f"xray api statsquery --server={server_addr} -pattern ''"
            
            ssh_manager = self.remote_manager.ssh_manager
            old_timeout = ssh_manager.timeout
            old_command_timeout = ssh_manager.command_timeout
            old_max_retries = ssh_manager.max_retries
            old_initial_delay = ssh_manager.initial_delay
            try:
                if timeout_sec is not None:
                    # Для /vpn/status работаем в режиме fail-fast, чтобы не держать HTTP 15-30+ секунд.
                    ssh_manager.command_timeout = max(1, int(timeout_sec))
                    ssh_manager.timeout = min(old_timeout, max(3, int(timeout_sec)))
                if fast_fail:
                    ssh_manager.max_retries = 1
                    ssh_manager.initial_delay = 0.1

                result = ssh_manager.execute_command(
                    ssh_config['host'],
                    command,
                    ssh_config['port'],
                    ssh_config['username'],
                    ssh_config.get('key_path'),
                    ssh_config.get('key_content'),
                    ssh_config.get('password')
                )
            finally:
                ssh_manager.timeout = old_timeout
                ssh_manager.command_timeout = old_command_timeout
                ssh_manager.max_retries = old_max_retries
                ssh_manager.initial_delay = old_initial_delay
            
            if result['success'] and result['stdout']:
                try:
                    stats_data = json.loads(result['stdout'])
                    return stats_data
                except json.JSONDecodeError:
                    logger.warning(
                        "Stats API: не удалось распарсить ответ server_id=%s stdout=%r",
                        server.id if server else None,
                        (result['stdout'] or '')[:200],
                    )
                    return None
            else:
                stderr = result.get('stderr', '') or ''
                # "Invalid HTTP request" — xray api может вернуть при проблемах с gRPC
                logger.warning(
                    "Stats API: ошибка server_id=%s stderr=%r exit=%s",
                    server.id if server else None,
                    stderr[:300],
                    result.get('exit_status', '?'),
                )
                return None
                
        except Exception as e:
            logger.error(
                "Stats API: исключение server_id=%s: %s",
                server.id if server else None,
                e,
                exc_info=True,
            )
            return None
    
    def _parse_client_email_from_client_id(self, client_id: str, server: Server) -> Optional[str]:
        """Извлекает email клиента из client_id для получения статистики"""
        try:
            # client_id имеет формат: protocol_device_id_server_id
            # Нужно найти device по client_id и получить email
            # Email имеет формат: user_id_device_id@granivpn.com
            parts = client_id.split('_')
            if len(parts) >= 3:
                device_id = parts[1]
                # Читаем конфигурацию и ищем клиента
                config = self._read_xray_config(server)
                for inbound in config.get('inbounds', []):
                    for client in inbound.get('settings', {}).get('clients', []):
                        client_email = client.get('email', '')
                        if client_email.endswith('@granivpn.com'):
                            email_parts = client_email.split('_')
                            if len(email_parts) >= 2 and email_parts[0].isdigit():
                                if email_parts[1].split('@')[0] == device_id:
                                    return client_email
            return None
        except Exception as e:
            logger.error(f"Ошибка извлечения email из client_id: {e}")
            return None
    
    def get_server_stats(self, server: Optional[Server] = None) -> Dict[str, Any]:
        """Получение статистики сервера"""
        if not server:
            server = self.server
        
        if not server:
            logger.warning("Сервер не указан для получения статистики")
            return {
                "total_uplink": 0,
                "total_downlink": 0,
                "active_clients": 0,
                "total_clients": 0,
                "timestamp": datetime.now().isoformat(),
                "error": "Сервер не указан"
            }
        
        try:
            # Получаем статистику всех пользователей через Stats API (pattern='' = все)
            stats_data = self._get_xray_stats_api(server)
            
            if not stats_data:
                # Fallback: пытаемся получить через конфигурацию
                config = self._read_xray_config(server)
                total_clients = 0
                for inbound in config.get('inbounds', []):
                    total_clients += len(inbound.get('settings', {}).get('clients', []))
                
                return {
                    "total_uplink": 0,
                    "total_downlink": 0,
                    "active_clients": 0,
                    "total_clients": total_clients,
                    "timestamp": datetime.now().isoformat(),
                    "message": "Stats API недоступен, возвращено количество клиентов из конфигурации"
                }
            
            # Парсим статистику из Stats API
            # Формат: user>>>email>>>traffic>>>uplink / user>>>email>>>traffic>>>downlink
            total_uplink = 0
            total_downlink = 0
            active_clients_set = set()  # уникальные пользователи (у каждого 2 записи: uplink, downlink)
            
            if 'stat' in stats_data:
                stats_list = stats_data['stat'] if isinstance(stats_data['stat'], list) else [stats_data['stat']]
                for stat in stats_list:
                    name = stat.get('name', '')
                    value = stat.get('value', 0)
                    
                    if name.startswith('user>>>') and '>>>traffic>>>' in name:
                        parts = name.split('>>>')
                        if len(parts) >= 2:
                            active_clients_set.add(parts[1])  # email
                        if name.endswith('>>>uplink'):
                            total_uplink += int(value) if isinstance(value, str) else value
                        elif name.endswith('>>>downlink'):
                            total_downlink += int(value) if isinstance(value, str) else value
                active_clients = len(active_clients_set)
            
            # Если не нашли раздельную статистику, пытаемся получить общую
            if total_uplink == 0 and total_downlink == 0:
                # Пытаемся получить общую статистику
                total_stats = self._get_xray_stats_api(server)
                if total_stats and 'stat' in total_stats:
                    stats_list = total_stats['stat'] if isinstance(total_stats['stat'], list) else [total_stats['stat']]
                    for stat in stats_list:
                        name = stat.get('name', '')
                        value = stat.get('value', 0)
                        if 'uplink' in name.lower():
                            total_uplink += value
                        elif 'downlink' in name.lower():
                            total_downlink += value
            
            # Получаем общее количество клиентов из конфигурации
            config = self._read_xray_config(server)
            total_clients = 0
            for inbound in config.get('inbounds', []):
                total_clients += len(inbound.get('settings', {}).get('clients', []))
            
            return {
                "total_uplink": total_uplink,
                "total_downlink": total_downlink,
                "active_clients": active_clients,
                "total_clients": total_clients,
                "timestamp": datetime.now().isoformat()
            }
            
        except Exception as e:
            logger.error(f"Ошибка получения статистики сервера: {e}", exc_info=True)
            return {
                "total_uplink": 0,
                "total_downlink": 0,
                "active_clients": 0,
                "total_clients": 0,
                "timestamp": datetime.now().isoformat(),
                "message": f"Не удалось получить статистику: {e}"
            }
    
    def get_client_stats(
        self,
        client_id: str,
        server: Optional[Server] = None,
        stats_timeout_sec: Optional[int] = None,
        fast_fail: bool = False,
    ) -> Dict[str, Any]:
        """Получение статистики клиента"""
        if not server:
            server = self.server
        
        if not server:
            logger.warning("Сервер не указан для получения статистики клиента")
            return {
                "uplink": 0,
                "downlink": 0,
                "error": "Сервер не указан"
            }
        
        try:
            # Извлекаем email клиента из client_id
            client_email = self._parse_client_email_from_client_id(client_id, server)
            
            if not client_email:
                logger.warning(f"Не удалось найти email для client_id={client_id}")
                return {
                    "uplink": 0,
                    "downlink": 0,
                    "error": "Клиент не найден"
                }
            
            # Получаем статистику для конкретного пользователя
            # Xray формат: user>>>email>>>traffic>>>uplink / user>>>email>>>traffic>>>downlink
            uplink_name = f"user>>>{client_email}>>>traffic>>>uplink"
            downlink_name = f"user>>>{client_email}>>>traffic>>>downlink"
            
            uplink_stats = self._get_xray_stats_api(
                server,
                name=uplink_name,
                timeout_sec=stats_timeout_sec,
                fast_fail=fast_fail,
            )
            downlink_stats = self._get_xray_stats_api(
                server,
                name=downlink_name,
                timeout_sec=stats_timeout_sec,
                fast_fail=fast_fail,
            )
            
            uplink = 0
            downlink = 0
            
            if uplink_stats and 'stat' in uplink_stats:
                stat = uplink_stats['stat']
                if isinstance(stat, list) and len(stat) > 0:
                    uplink = stat[0].get('value', 0)
                elif isinstance(stat, dict):
                    uplink = stat.get('value', 0)
            
            if downlink_stats and 'stat' in downlink_stats:
                stat = downlink_stats['stat']
                if isinstance(stat, list) and len(stat) > 0:
                    downlink = stat[0].get('value', 0)
                elif isinstance(stat, dict):
                    downlink = stat.get('value', 0)
            
            return {
                "uplink": uplink,
                "downlink": downlink,
                "client_id": client_id,
                "client_email": client_email,
                "timestamp": datetime.now().isoformat()
            }
            
        except Exception as e:
            logger.error(f"Ошибка получения статистики клиента {client_id}: {e}")
            return {
                "uplink": 0,
                "downlink": 0,
                "error": str(e)
            }
    
    def check_server_health(self, server: Optional[Server] = None) -> Dict[str, Any]:
        """Проверка здоровья сервера"""
        if not server:
            server = self.server
        
        if not server:
            return {
                "status": "error",
                "message": "Сервер не указан"
            }
        
        if not self.remote_manager or not self.remote_manager.ssh_manager:
            return {
                "status": "error",
                "message": "SSH недоступен"
            }
        
        try:
            ssh_config = self._get_ssh_config(server)
            result = self.remote_manager.ssh_manager.execute_command(
                ssh_config['host'],
                "systemctl is-active xray-v2",
                ssh_config['port'],
                ssh_config['username'],
                ssh_config.get('key_path'),
                ssh_config.get('key_content'),
                ssh_config.get('password')
            )
            
            if result['success'] and "active" in result['stdout']:
                return {
                    "status": "healthy",
                    "message": "Xray работает"
                }
            else:
                return {
                    "status": "error",
                    "message": f"Xray не запущен: {result['stderr']}"
                }
        except Exception as e:
            logger.error(f"Ошибка проверки здоровья Xray: {e}")
            return {
                "status": "error",
                "message": str(e)
            }

    def check_server_runtime_ready(
        self,
        server: Optional[Server] = None,
        required_ports: Optional[List[int]] = None,
    ) -> Dict[str, Any]:
        """
        Проверка runtime-готовности dataplane:
        - xray-v2 active
        - inbound-порты реально listening
        """
        if not server:
            server = self.server
        if not server:
            return {"ready": False, "reason": "server_not_provided", "missing_ports": []}
        if not self.remote_manager or not self.remote_manager.ssh_manager:
            return {"ready": False, "reason": "ssh_unavailable", "missing_ports": []}

        ports = required_ports or [4443, 2053, 8443]
        ports = [int(p) for p in ports if isinstance(p, int) and p > 0]
        if not ports:
            ports = [4443]

        try:
            ssh_config = self._get_ssh_config(server)
            unit_res = self.remote_manager.ssh_manager.execute_command(
                ssh_config["host"],
                "systemctl is-active xray-v2",
                ssh_config["port"],
                ssh_config["username"],
                ssh_config.get("key_path"),
                ssh_config.get("key_content"),
                ssh_config.get("password"),
            )
            unit_active = bool(
                unit_res.get("success")
                and str(unit_res.get("stdout") or "").strip().lower() == "active"
            )
            if not unit_active:
                return {
                    "ready": False,
                    "reason": "xray_v2_inactive",
                    "missing_ports": ports,
                }

            missing_ports: List[int] = []
            for port in ports:
                check_res = self.remote_manager.ssh_manager.execute_command(
                    ssh_config["host"],
                    f"ss -ltn '( sport = :{port} )' | wc -l",
                    ssh_config["port"],
                    ssh_config["username"],
                    ssh_config.get("key_path"),
                    ssh_config.get("key_content"),
                    ssh_config.get("password"),
                )
                listen_rows_raw = str(check_res.get("stdout") or "").strip()
                try:
                    listen_rows = int(listen_rows_raw or "0")
                except ValueError:
                    listen_rows = 0
                if listen_rows < 2:
                    missing_ports.append(port)

            if missing_ports:
                return {
                    "ready": False,
                    "reason": "ports_not_listening",
                    "missing_ports": missing_ports,
                }

            return {"ready": True, "reason": "ok", "missing_ports": []}
        except Exception as e:
            logger.warning(
                "check_server_runtime_ready failed: server_id=%s err=%s",
                getattr(server, "id", None),
                e,
            )
            return {"ready": False, "reason": f"runtime_check_error:{e}", "missing_ports": ports}
    
    def get_all_clients(self) -> List[Dict[str, Any]]:
        """Получение списка всех клиентов"""
        return []
    
    def _generate_client_json_config(
        self,
        client_id: str,
        server: Server,
        protocol: str,
        uuid_str: Optional[str] = None
    ) -> Optional[Dict[str, Any]]:
        """Генерация JSON конфигурации клиента"""
        # Принимаем как "vless", так и "xray_vless" (и аналоги), чтобы
        # корректно выбирать inbound-порт и не отправлять VLESS на REALITY-порт.
        if isinstance(protocol, str) and protocol.startswith("xray_"):
            protocol = protocol.replace("xray_", "", 1)

        if not uuid_str:
            # Пытаемся найти UUID на сервере по email клиента
            uuid_str = self._resolve_client_uuid_from_server_config(client_id, server, protocol)

            # Извлекаем UUID из client_id или используем его напрямую
            # Формат: protocol_deviceId_serverId
            if not uuid_str:
                parts = client_id.split('_')
                if len(parts) >= 3:
                    # UUID не найден на сервере (клиент удалён, SSH недоступен и т.д.).
                    # НЕ генерируем новый uuid4 — он невалиден на inbound.
                    # Вызывающий код должен вернуть 404, клиент сделает create-client.
                    return None
                else:
                    uuid_str = client_id
        
        if protocol in {"vless", "vless_ws_tls", "vless_grpc_tls"}:
            port = self._resolve_port_from_runtime_inbound(
                server=server,
                protocol_kind="vless",
                security="none",
            )
        elif protocol == "vmess":
            port = self._resolve_port_from_runtime_inbound(
                server=server,
                protocol_kind="vmess",
                security="none",
            )
        elif protocol == "reality":
            port = self._resolve_port_from_runtime_inbound(
                server=server,
                protocol_kind="vless",
                security="reality",
            )
        else:
            port = server.xray_port or XRAY_DEFAULT_PORT
        address = server.ip_address
        
        if protocol in {"vless", "vless_ws_tls", "vless_grpc_tls"}:
            base = {
                "protocol": "vless",
                "v": "2",
                "ps": "GRANI",
                "add": address,
                "port": port,
                "id": uuid_str,
                "aid": 0,
                "scy": "none",
                "net": "tcp",
                "type": "none",
                "host": "",
                "path": "",
                "tls": "none"
            }
            if protocol == "vless_ws_tls":
                base.update({
                    "net": "ws",
                    "tls": "tls",
                    "host": "api.granilink.com",
                    "path": "/xray-vless-ws",
                    "sni": "api.granilink.com",
                    "port": 443,
                })
            elif protocol == "vless_grpc_tls":
                base.update({
                    "net": "grpc",
                    "type": "gun",
                    "tls": "tls",
                    "host": "api.granilink.com",
                    "path": "xray-grpc",
                    "sni": "api.granilink.com",
                    "port": 443,
                })
            return base
        elif protocol == "vmess":
            return {
                "protocol": "vmess",
                "v": "2",
                "ps": "GRANI",
                "add": address,
                "port": port,
                "id": uuid_str,
                "aid": 0,
                "scy": "none",
                "net": "tcp",
                "type": "none",
                "host": "",
                "path": "",
                "tls": "none"
            }
        elif protocol == "reality":
            return {
                "protocol": "vless",
                "v": "2",
                "ps": "GRANI-REALITY",
                "add": address,
                "port": port,
                "id": uuid_str,
                "aid": 0,
                "scy": "none",
                "net": "tcp",
                "type": "none",
                "host": "",
                "path": "",
                "tls": "reality",
                "sni": server.reality_sni or "google.com",
                "pbk": server.reality_public_key or "",
                "sid": server.reality_short_id or "",
                "fp": "chrome",
                # flow intentionally omitted for better compatibility
            }
        
        return None

    def _resolve_port_from_runtime_inbound(
        self,
        server: Server,
        protocol_kind: str,
        security: str,
    ) -> int:
        """
        Возвращает фактический inbound-порт из текущего runtime-конфига,
        чтобы клиентский JSON не указывал устаревший дефолтный порт.
        """
        default_port = self._get_default_inbound_port(protocol_kind, server, security)
        cfg = self._get_cached_xray_config(server)
        if not cfg:
            # Кэш может быть пустым после рестарта API или в раннем connect-пути.
            # Читаем фактический runtime-конфиг ноды, чтобы не отдавать stale/default порт.
            try:
                cfg = self._read_xray_config(server)
                if cfg:
                    self._set_cached_xray_config(server, cfg)
            except Exception as e:
                logger.warning(
                    "resolve runtime inbound port fallback to default: server_id=%s protocol=%s security=%s err=%s",
                    getattr(server, "id", None),
                    protocol_kind,
                    security,
                    e,
                )
                cfg = None
        if not cfg:
            return default_port
        inbound = self._find_inbound_by_security(cfg, protocol_kind, security)
        return self._get_inbound_port(inbound, default_port)

    def _resolve_client_uuid_from_server_config(
        self,
        client_id: str,
        server: Server,
        protocol: str
    ) -> Optional[str]:
        """Пытается найти UUID клиента на сервере по email."""
        if not self.remote_manager or not self.remote_manager.ssh_manager:
            return None
        try:
            config = self._get_cached_xray_config(server)
            if not config:
                config = self._read_xray_config(server)
                if config:
                    self._set_cached_xray_config(server, config)
            parts = client_id.split('_')
            device_id = parts[1] if len(parts) >= 3 else None
            if not device_id:
                return None

            target_email = None
            for inbound in config.get('inbounds', []):
                for client in inbound.get('settings', {}).get('clients', []):
                    client_email = client.get('email', '')
                    if client_email.endswith('@granivpn.com'):
                        email_parts = client_email.split('_')
                        if len(email_parts) >= 2 and email_parts[1].split('@')[0] == device_id:
                            target_email = client_email
                            break
                if target_email:
                    break

            if not target_email:
                return None

            def inbound_matches(inbound: Dict[str, Any]) -> bool:
                if protocol == "vmess":
                    return inbound.get('protocol') == 'vmess'
                if protocol == "reality":
                    if inbound.get('protocol') != 'vless':
                        return False
                    stream = inbound.get('streamSettings') or {}
                    return stream.get('security') == 'reality'
                if protocol == "vless":
                    if inbound.get('protocol') != 'vless':
                        return False
                    stream = inbound.get('streamSettings') or {}
                    return stream.get('security') == 'none'
                return False

            for inbound in config.get('inbounds', []):
                if not inbound_matches(inbound):
                    continue
                for client in inbound.get('settings', {}).get('clients', []):
                    if client.get('email') == target_email and client.get('id'):
                        return client.get('id')

            # Fallback: ищем клиента по email во всех inbounds
            for inbound in config.get('inbounds', []):
                for client in inbound.get('settings', {}).get('clients', []):
                    if client.get('email') == target_email and client.get('id'):
                        return client.get('id')
        except Exception as e:
            logger.warning(f"Не удалось определить UUID клиента из конфигурации: {e}")
        return None
    
    def _generate_client_config(self, client_id: str, server: Server, protocol: str) -> str:
        """Генерация конфигурации клиента"""
        json_config = self._generate_client_json_config(client_id, server, protocol)
        if json_config:
            uuid_str = json_config.get('id', client_id)
            if protocol == "vless":
                return self._generate_vless_config_url(uuid_str, server)
            elif protocol == "vmess":
                return self._generate_vmess_config_url(uuid_str, server)
            elif protocol == "reality":
                return self._generate_reality_config_url(uuid_str, server)
        return ""