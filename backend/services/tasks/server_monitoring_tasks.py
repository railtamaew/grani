import logging
from datetime import datetime, timedelta
from typing import Dict, Any
from sqlalchemy.orm import Session

from core.database import SessionLocal
from models.server import Server
from services.server_load_calculator import ServerLoadCalculator
from services.provider_monitor import ProviderMonitor
from services.protocol_analyzer import ProtocolAnalyzer
from services.remote_vpn_manager import RemoteVPNManager
from services.telemetry_service import TelemetryService
from models.telemetry import TelemetryEvent
from services.celery_app import celery_app
from core.cache import cache_delete
from core.network_latency import measure_latency_to_server

logger = logging.getLogger(__name__)

# Согласовано с api/vpn.py DEFAULT_XRAY_PORT
_DEFAULT_XRAY_PROBE_PORT = 4443

@celery_app.task(bind=True, name='server.update_server_load')
def update_server_load_task(self):
    """Фоновая задача для обновления нагрузки всех серверов"""
    try:
        db = SessionLocal()
        calculator = ServerLoadCalculator(db)
        
        result = calculator.update_all_servers_load()
        
        logger.info(f"Обновлена нагрузка серверов: {result.get('updated', 0)} серверов")
        
        db.close()
        
        return {
            'status': 'success',
            'result': result,
            'timestamp': datetime.now().isoformat()
        }
        
    except Exception as e:
        logger.error(f"Ошибка обновления нагрузки серверов: {e}")
        return {
            'status': 'error',
            'error': str(e),
            'timestamp': datetime.now().isoformat()
        }

@celery_app.task(bind=True, name='server.check_server_health')
def check_server_health_task(self):
    """Фоновая задача для проверки здоровья серверов"""
    try:
        db = SessionLocal()
        
        servers = db.query(Server).filter(Server.is_active == True).all()
        results = []
        remote_manager = RemoteVPNManager()
        
        for server in servers:
            try:
                ping_ms, source = measure_latency_to_server(
                    server.ip_address,
                    getattr(server, "xray_port", None),
                    default_xray_port=_DEFAULT_XRAY_PROBE_PORT,
                )
                server.ping_ms = ping_ms
                is_reachable = ping_ms is not None
                if not is_reachable and getattr(server, "graniwg_enabled", False):
                    try:
                        ssh_ok = remote_manager.test_connection(server)
                        wg_status = remote_manager.get_wireguard_status(server) if ssh_ok else {}
                        wg_output = wg_status.get("output") or ""
                        if ssh_ok and wg_status.get("status") == "running" and "interface:" in wg_output:
                            is_reachable = True
                            source = "wireguard_ssh"
                    except Exception as wg_error:
                        logger.warning(
                            "GRANIwg health fallback failed for server %s: %s",
                            server.id,
                            wg_error,
                        )
                server.health_status = "healthy" if is_reachable else "error"

                server.last_health_check = datetime.utcnow()

                results.append({
                    'server_id': server.id,
                    'server_name': server.name,
                    'is_reachable': is_reachable,
                    'ping_ms': server.ping_ms,
                    'latency_source': source,
                    'health_status': server.health_status,
                })

            except Exception as e:
                logger.error(f"Ошибка проверки здоровья сервера {server.id}: {e}")
                server.health_status = "error"
                server.last_health_check = datetime.utcnow()
                results.append({
                    'server_id': server.id,
                    'server_name': server.name,
                    'is_reachable': False,
                    'error': str(e)
                })

        db.commit()
        try:
            cache_delete("cache:servers:list")
        except Exception as ce:
            logger.warning("Не удалось сбросить кэш списка серверов: %s", ce)
        db.close()
        
        return {
            'status': 'success',
            'checked_servers': len(servers),
            'results': results,
            'timestamp': datetime.now().isoformat()
        }
        
    except Exception as e:
        logger.error(f"Ошибка проверки здоровья серверов: {e}")
        return {
            'status': 'error',
            'error': str(e),
            'timestamp': datetime.now().isoformat()
        }

