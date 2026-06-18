import logging
from typing import List, Dict, Any, Optional
from sqlalchemy.orm import Session

from domain.models.server import Server
from application.services.server_load_calculator import ServerLoadCalculator

logger = logging.getLogger(__name__)

class ServerSelector:
    """Селектор оптимального сервера для подключения"""
    
    def __init__(self, db: Session):
        self.db = db
        self.load_calculator = ServerLoadCalculator(db)
    
    def select_best_server(
        self,
        protocol: str = None,
        country: str = None,
        max_load: float = 80.0
    ) -> Optional[Server]:
        """
        Выбирает оптимальный сервер для подключения
        
        Алгоритм:
        1. Фильтрация по активности, нагрузке, протоколу, стране
        2. Ранжирование по ping, нагрузке, uptime, производительности протокола
        3. Возврат лучшего сервера
        
        Использует кэширование для оптимизации производительности.
        """
        try:
            # Проверяем кэш
            cache_key = f"server:best:{protocol or 'any'}:{country or 'any'}:{max_load}"
            cached_result = cache_get(cache_key)
            if cached_result:
                # Находим сервер по ID из кэша
                server = self.db.query(Server).filter(Server.id == cached_result).first()
                if server and server.is_active:
                    return server
            
            # Шаг 1: Фильтрация
            query = self.db.query(Server).filter(Server.is_active == True)
            
            # Фильтр по нагрузке
            query = query.filter(Server.load_percentage < max_load)
            
            # Фильтр по протоколу
            if protocol:
                # Проверяем поддерживаемые протоколы
                # В SQLAlchemy нужно использовать JSON операции
                # Для упрощения используем Python фильтрацию
                pass
            
            # Фильтр по стране
            if country:
                query = query.filter(Server.country == country)
            
            servers = query.all()
            
            # Дополнительная фильтрация по протоколу (если указан)
            if protocol:
                servers = [
                    s for s in servers
                    if protocol in s.get_supported_protocols()
                ]
            
            if not servers:
                logger.warning(f"Не найдено подходящих серверов (protocol={protocol}, country={country})")
                return None
            
            # Шаг 2: Ранжирование
            scored_servers = []
            
            for server in servers:
                score = self._calculate_server_score(server, protocol)
                scored_servers.append((server, score))
            
            # Сортируем по score (больше = лучше)
            scored_servers.sort(key=lambda x: x[1], reverse=True)
            
            # Шаг 3: Возвращаем лучший сервер
            best_server, best_score = scored_servers[0]
            
            # Кэшируем результат на 5 минут
            cache_set(cache_key, best_server.id, ttl=300)
            
            logger.info(
                f"Выбран сервер {best_server.id} ({best_server.name}) "
                f"со score {best_score:.2f}"
            )
            
            return best_server
            
        except Exception as e:
            logger.error(f"Ошибка выбора сервера: {e}")
            return None
    
    def _calculate_server_score(self, server: Server, protocol: str = None) -> float:
        """
        Рассчитывает score сервера для ранжирования
        
        Факторы:
        - Низкий ping (чем меньше, тем лучше) - 40%
        - Низкая нагрузка (чем меньше, тем лучше) - 30%
        - Высокий uptime (чем больше, тем лучше) - 20%
        - Хорошая производительность протокола - 10%
        """
        try:
            score = 0.0
            
            # Ping score (меньше = лучше, нормализуем до 100ms)
            ping_score = 1.0
            if server.ping_ms:
                ping_score = max(0.0, 1.0 - (server.ping_ms / 100.0))
            score += ping_score * 0.4
            
            # Load score (меньше = лучше)
            load_score = max(0.0, 1.0 - (server.load_percentage / 100.0))
            score += load_score * 0.3
            
            # Uptime score (больше = лучше)
            uptime_score = server.uptime_percentage / 100.0
            score += uptime_score * 0.2
            
            # Protocol performance score
            protocol_score = 0.5  # По умолчанию средний
            if protocol:
                perf = server.get_protocol_performance()
                if protocol in perf:
                    # Предполагаем, что в perf хранится score от 0 до 1
                    protocol_score = perf[protocol].get('score', 0.5) if isinstance(perf[protocol], dict) else 0.5
            score += protocol_score * 0.1
            
            return score
            
        except Exception as e:
            logger.error(f"Ошибка расчета score для сервера {server.id}: {e}")
            return 0.0
    
    def get_recommended_servers(
        self,
        protocol: str = None,
        country: str = None,
        limit: int = 5
    ) -> List[Dict[str, Any]]:
        """Получает список рекомендуемых серверов"""
        try:
            query = self.db.query(Server).filter(Server.is_active == True)
            
            if country:
                query = query.filter(Server.country == country)
            
            servers = query.all()
            
            # Фильтруем по протоколу
            if protocol:
                servers = [
                    s for s in servers
                    if protocol in s.get_supported_protocols()
                ]
            
            # Ранжируем
            scored_servers = []
            for server in servers:
                score = self._calculate_server_score(server, protocol)
                scored_servers.append({
                    'server': server,
                    'score': score
                })
            
            # Сортируем и ограничиваем
            scored_servers.sort(key=lambda x: x['score'], reverse=True)
            scored_servers = scored_servers[:limit]
            
            # Формируем результат
            result = []
            for item in scored_servers:
                server = item['server']
                result.append({
                    'id': server.id,
                    'name': server.name,
                    'country': server.country,
                    'city': server.city,
                    'ip_address': server.ip_address,
                    'load_percentage': server.load_percentage,
                    'ping_ms': server.ping_ms,
                    'uptime_percentage': server.uptime_percentage,
                    'current_users': server.current_users,
                    'max_users': server.max_users,
                    'score': round(item['score'], 2),
                    'health_status': server.health_status
                })
            
            return result
            
        except Exception as e:
            logger.error(f"Ошибка получения рекомендуемых серверов: {e}")
            return []



