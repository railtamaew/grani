"""
Репозиторий для VPN-соединений по (user, server, protocol).
"""
from typing import Optional
from sqlalchemy.orm import Session
from sqlalchemy import and_, or_

from domain.models.user_vpn_connection import UserVpnConnection
from infrastructure.repositories.base_repository import BaseRepository


class UserVpnConnectionRepository(BaseRepository[UserVpnConnection]):
    """Репозиторий для user_vpn_connections."""

    def __init__(self, db: Session):
        super().__init__(db, UserVpnConnection)

    def get_by_user_server_protocol(
        self,
        user_id: int,
        server_id: int,
        protocol: str,
    ) -> Optional[UserVpnConnection]:
        """Найти запись по (user_id, server_id, protocol)."""
        return self.db.query(UserVpnConnection).filter(
            and_(
                UserVpnConnection.user_id == user_id,
                UserVpnConnection.server_id == server_id,
                UserVpnConnection.protocol == protocol,
            )
        ).first()

    def get_by_client_or_connection_id(self, client_id: str, user_id: int) -> Optional[UserVpnConnection]:
        """
        Найти запись по идентификатору клиента.
        Для XRay — vpn_client_id, для WG — connection_id.
        """
        return self.db.query(UserVpnConnection).filter(
            and_(
                UserVpnConnection.user_id == user_id,
                or_(
                    UserVpnConnection.vpn_client_id == client_id,
                    UserVpnConnection.connection_id == client_id,
                ),
            )
        ).first()
