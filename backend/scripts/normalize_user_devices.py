#!/usr/bin/env python3
"""
Нормализация устройств пользователя:
- объединяет дубликаты по device_id
- переносит VPN-состояние в каноническое устройство
- при необходимости создает Xray клиента для канонического устройства
"""
import os
import sys
from datetime import datetime
from typing import List, Optional

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from sqlalchemy import text
from core.database import SessionLocal
from models.user import User, Device
from models.server import Server
from services.xray_manager import XrayManager


def _device_rank(device: Device) -> tuple:
    return (
        device.last_connected or datetime.min,
        device.created_at or datetime.min,
        device.id,
    )


def _pick_first(devices: List[Device], attr: str):
    for device in devices:
        value = getattr(device, attr, None)
        if value is not None and value != "":
            return value
    return None


def _normalize_duplicates(
    db,
    user: User,
    remove_xray_clients: bool = False,
    ensure_all_xray: bool = False
):
    devices = db.query(Device).filter(Device.user_id == user.id).all()
    by_device_id = {}
    for device in devices:
        by_device_id.setdefault(device.device_id, []).append(device)

    xray_manager = XrayManager()
    changed = False

    for device_id, group in by_device_id.items():
        if len(group) <= 1:
            continue

        group_sorted = sorted(group, key=_device_rank, reverse=True)
        canonical = group_sorted[0]
        duplicates = group_sorted[1:]

        vpn_protocol = _pick_first(group_sorted, "vpn_protocol")
        vpn_client_id = _pick_first(group_sorted, "vpn_client_id")
        current_server_id = _pick_first(group_sorted, "current_server_id")
        ip_address = _pick_first(group_sorted, "ip_address")
        is_active = any(d.is_active for d in group_sorted if d.is_active is not None)
        is_vpn_enabled = any(d.is_vpn_enabled for d in group_sorted if d.is_vpn_enabled is not None)
        last_connected = _pick_first(group_sorted, "last_connected")

        for duplicate in duplicates:
            if remove_xray_clients and duplicate.vpn_client_id and current_server_id:
                server = db.query(Server).filter(Server.id == current_server_id).first()
                if server:
                    try:
                        xray_manager.server = server
                        xray_manager.remove_client(duplicate.vpn_client_id)
                    except Exception:
                        pass

            duplicate.is_active = False
            duplicate.is_vpn_enabled = False
            duplicate.current_server_id = None
            duplicate.ip_address = None
            duplicate.vpn_protocol = None
            duplicate.vpn_client_id = None
            changed = True

        if duplicates:
            db.flush()

        canonical.vpn_protocol = vpn_protocol
        canonical.current_server_id = current_server_id
        canonical.ip_address = ip_address
        canonical.is_active = bool(is_active)
        canonical.is_vpn_enabled = bool(is_vpn_enabled)
        canonical.last_connected = last_connected
        changed = True

        if canonical.vpn_protocol in {"vless", "vmess", "reality"} and canonical.current_server_id:
            expected_client_id = f"{canonical.vpn_protocol}_{canonical.id}_{canonical.current_server_id}"
            canonical.vpn_client_id = expected_client_id
        else:
            canonical.vpn_client_id = vpn_client_id

        if canonical.current_server_id:
            server = db.query(Server).filter(Server.id == canonical.current_server_id).first()
            if server:
                try:
                    if ensure_all_xray or canonical.vpn_protocol == "vless":
                        xray_manager.create_vless_client(canonical, server)
                    if ensure_all_xray or canonical.vpn_protocol == "vmess":
                        xray_manager.create_vmess_client(canonical, server)
                    if ensure_all_xray or canonical.vpn_protocol == "reality":
                        xray_manager.create_reality_client(canonical, server)
                except Exception:
                    pass

    if changed:
        db.commit()


def main():
    email = sys.argv[1] if len(sys.argv) > 1 else None
    remove_xray_clients = "--remove-xray-clients" in sys.argv
    ensure_all_xray = "--ensure-all-xray" in sys.argv
    if not email:
        print("Укажите email пользователя: python3 scripts/normalize_user_devices.py user@example.com")
        sys.exit(1)

    db = SessionLocal()
    try:
        user = db.query(User).filter(User.email == email).first()
        if not user:
            print(f"Пользователь не найден: {email}")
            return 1

        _normalize_duplicates(
            db,
            user,
            remove_xray_clients=remove_xray_clients,
            ensure_all_xray=ensure_all_xray
        )
        print("Нормализация завершена.")
        return 0
    finally:
        db.close()


if __name__ == "__main__":
    raise SystemExit(main())
