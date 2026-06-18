"""
Репозиторий для работы с серверами.
"""
from typing import Optional, List
from sqlalchemy.orm import Session

from domain.models.server import Server
from infrastructure.repositories.base_repository import BaseRepository


class ServerRepository(BaseRepository[Server]):
    """Репозиторий для серверов"""
    
    def __init__(self, db: Session):
        super().__init__(db, Server)
    
    def get_active(self) -> List[Server]:
        """Получить все активные серверы"""
        return self.db.query(Server).filter(Server.is_active == True).all()
    
    def get_active_by_id(self, server_id: int) -> Optional[Server]:
        """Получить активный сервер по ID"""
        return self.db.query(Server).filter(
            Server.id == server_id,
            Server.is_active == True
        ).first()
    
    def get_by_country(self, country: str) -> List[Server]:
        """Получить серверы по стране"""
        return self.db.query(Server).filter(
            and_(
                Server.country == country,
                Server.is_active == True
            )
        ).all()
    
    def get_by_protocol(self, protocol: str) -> List[Server]:
        """Получить серверы, поддерживающие протокол"""
        # Протоколы хранятся в JSON формате
        import json
        servers = self.get_active()
        result = []
        for server in servers:
            supported = server.supported_protocols or []
            if isinstance(supported, str):
                try:
                    supported = json.loads(supported)
                except:
                    supported = []
            if protocol in supported:
                result.append(server)
        return result
    
    def get_first_active(self) -> Optional[Server]:
        """Получить первый активный сервер"""
        return self.db.query(Server).filter(Server.is_active == True).first()
