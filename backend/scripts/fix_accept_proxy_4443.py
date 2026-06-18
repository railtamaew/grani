#!/usr/bin/env python3
"""
Исправление acceptProxyProtocol для plain VLESS inbound на порту 4443.
При прямом подключении клиента (без haproxy/nginx) Xray с acceptProxyProtocol=true
ожидает PROXY header и сбрасывает соединение (connection reset by peer).

Запуск:
  PYTHONPATH=/opt/grani/backend python3 scripts/fix_accept_proxy_4443.py --ip 45.12.132.94
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

TARGET_PORT = 4443


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ip", type=str, default="45.12.132.94")
    parser.add_argument("--name", type=str)
    parser.add_argument("--dry-run", action="store_true", help="Только показать изменения, не применять")
    args = parser.parse_args()

    server = None
    try:
        from core.database import SessionLocal
        from models.server import Server
        db = SessionLocal()
        q = db.query(Server)
        if args.name:
            server = q.filter(Server.name == args.name).first()
        else:
            server = q.filter(Server.ip_address == args.ip).first()
        db.close()
    except Exception as e:
        print(f"БД: {e}")
        sys.exit(1)

    if not server:
        print(f"Сервер не найден: ip={args.ip} name={args.name}")
        sys.exit(1)

    config_path = getattr(server, "xray_config_path", None) or "/usr/local/etc/xray/config.json"

    def do_fix(client):
        sftp = client.open_sftp()
        try:
            with sftp.file(config_path, "r") as f:
                config = json.load(f)
        except Exception as e:
            try:
                with sftp.file("/etc/xray/config.json", "r") as f:
                    config = json.load(f)
            except Exception:
                raise e

        modified = False
        for ib in config.get("inbounds", []):
            if ib.get("port") != TARGET_PORT:
                continue
            stream = ib.setdefault("streamSettings", {})
            tcp = stream.setdefault("tcpSettings", {})
            if tcp.get("acceptProxyProtocol") is True:
                tcp["acceptProxyProtocol"] = False
                modified = True
                print(f"Inbound port {TARGET_PORT}: acceptProxyProtocol true -> false")

        if not modified:
            print("Изменений не требуется (acceptProxyProtocol уже false или отсутствует)")
            return 0

        if args.dry_run:
            print("\n[DRY-RUN] Изменения не применены")
            return 0

        config_json = json.dumps(config, indent=2)
        tmp_path = config_path + ".fix.tmp"
        with sftp.file(tmp_path, "w") as f:
            f.write(config_json)
        sftp.rename(config_path, config_path + ".bak")
        sftp.rename(tmp_path, config_path)
        sftp.close()

        stdin, stdout, stderr = client.exec_command(
            f"chmod 644 {config_path} && systemctl reload xray-v2 2>/dev/null || systemctl restart xray-v2"
        )
        exit_status = stdout.channel.recv_exit_status()
        if exit_status == 0:
            print("Xray перезагружен. Проверьте подключение клиента.")
        else:
            print("Ошибка reload:", stderr.read().decode())
        return 0 if exit_status == 0 else 1

    from services.remote_vpn_manager import RemoteVPNManager
    rm = RemoteVPNManager()
    return rm.with_ssh_connection(server, do_fix)


if __name__ == "__main__":
    sys.exit(main())
