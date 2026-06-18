"""
Скрипт для дедупликации device_id.

Оставляет одно (самое свежее) устройство на device_id и деактивирует остальные.
Если нужно — перепривязывает device_id к последнему активному пользователю.
"""
from datetime import datetime
from sqlalchemy import text
from core.database import SessionLocal


def main():
    session = SessionLocal()
    try:
        # Находим device_id с дубликатами
        dup_rows = session.execute(text("""
            SELECT device_id, COUNT(*) AS cnt
            FROM devices
            GROUP BY device_id
            HAVING COUNT(*) > 1
            ORDER BY cnt DESC
        """)).fetchall()

        print(f"Duplicate device_id count: {len(dup_rows)}")

        for device_id, _ in dup_rows:
            devices = session.execute(text("""
                SELECT id, user_id, is_active, created_at
                FROM devices
                WHERE device_id = :device_id
                ORDER BY created_at DESC NULLS LAST, id DESC
            """), {"device_id": device_id}).fetchall()

            if not devices:
                continue

            keep_id = devices[0].id
            keep_user_id = devices[0].user_id

            # Деактивируем все остальные
            session.execute(text("""
                UPDATE devices
                SET is_active = FALSE,
                    current_server_id = NULL,
                    ip_address = NULL,
                    vpn_protocol = NULL,
                    vpn_client_id = NULL
                WHERE device_id = :device_id
                  AND id != :keep_id
            """), {"device_id": device_id, "keep_id": keep_id})

            # Перепривязываем device_id к последнему пользователю (на всякий случай)
            session.execute(text("""
                UPDATE devices
                SET user_id = :user_id
                WHERE id = :keep_id
            """), {"user_id": keep_user_id, "keep_id": keep_id})

            print(f"{device_id}: keep id={keep_id} user_id={keep_user_id} ({len(devices)-1} duplicates deactivated)")

        session.commit()
        print("Done")
    finally:
        session.close()


if __name__ == "__main__":
    main()
