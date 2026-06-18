import logging
from datetime import datetime, timedelta
from typing import Dict, Any
from sqlalchemy.orm import Session

from core.database import SessionLocal
from models.server import Server
from services.server_load_calculator import ServerLoadCalculator
from services.provider_monitor import ProviderMonitor
from services.protocol_analyzer import ProtocolAnalyzer
from services.celery_app import celery_app
from core.cache import cache_delete
from core.network_latency import measure_latency_to_server

logger = logging.getLogger(__name__)

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
        
        for server in servers:
            try:
                ping_ms, source = measure_latency_to_server(
                    server.ip_address,
                    getattr(server, "xray_port", None),
                    default_xray_port=_DEFAULT_XRAY_PROBE_PORT,
                )
                server.ping_ms = ping_ms
                is_reachable = ping_ms is not None
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

