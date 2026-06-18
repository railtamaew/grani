"""
Сервис для проверки здоровья системы.
Проверяет состояние всех критических компонентов.
"""
import logging
from typing import Dict, Any, List
from datetime import datetime
from sqlalchemy.orm import Session
from sqlalchemy import text

from core.database import SessionLocal, engine
from core.config import settings
from infrastructure.repositories.server_repository import ServerRepository
from infrastructure.repositories.device_repository import DeviceRepository

logger = logging.getLogger(__name__)


class HealthService:
    """Сервис для проверки здоровья системы"""
    
    def __init__(self, db: Session):
        self.db = db
        self.server_repo = ServerRepository(db)
        self.device_repo = DeviceRepository(db)
    
    def check_database(self) -> Dict[str, Any]:
        """
        Проверка подключения к базе данных.
        
        Returns:
            Статус подключения к БД
        """
        try:
            # Простой запрос для проверки подключения
            self.db.execute(text("SELECT 1"))
            return {
                "status": "healthy",
                "message": "Database connection OK",
                "timestamp": datetime.now().isoformat()
            }
        except Exception as e:
            logger.error(f"Database health check failed: {e}")
            return {
                "status": "unhealthy",
                "message": f"Database connection failed: {str(e)}",
                "timestamp": datetime.now().isoformat()
            }
    
    def check_servers(self) -> Dict[str, Any]:
        """
        Проверка состояния серверов.
        
        Returns:
            Статус серверов
        """
        try:
            active_servers = self.server_repo.get_active()
            total_servers = len(active_servers)
            
            # Подсчитываем серверы по статусу здоровья
            healthy_count = sum(1 for s in active_servers if getattr(s, 'health_status', None) == 'healthy')
            warning_count = sum(1 for s in active_servers if getattr(s, 'health_status', None) == 'warning')
            error_count = sum(1 for s in active_servers if getattr(s, 'health_status', None) == 'error')
            
            status = "healthy" if total_servers > 0 and error_count == 0 else "degraded"
            if total_servers == 0:
                status = "unhealthy"
            
            return {
                "status": status,
                "total_servers": total_servers,
                "healthy": healthy_count,
                "warning": warning_count,
                "error": error_count,
                "timestamp": datetime.now().isoformat()
            }
        except Exception as e:
            logger.error(f"Servers health check failed: {e}")
            return {
                "status": "unhealthy",
                "message": f"Failed to check servers: {str(e)}",
                "timestamp": datetime.now().isoformat()
            }
    
    def check_devices(self) -> Dict[str, Any]:
        """
        Проверка статистики устройств.
        
        Returns:
            Статистика устройств
        """
        try:
            total_devices = self.device_repo.count()
            active_devices = len(self.device_repo.filter_by(is_active=True))
            
            return {
                "status": "healthy",
                "total_devices": total_devices,
                "active_devices": active_devices,
                "timestamp": datetime.now().isoformat()
            }
        except Exception as e:
            logger.error(f"Devices health check failed: {e}")
            return {
                "status": "unhealthy",
                "message": f"Failed to check devices: {str(e)}",
                "timestamp": datetime.now().isoformat()
            }

    @staticmethod
    def check_celery_queues() -> Dict[str, Any]:
        """
        Глубина очередей Celery в Redis (списки default, vpn, monitoring, celery).
        """
        ts = datetime.now().isoformat()
        try:
            import redis as redis_lib

            url = settings.redis_url
            if not url:
                return {
                    "status": "degraded",
                    "message": "redis_url not configured",
                    "depths": {},
                    "timestamp": ts,
                }
            client = redis_lib.from_url(url, decode_responses=False)
            client.ping()
            queue_names = ("default", "vpn", "monitoring", "celery")
            depths: Dict[str, int] = {}
            for name in queue_names:
                try:
                    depths[name] = int(client.llen(name))
                except Exception as e:
                    logger.warning("celery queue LLEN %s: %s", name, e)
                    depths[name] = -1
            total = sum(d for d in depths.values() if d >= 0)
            status = "healthy"
            if total > 10_000:
                status = "unhealthy"
            elif total > 1_000:
                status = "degraded"
            return {
                "status": status,
                "depths": depths,
                "total_pending": total,
                "timestamp": ts,
            }
        except Exception as e:
            logger.warning("check_celery_queues: %s", e)
            return {
                "status": "degraded",
                "message": str(e),
                "depths": {},
                "timestamp": ts,
            }

    def get_full_health(self) -> Dict[str, Any]:
        """
        Полная проверка здоровья системы.
        
        Returns:
            Полный отчет о здоровье системы
        """
        checks = {
            "database": self.check_database(),
            "servers": self.check_servers(),
            "devices": self.check_devices(),
            "celery_queues": HealthService.check_celery_queues(),
        }
        
        # Определяем общий статус
        overall_status = "healthy"
        for check_name, check_result in checks.items():
            if check_result.get("status") == "unhealthy":
                overall_status = "unhealthy"
                break
            elif check_result.get("status") == "degraded" and overall_status == "healthy":
                overall_status = "degraded"
        
        return {
            "status": overall_status,
            "timestamp": datetime.now().isoformat(),
            "checks": checks,
            "version": "1.0.0"
        }


def get_health_service(db: Session = None) -> HealthService:
    """
    Получить экземпляр HealthService.
    
    Args:
        db: Сессия БД (если None, создается новая)
    
    Returns:
        HealthService экземпляр
    """
    if db is None:
        db = SessionLocal()
    return HealthService(db)