@celery_app.task(bind=True, name='server.collect_protocol_stats')
def collect_protocol_stats_task(self):
    """Фоновая задача для сбора статистики по протоколам"""
    try:
        db = SessionLocal()
        analyzer = ProtocolAnalyzer(db)
        
        result = analyzer.collect_daily_stats()
        
        db.close()
        
        return {
            'status': 'success',
            'result': result,
            'timestamp': datetime.now().isoformat()
        }
        
    except Exception as e:
        logger.error(f"Ошибка сбора статистики по протоколам: {e}")
        return {
            'status': 'error',
            'error': str(e),
            'timestamp': datetime.now().isoformat()
        }

@celery_app.task(bind=True, name='server.update_provider_stats')
def update_provider_stats_task(self):
    """Фоновая задача для обновления статистики по провайдерам"""
    try:
        db = SessionLocal()
        monitor = ProviderMonitor(db)
        
        result = monitor.update_all_providers_stats()
        
        db.close()
        
        return {
            'status': 'success',
            'result': result,
            'timestamp': datetime.now().isoformat()
        }
        
    except Exception as e:
        logger.error(f"Ошибка обновления статистики провайдеров: {e}")
        return {
            'status': 'error',
            'error': str(e),
            'timestamp': datetime.now().isoformat()
        }


def _filter_error_lines(lines, keywords):
    if not lines:
        return []
    result = []
    for line in lines:
        if not line:
            continue
        line_lower = line.lower()
        if any(keyword in line_lower for keyword in keywords):
            result.append(line)
    return result


def _is_duplicate_event(db: Session, server_id: int, protocol_code: str, error_message: str, window_minutes: int = 30) -> bool:
    since = datetime.utcnow() - timedelta(minutes=window_minutes)
    existing = db.query(TelemetryEvent).filter(
        TelemetryEvent.server_id == server_id,
        TelemetryEvent.protocol_code == protocol_code,
        TelemetryEvent.error_message == error_message,
        TelemetryEvent.timestamp >= since
    ).first()
    return existing is not None


@celery_app.task(bind=True, name='server.collect_server_error_logs')
def collect_server_error_logs_task(self):
    """Сбор ошибок пользователей из серверных логов Xray/WireGuard"""
    try:
        db = SessionLocal()
        servers = db.query(Server).filter(Server.is_active == True).all()
        remote_manager = RemoteVPNManager()
        telemetry_service = TelemetryService(db)

        xray_keywords = [
            "error", "failed", "invalid", "timeout", "reality", "privatekey", "handshake", "auth"
        ]
        wireguard_keywords = [
            "error", "failed", "timeout", "handshake", "invalid", "unable", "no such"
        ]

        created = 0
        for server in servers:
            # Xray error logs
            xray_result = remote_manager.get_xray_logs(server, log_type="error", lines=200)
            if xray_result.get('success'):
                error_lines = _filter_error_lines(xray_result.get('logs', []), xray_keywords)[:20]
                for line in error_lines:
                    if _is_duplicate_event(db, server.id, "xray", line):
                        continue
                    telemetry_service.record_event(
                        user_id=None,
                        device_id=None,
                        protocol_code="xray",
                        server_id=server.id,
                        event_type="server_error",
                        error_code="xray_log_error",
                        error_message=line
                    )
                    created += 1

            # WireGuard logs
            wg_result = remote_manager.get_wireguard_logs(server, lines=200)
            if wg_result.get('success'):
                error_lines = _filter_error_lines(wg_result.get('logs', []), wireguard_keywords)[:20]
                for line in error_lines:
                    if _is_duplicate_event(db, server.id, "wireguard", line):
                        continue
                    telemetry_service.record_event(
                        user_id=None,
                        device_id=None,
                        protocol_code="wireguard",
                        server_id=server.id,
                        event_type="server_error",
                        error_code="wireguard_log_error",
                        error_message=line
                    )
                    created += 1

        db.close()
        return {
            'status': 'success',
            'created_events': created,
            'timestamp': datetime.now().isoformat()
        }

    except Exception as e:
        logger.error(f"Ошибка сбора логов серверов: {e}")
        return {
            'status': 'error',
            'error': str(e),
            'timestamp': datetime.now().isoformat()
        }
