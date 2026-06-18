#!/usr/bin/env python3
"""
Проверка параметров клиента для UUID b665c7a3-6fab-47f8-87fa-938c54075c0f (1_102@granivpn.com):
- Какой json_config возвращает API
- Совпадают ли address, port, UUID с сервером
"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

TARGET_UUID = "b665c7a3-6fab-47f8-87fa-938c54075c0f"
TARGET_SERVER_IP = "45.12.132.94"
TARGET_PORT = 4443


def main():
    from core.database import SessionLocal
    from models.server import Server
    from models.user import Device
    from infrastructure.external.xray_manager import XrayManager

    db = SessionLocal()
    try:
        server = db.query(Server).filter(Server.ip_address == TARGET_SERVER_IP).first()
        if not server:
            print(f"Сервер {TARGET_SERVER_IP} не найден")
            return 1

        # Ищем device с email 1_102@granivpn.com
        devices = db.query(Device).filter(Device.vpn_client_id.like("%_102_%")).all()
        device = None
        for d in devices:
            email = f"{d.user_id}_{d.id}@granivpn.com"
            if email == "1_102@granivpn.com":
                device = d
                break

        if not device:
            # Попробуем по vpn_client_id
            device = db.query(Device).filter(
                Device.vpn_client_id.like(f"%_{server.id}"),
                Device.vpn_protocol == "vless"
            ).all()
            device = next((d for d in device if f"{d.user_id}_{d.id}@granivpn.com" == "1_102@granivpn.com"), None)

        if not device:
            device = db.query(Device).filter(Device.id == 102).first()
            if device and f"{device.user_id}_{device.id}@granivpn.com" != "1_102@granivpn.com":
                device = None

        if not device:
            print("Device 1_102 не найден. Проверяем все VLESS устройства на HU-BUD-01...")
            devices = db.query(Device).filter(
                Device.vpn_protocol == "vless",
                Device.current_server_id == server.id
            ).all()
            for d in devices:
                print(f"  - device_id={d.id} user_id={d.user_id} client_id={d.vpn_client_id}")
            return 0

        xm = XrayManager(server)
        json_config = xm._generate_client_json_config(
            device.vpn_client_id,
            server,
            device.vpn_protocol or "vless",
            uuid_str=TARGET_UUID
        )

        if not json_config:
            json_config = xm._generate_client_json_config(
                device.vpn_client_id,
                server,
                "vless",
                uuid_str=TARGET_UUID
            )

        print("=" * 60)
        print("  ПАРАМЕТРЫ КЛИЕНТА (json_config)")
        print("=" * 60)
        print(f"\nDevice: id={device.id} user_id={device.user_id} client_id={device.vpn_client_id}")
        print(f"Server: {server.name} ({server.ip_address})")
        print(f"\nJSON config:")
        if json_config:
            for k, v in json_config.items():
                print(f"  {k}: {v}")
            add = json_config.get("add")
            port = json_config.get("port")
            uid = json_config.get("id")
            ok_add = add == TARGET_SERVER_IP
            ok_port = str(port) == str(TARGET_PORT)
            ok_uuid = uid == TARGET_UUID
            print(f"\nПроверка:")
            print(f"  add == {TARGET_SERVER_IP}: {'OK' if ok_add else 'ОШИБКА'}")
            print(f"  port == {TARGET_PORT}: {'OK' if ok_port else 'ОШИБКА'}")
            print(f"  id == {TARGET_UUID[:8]}...: {'OK' if ok_uuid else 'ОШИБКА'}")
        else:
            print("  (не сгенерирован)")
        print()
    finally:
        db.close()


if __name__ == "__main__":
    main()
