"""
Репозиторий для работы с устройствами.
"""
from typing import Optional, List
from sqlalchemy.orm import Session
from sqlalchemy import and_, func

from domain.models.user import Device
from infrastructure.repositories.base_repository import BaseRepository


class DeviceRepository(BaseRepository[Device]):
    """Репозиторий для устройств"""
    
    def __init__(self, db: Session):
        super().__init__(db, Device)
    
    def get_by_device_id(self, device_id: str, user_id: int) -> Optional[Device]:
        """Получить устройство по device_id и user_id.

        При дубликатах строк с одним device_id предпочитаем активную запись,
        затем с наибольшим id — чтобы не выбрать «мертвую» строку и не словить
        UniqueViolation на ux_devices_device_id_active при активации.
        """
        return self.db.query(Device).filter(
            and_(
                Device.device_id == device_id,
                Device.user_id == user_id
            )
        ).order_by(
            Device.is_active.desc(),
            Device.created_at.desc().nullslast(),
            Device.id.desc(),
        ).first()

    def get_by_user_and_fingerprint(self, user_id: int, fingerprint: str) -> Optional[Device]:
        """Получить устройство по user_id и device_fingerprint (для resolve после переустановки)."""
        if not fingerprint or not fingerprint.strip():
            return None
        return self.db.query(Device).filter(
            and_(
                Device.user_id == user_id,
                Device.device_fingerprint == fingerprint.strip()
            )
        ).first()

    def get_all_by_device_id(self, device_id: str) -> List[Device]:
        """Получить все устройства по device_id (независимо от пользователя)"""
        return self.db.query(Device).filter(Device.device_id == device_id).all()
    
    def get_by_user_id(self, user_id: int) -> List[Device]:
        """Получить все устройства пользователя"""
        return self.db.query(Device).filter(Device.user_id == user_id).all()
    
    def get_active_by_user_id(self, user_id: int) -> List[Device]:
        """Получить активные устройства пользователя"""
        return self.db.query(Device).filter(
            and_(
                Device.user_id == user_id,
                Device.is_active == True
            )
        ).all()
    
    def get_by_client_id(self, client_id: str, user_id: int) -> Optional[Device]:
        """Получить устройство по Xray client_id"""
        return self.db.query(Device).filter(
            and_(
                Device.vpn_client_id == client_id,
                Device.user_id == user_id
            )
        ).first()
    
    def get_by_server_id(self, server_id: int) -> List[Device]:
        """Получить все устройства на сервере"""
        return self.db.query(Device).filter(
            Device.current_server_id == server_id
        ).all()
    
    def get_active_by_server_id(self, server_id: int) -> List[Device]:
        """Получить активные устройства на сервере"""
        return self.db.query(Device).filter(
            and_(
                Device.current_server_id == server_id,
                Device.is_active == True
            )
        ).all()
    
    def count_by_user_id(self, user_id: int) -> int:
        """Подсчитать количество устройств пользователя"""
        return self.db.query(Device).filter(Device.user_id == user_id).count()

    def count_distinct_device_ids_by_user_id(self, user_id: int) -> int:
        """Логические устройства (уникальные строковые device_id), без дублей строк в БД."""
        n = (
            self.db.query(func.count(func.distinct(Device.device_id)))
            .filter(Device.user_id == user_id)
            .scalar()
        )
        return int(n or 0)
    
    def count_active_by_server_id(self, server_id: int) -> int:
        """Подсчитать количество активных устройств на сервере"""
        return self.db.query(Device).filter(
            and_(
                Device.current_server_id == server_id,
                Device.is_active == True
            )
        ).count()
