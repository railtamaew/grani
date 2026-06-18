#!/usr/bin/env python3
"""Быстрая диагностика HU-BUD-01: порты, Xray, access.log по IP клиента"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from core.database import SessionLocal
from models.server import Server
from services.remote_vpn_manager import RemoteVPNManager

def main():
    db = SessionLocal()
    try:
        server = db.query(Server).filter(Server.name == "HU-BUD-01").first()
        if not server:
            print("Сервер HU-BUD-01 не найден")
            return 1

        rm = RemoteVPNManager()
        cfg = rm.get_ssh_config(server)
        if not cfg:
            print("Не удалось получить SSH конфиг")
            return 1

        def run(cmd, desc):
            r = rm.ssh_manager.execute_command(
                cfg['host'], cmd, cfg['port'], cfg['username'],
                cfg.get('key_path'), cfg.get('key_content'), cfg.get('password')
            )
            out = (r.get('stdout') or '') + (r.get('stderr') or '')
            print(f"\n=== {desc} ===\n{out or '(пусто)'}")
            return r.get('success', False)

        print("Сервер:", server.name, server.ip_address)
        run("systemctl is-active xray-v2", "Xray status")
        run("ss -tlnp | grep -E '443|4443|8443|10085'", "Порты Xray")
        run("wc -l /usr/local/etc/xray/config.json 2>/dev/null && head -c 500 /usr/local/etc/xray/config.json", "Config.json (первые 500 байт)")
        run("grep -E '81.222.191.156|1_89@granivpn' /var/log/xray/access.log 2>/dev/null | tail -15", "Access.log: клиент 81.222.191.156 / 1_89")
        run("grep '81.222.191.156' /var/log/xray/error.log 2>/dev/null | tail -10", "Error.log: клиент 81.222.191.156")
    finally:
        db.close()

if __name__ == "__main__":
    sys.exit(main() or 0)
