import logging
from typing import Dict, Any, List, Optional
from datetime import datetime, date, timedelta
from sqlalchemy.orm import Session
from sqlalchemy import func, and_

from models.server import Server
from models.protocol_stats import ProtocolStats
from models.user import Device
from models.server import ConnectionLog

logger = logging.getLogger(__name__)

class ProtocolAnalyzer:
    """Анализатор производительности протоколов"""
    
    def __init__(self, db: Session):
        self.db = db
    
    def collect_protocol_stats(self, server_id: int, protocol: str, date: date = None) -> ProtocolStats:
        """Собирает статистику по протоколу для сервера за день"""
        if date is None:
            date = date.today()
        
        try:
            # Ищем существующую статистику
            stats = self.db.query(ProtocolStats).filter(
                and_(
                    ProtocolStats.server_id == server_id,
                    ProtocolStats.protocol == protocol,
                    ProtocolStats.date == date
                )
            ).first()
            
            if not stats:
                stats = ProtocolStats(
                    server_id=server_id,
                    protocol=protocol,
                    date=date
                )
                self.db.add(stats)
            
            # Получаем данные из логов подключений
            # В реальной реализации здесь будет более сложная логика
            # с учетом типа протокола из Device или ConnectionLog
            
            # Подсчитываем подключения за день
            start_datetime = datetime.combine(date, datetime.min.time())
            end_datetime = datetime.combine(date, datetime.max.time())
            
            connections = self.db.query(ConnectionLog).filter(
                and_(
                    ConnectionLog.server_id == server_id,
                    ConnectionLog.connected_at >= start_datetime,
                    ConnectionLog.connected_at < end_datetime + timedelta(days=1)
                )
            ).all()
            
            total_connections = len(connections)
            successful_connections = len([c for c in connections if c.connection_type == 'connect'])
            failed_connections = total_connections - successful_connections
            
            # Обновляем статистику
            stats.total_connections = total_connections
            stats.successful_connections = successful_connections
            stats.failed_connections = failed_connections
            
            # Вычисляем средние значения (заглушки, в реальности из метрик)
            if total_connections > 0:
                stats.average_speed_mbps = 50.0  # Заглушка
                stats.average_ping_ms = 30.0  # Заглушка
                stats.uptime_percentage = (successful_connections / total_connections) * 100
                stats.user_satisfaction_score = min(10.0, (successful_connections / total_connections) * 10)
            
            stats.updated_at = datetime.utcnow()
            
            self.db.commit()
            self.db.refresh(stats)
            
            return stats
            
        except Exception as e:
            logger.error(f"Ошибка сбора статистики протокола {protocol} для сервера {server_id}: {e}")
            self.db.rollback()
            raise
    
    def collect_daily_stats(self, target_date: date = None) -> Dict[str, Any]:
        """Собирает статистику по всем протоколам за день"""
        if target_date is None:
            target_date = date.today()
        
        try:
            servers = self.db.query(Server).filter(Server.is_active == True).all()
            results = []
            
            for server in servers:
                protocols = server.get_supported_protocols()
                
                for protocol in protocols:
                    try:
                        stats = self.collect_protocol_stats(server.id, protocol, target_date)
                        results.append({
                            'server_id': server.id,
                            'server_name': server.name,
                            'protocol': protocol,
                            'stats': {
                                'total_connections': stats.total_connections,
                                'successful_connections': stats.successful_connections,
                                'failed_connections': stats.failed_connections,
                                'success_rate': stats.get_success_rate(),
                                'average_speed_mbps': stats.average_speed_mbps,
                                'average_ping_ms': stats.average_ping_ms,
                                'uptime_percentage': stats.uptime_percentage,
                                'user_satisfaction_score': stats.user_satisfaction_score
                            }
                        })
                    except Exception as e:
                        logger.error(f"Ошибка сбора статистики для {protocol} на сервере {server.id}: {e}")
            
            return {
                'date': target_date.isoformat(),
                'total_servers': len(servers),
                'results': results,
                'timestamp': datetime.utcnow().isoformat()
            }
            
        except Exception as e:
            logger.error(f"Ошибка сбора ежедневной статистики: {e}")
            return {
                'error': str(e),
                'timestamp': datetime.utcnow().isoformat()
            }
    
    def get_protocol_performance(self, protocol: str, days: int = 7) -> Dict[str, Any]:
        """Получает производительность протокола за период"""
        try:
            start_date = date.today() - timedelta(days=days)
            
            stats = self.db.query(ProtocolStats).filter(
                and_(
                    ProtocolStats.protocol == protocol,
                    ProtocolStats.date >= start_date
                )
            ).all()
            
            if not stats:
                return {
                    'protocol': protocol,
                    'error': 'Нет данных за указанный период'
                }
            
            # Агрегируем статистику
            total_connections = sum(s.total_connections for s in stats)
            successful_connections = sum(s.successful_connections for s in stats)
            failed_connections = sum(s.failed_connections for s in stats)
            
            avg_speed = sum(s.average_speed_mbps for s in stats) / len(stats) if stats else 0.0
            avg_ping = sum(s.average_ping_ms for s in stats) / len(stats) if stats else 0.0
            avg_uptime = sum(s.uptime_percentage for s in stats) / len(stats) if stats else 0.0
            avg_satisfaction = sum(s.user_satisfaction_score for s in stats) / len(stats) if stats else 0.0
            
            success_rate = (successful_connections / total_connections * 100) if total_connections > 0 else 0.0
            
            return {
                'protocol': protocol,
                'period_days': days,
                'total_connections': total_connections,
                'successful_connections': successful_connections,
                'failed_connections': failed_connections,
                'success_rate': round(success_rate, 2),
                'average_speed_mbps': round(avg_speed, 2),
                'average_ping_ms': round(avg_ping, 2),
                'average_uptime_percentage': round(avg_uptime, 2),
                'average_satisfaction_score': round(avg_satisfaction, 2),
                'timestamp': datetime.utcnow().isoformat()
            }
            
        except Exception as e:
            logger.error(f"Ошибка получения производительности протокола {protocol}: {e}")
            return {
                'protocol': protocol,
                'error': str(e)
            }
    
    def get_protocol_recommendations(self, country: str = None) -> Dict[str, Any]:
        """Получает рекомендации по выбору протокола для региона"""
        try:
            # Базовые рекомендации
            recommendations = {
                'russia': {
                    'recommended': ['xray_vless', 'xray_vmess'],
                    'alternative': ['openvpn'],
                    'not_recommended': ['wireguard'],
                    'reason': 'Xray лучше обходит блокировки в России'
                },
                'default': {
                    'recommended': ['wireguard', 'xray_vless'],
                    'alternative': ['openvpn'],
                    'not_recommended': [],
                    'reason': 'WireGuard обеспечивает лучшую скорость'
                }
            }
            
            # Получаем статистику по протоколам
            protocols = ['wireguard', 'xray_vless', 'xray_vmess', 'openvpn']
            protocol_performance = {}
            
            for protocol in protocols:
                perf = self.get_protocol_performance(protocol, days=30)
                if 'error' not in perf:
                    protocol_performance[protocol] = perf
            
            # Определяем лучший протокол на основе статистики
            if protocol_performance:
                best_protocol = max(
                    protocol_performance.items(),
                    key=lambda x: x[1].get('average_satisfaction_score', 0)
                )
                
                recommendations['best_performing'] = {
                    'protocol': best_protocol[0],
                    'score': best_protocol[1].get('average_satisfaction_score', 0)
                }
            
            # Выбираем рекомендации в зависимости от страны
            if country and country.lower() in ['russia', 'ru', 'россия']:
                base_rec = recommendations['russia']
            else:
                base_rec = recommendations['default']
            
            return {
                'country': country,
                'recommended_protocols': base_rec['recommended'],
                'alternative_protocols': base_rec['alternative'],
                'not_recommended_protocols': base_rec['not_recommended'],
                'reason': base_rec['reason'],
                'protocol_performance': protocol_performance,
                'best_performing': recommendations.get('best_performing'),
                'timestamp': datetime.utcnow().isoformat()
            }
            
        except Exception as e:
            logger.error(f"Ошибка получения рекомендаций по протоколам: {e}")
            return {
                'error': str(e)
            }



