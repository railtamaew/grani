import logging
from typing import Dict, Any, List
from datetime import datetime, timedelta
from sqlalchemy.orm import Session
from sqlalchemy import func

from domain.models.server import Server
from domain.models.user import Device

logger = logging.getLogger(__name__)

class ProviderMonitor:
    """Мониторинг провайдеров серверов"""
    
    def __init__(self, db: Session):
        self.db = db
    
    def get_provider_stats(self, provider_name: str) -> Dict[str, Any]:
        """Получает статистику по конкретному провайдеру"""
        try:
            servers = self.db.query(Server).filter(
                Server.provider == provider_name
            ).all()
            
            if not servers:
                return {
                    'provider_name': provider_name,
                    'total_servers': 0,
                    'active_servers': 0,
                    'error': 'Провайдер не найден'
                }
            
            active_servers = [s for s in servers if s.is_active]
            total_users = sum(s.current_users for s in servers)
            
            # Вычисляем средние значения
            total_load = sum(s.load_percentage for s in servers)
            average_load = total_load / len(servers) if servers else 0.0
            
            total_ping = sum(s.ping_ms for s in servers if s.ping_ms)
            ping_count = sum(1 for s in servers if s.ping_ms)
            average_ping = total_ping / ping_count if ping_count > 0 else None
            
            total_bandwidth_used = sum(s.bandwidth_used_mbps for s in servers)
            total_bandwidth_limit = sum(s.bandwidth_limit_mbps for s in servers if s.bandwidth_limit_mbps)
            
            # Вычисляем uptime
            total_uptime = sum(s.uptime_percentage for s in servers)
            average_uptime = total_uptime / len(servers) if servers else 0.0
            
            # Получаем уникальные регионы
            regions = list(set(s.provider_region for s in servers if s.provider_region))
            
            return {
                'provider_name': provider_name,
                'total_servers': len(servers),
                'active_servers': len(active_servers),
                'total_users': total_users,
                'average_load': round(average_load, 2),
                'average_ping': round(average_ping, 2) if average_ping else None,
                'total_bandwidth_used': round(total_bandwidth_used, 2),
                'total_bandwidth_limit': round(total_bandwidth_limit, 2) if total_bandwidth_limit else None,
                'uptime_percentage': round(average_uptime, 2),
                'regions': regions,
                'timestamp': datetime.utcnow().isoformat()
            }
            
        except Exception as e:
            logger.error(f"Ошибка получения статистики провайдера {provider_name}: {e}")
            return {
                'provider_name': provider_name,
                'error': str(e)
            }
    
    def get_all_providers(self) -> List[str]:
        """Получает список всех провайдеров"""
        try:
            providers = self.db.query(Server.provider).filter(
                Server.provider.isnot(None)
            ).distinct().all()
            
            return [p[0] for p in providers if p[0]]
            
        except Exception as e:
            logger.error(f"Ошибка получения списка провайдеров: {e}")
            return []
    
    def get_all_providers_stats(self) -> List[Dict[str, Any]]:
        """Получает статистику по всем провайдерам"""
        try:
            providers = self.get_all_providers()
            stats = []
            
            for provider in providers:
                stat = self.get_provider_stats(provider)
                stats.append(stat)
            
            return stats
            
        except Exception as e:
            logger.error(f"Ошибка получения статистики всех провайдеров: {e}")
            return []
    
    def update_all_providers_stats(self) -> Dict[str, Any]:
        """Обновляет статистику всех провайдеров"""
        try:
            stats = self.get_all_providers_stats()
            
            return {
                'total_providers': len(stats),
                'providers': stats,
                'timestamp': datetime.utcnow().isoformat()
            }
            
        except Exception as e:
            logger.error(f"Ошибка обновления статистики провайдеров: {e}")
            return {
                'error': str(e),
                'timestamp': datetime.utcnow().isoformat()
            }
    
    def get_provider_servers(self, provider_name: str) -> List[Dict[str, Any]]:
        """Получает список серверов провайдера"""
        try:
            servers = self.db.query(Server).filter(
                Server.provider == provider_name
            ).all()
            
            return [
                {
                    'id': s.id,
                    'name': s.name,
                    'country': s.country,
                    'city': s.city,
                    'ip_address': s.ip_address,
                    'is_active': s.is_active,
                    'load_percentage': s.load_percentage,
                    'current_users': s.current_users,
                    'max_users': s.max_users,
                    'ping_ms': s.ping_ms,
                    'health_status': s.health_status,
                    'provider_region': s.provider_region
                }
                for s in servers
            ]
            
        except Exception as e:
            logger.error(f"Ошибка получения серверов провайдера {provider_name}: {e}")
            return []
    
    def compare_providers(self) -> Dict[str, Any]:
        """Сравнивает провайдеров по различным метрикам"""
        try:
            providers = self.get_all_providers()
            comparison = []
            
            for provider in providers:
                stats = self.get_provider_stats(provider)
                comparison.append(stats)
            
            # Сортируем по средней нагрузке
            comparison.sort(key=lambda x: x.get('average_load', 0))
            
            return {
                'providers': comparison,
                'best_load': comparison[0] if comparison else None,
                'timestamp': datetime.utcnow().isoformat()
            }
            
        except Exception as e:
            logger.error(f"Ошибка сравнения провайдеров: {e}")
            return {
                'error': str(e)
            }



