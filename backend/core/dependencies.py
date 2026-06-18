"""Зависимости для FastAPI endpoints"""
from fastapi import Depends
from sqlalchemy.orm import Session
from core.database import get_db

from services.device_manager import DeviceManager
from services.vpn_operations_service import VPNOperationsService


def get_device_manager(db: Session = Depends(get_db)) -> DeviceManager:
    """Получить экземпляр DeviceManager (Xray-only: без WireGuardManager)."""
    return DeviceManager(db, wg_manager=None)


def get_vpn_operations_service(
    db: Session = Depends(get_db),
    device_manager: DeviceManager = Depends(get_device_manager),
) -> VPNOperationsService:
    """Получить экземпляр VPNOperationsService (только Xray)."""
    return VPNOperationsService(db, device_manager)






