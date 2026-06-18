import logging
import subprocess
from typing import Dict, Any, Optional
from datetime import datetime
from sqlalchemy.orm import Session

from domain.models.server import Server
from domain.models.user import Device
from domain.models.user_vpn_connection import UserVpnConnection
from core.constants import (
    LOAD_WEIGHT_USERS,
    LOAD_WEIGHT_BANDWIDTH,
    LOAD_WEIGHT_CPU,
    LOAD_WEIGHT_PING
)

logger = logging.getLogger(__name__)

class ServerLoadCalculator:
    """Калькулятор нагрузки серверов"""
    
    def __init__(self, db: Session):
        self.db = db
    
    def calculate_load(self, server: Server) -> float:
        """
        Рассчитывает нагрузку сервера по формуле:
        load = (
            (active_users / max_users) * LOAD_WEIGHT_USERS +
            (bandwidth_used / bandwidth_limit) * LOAD_WEIGHT_BANDWIDTH +
            (cpu_usage / 100) * LOAD_WEIGHT_CPU +
            (ping_ms / 100) * LOAD_WEIGHT_PING
        ) * 100
        """
        try:
            # Активные пользователи: устройства (is_active) + соединения из user_vpn_connections
            device_user_ids = {
                r[0] for r in self.db.query(Device.user_id).filter(
                    Device.current_server_id == server.id,
                    Device.is_active == True,
                ).distinct().all()
            }
            connection_user_ids = {
                r[0] for r in self.db.query(UserVpnConnection.user_id).filter(
                    UserVpnConnection.server_id == server.id,
                ).distinct().all()
            }
            active_users = len(device_user_ids | connection_user_ids)
            server.current_users = active_users
            
            # Нормализуем количество пользователей (максимум 1.0)
            user_load = min(active_users / max(server.max_users, 1), 1.0) if server.max_users > 0 else 0.0
            
            # Нормализуем использование пропускной способности
            bandwidth_load = 0.0
            if server.bandwidth_limit_mbps and server.bandwidth_limit_mbps > 0:
                bandwidth_load = min(
                    server.bandwidth_used_mbps / server.bandwidth_limit_mbps,
                    1.0
                )
            
            # Получаем CPU usage (если доступно)
            cpu_usage = self._get_cpu_usage(server)
            cpu_load = min(cpu_usage / 100.0, 1.0) if cpu_usage else 0.0
            
            # Нормализуем ping (считаем нормальным до 100ms)
            ping_load = 0.0
            if server.ping_ms:
                ping_load = min(server.ping_ms / 100.0, 1.0)
            
            # Рассчитываем общую нагрузку
            load = (
                user_load * LOAD_WEIGHT_USERS +
                bandwidth_load * LOAD_WEIGHT_BANDWIDTH +
                cpu_load * LOAD_WEIGHT_CPU +
                ping_load * LOAD_WEIGHT_PING
            ) * 100
            
            # Ограничиваем от 0 до 100
            load = max(0.0, min(100.0, load))
            
            return load
            
        except Exception as e:
            logger.error(f"Ошибка расчета нагрузки для сервера {server.id}: {e}")
            return 0.0
    
    def _get_cpu_usage(self, server: Server) -> Optional[float]:
        """Получает использование CPU сервера (если доступно)"""
        try:
            # Попытка получить CPU usage через SSH или API
            # В реальной реализации здесь будет запрос к серверу
            # Пока возвращаем None, так как это требует настройки SSH/API
            return None
        except Exception as e:
            logger.debug(f"Не удалось получить CPU usage для сервера {server.id}: {e}")
            return None
    
    def update_server_load(self, server: Server) -> Dict[str, Any]:
        """Обновляет нагрузку сервера и возвращает информацию"""
        try:
            load = self.calculate_load(server)
            server.load_percentage = load
            server.last_health_check = datetime.utcnow()
            
            # Определяем статус здоровья
            if load >= 95:
                server.health_status = "error"
            elif load >= 80:
                server.health_status = "warning"
            else:
                server.health_status = "healthy"
            
            # Если нагрузка критическая, деактивируем сервер
            if load >= 95:
                server.is_active = False
                logger.warning(f"Сервер {server.id} ({server.name}) деактивирован из-за критической нагрузки: {load}%")
            
            self.db.commit()
            
            return {
                'server_id': server.id,
                'server_name': server.name,
                'load_percentage': load,
                'health_status': server.health_status,
                'active_users': server.current_users,
                'max_users': server.max_users,
                'bandwidth_used': server.bandwidth_used_mbps,
                'bandwidth_limit': server.bandwidth_limit_mbps,
                'ping_ms': server.ping_ms,
                'is_active': server.is_active,
                'timestamp': datetime.utcnow().isoformat()
            }
            
        except Exception as e:
            logger.error(f"Ошибка обновления нагрузки сервера {server.id}: {e}")
            self.db.rollback()
            return {
                'server_id': server.id,
                'error': str(e)
            }
    
    def update_all_servers_load(self) -> Dict[str, Any]:
        """Обновляет нагрузку всех активных серверов"""
        try:
            servers = self.db.query(Server).filter(Server.is_active == True).all()
            results = []
            
            for server in servers:
                result = self.update_server_load(server)
                results.append(result)
            
            return {
                'total_servers': len(servers),
                'updated': len(results),
                'results': results,
                'timestamp': datetime.utcnow().isoformat()
            }
            
        except Exception as e:
            logger.error(f"Ошибка обновления нагрузки всех серверов: {e}")
            return {
                'error': str(e),
                'timestamp': datetime.utcnow().isoformat()
            }
    
    def get_load_alerts(self, threshold: float = 80.0) -> list:
        """Получает предупреждения о высокой нагрузке"""
        try:
            servers = self.db.query(Server).filter(
                Server.is_active == True,
                Server.load_percentage >= threshold
            ).all()
            
            alerts = []
            for server in servers:
                alerts.append({
                    'server_id': server.id,
                    'server_name': server.name,
                    'load_percentage': server.load_percentage,
                    'health_status': server.health_status,
                    'active_users': server.current_users,
                    'max_users': server.max_users,
                    'bandwidth_used': server.bandwidth_used_mbps,
                    'bandwidth_limit': server.bandwidth_limit_mbps
                })
            
            return alerts
            
        except Exception as e:
            logger.error(f"Ошибка получения предупреждений о нагрузке: {e}")
            return []



