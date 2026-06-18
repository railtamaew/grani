#!/usr/bin/env python3
"""
Добавляет cron-задачу на VPN-сервер: проверка Xray каждые 5 мин, автозапуск при падении.
Использует RemoteVPNManager (ключ из servers.ssh_key_content).

Пример: PYTHONPATH=/opt/grani/backend python3 scripts/setup_xray_cron_watchdog.py --name HU-BUD-01
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from core.database import SessionLocal
from models.server import Server
from services.remote_vpn_manager import RemoteVPNManager

CRON_LINE = "*/5 * * * * systemctl is-active xray-v2 >/dev/null 2>&1 || systemctl start xray-v2"
CRON_MARKER = "xray watchdog"


def main():
    parser = argparse.ArgumentParser(description="Setup Xray cron watchdog on VPN server")
    parser.add_argument("--name", type=str, default="HU-BUD-01", help="Server name (e.g. HU-BUD-01)")
    args = parser.parse_args()

    db = SessionLocal()
    try:
        server = db.query(Server).filter(Server.name == args.name).first()
        if not server:
            print(f"❌ Сервер {args.name} не найден в БД")
            return 1

        rm = RemoteVPNManager()
        if not rm.ssh_manager:
            print("❌ SSHManager недоступен")
            return 1

        cfg = rm.get_ssh_config(server)
        if not cfg:
            print("❌ Не удалось получить SSH конфиг")
            return 1

        # Команда: добавить cron, если ещё нет
        # Удаляем старые строки с маркером, добавляем новую
        cmd = f"""(crontab -l 2>/dev/null | grep -v "{CRON_MARKER}" || true; echo '# {CRON_MARKER}'; echo '{CRON_LINE}') | crontab -"""
        result = rm.ssh_manager.execute_command(
            cfg["host"],
            cmd,
            cfg["port"],
            cfg["username"],
            cfg.get("key_path"),
            cfg.get("key_content"),
            cfg.get("password"),
        )

        if not result.get("success"):
            print(f"❌ Ошибка: {result.get('stderr', result.get('stdout', '?'))}")
            return 1

        # Проверяем, что cron добавлен
        check = rm.ssh_manager.execute_command(
            cfg["host"],
            "crontab -l 2>/dev/null | grep -E 'xray|systemctl' || true",
            cfg["port"],
            cfg["username"],
            cfg.get("key_path"),
            cfg.get("key_content"),
            cfg.get("password"),
        )
        out = (check.get("stdout") or "").strip()
        print(f"✅ Cron добавлен на {server.name} ({server.ip_address})")
        if out:
            print(f"   Текущие записи: {out}")
        return 0
    finally:
        db.close()


if __name__ == "__main__":
    sys.exit(main())
