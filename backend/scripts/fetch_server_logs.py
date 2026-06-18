#!/usr/bin/env python3
"""
Получение логов с VPN сервера (XRay + WireGuard) через RemoteVPNManager.
Использует сервер из БД по имени или IP; SSH по ключу из servers.ssh_key_content.
Без БД: --ip и --ssh-key-path (ключ в файле).
Пример: PYTHONPATH=/opt/grani/backend python3 scripts/fetch_server_logs.py --name HU-BUD-01
Пример без БД: ... fetch_server_logs.py --ip 45.12.132.94 --ssh-key-path /path/to/key.pem
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from services.remote_vpn_manager import RemoteVPNManager


def _make_server_from_args(args):
    """Минимальный объект сервера для get_ssh_config: host, port, user, key или password."""
    class ServerLike:
        def __init__(self, host, port=22, user="root", key_path=None, key_content=None, password=None, name=None, id_=0):
            self.ssh_host = host
            self.ssh_port = port
            self.ssh_user = user
            self.ssh_key_path = key_path
            self.ssh_key_content = key_content
            self.ssh_password = password
            self.ip_address = host
            self.name = name or host
            self.id = id_
    key_content = None
    if getattr(args, "ssh_key_path", None):
        path = os.path.expanduser(args.ssh_key_path)
        if os.path.isfile(path):
            with open(path, "r") as f:
                key_content = f.read()
    if not key_content and os.environ.get("SSH_KEY_CONTENT"):
        key_content = os.environ["SSH_KEY_CONTENT"]
    password = getattr(args, "ssh_password", None) or os.environ.get("SSH_PASSWORD")
    return ServerLike(
        host=args.ip,
        port=getattr(args, "ssh_port", None) or 22,
        user=getattr(args, "ssh_user", None) or "root",
        key_path=getattr(args, "ssh_key_path", None) if key_content else None,
        key_content=key_content,
        password=password,
        name=args.ip,
    )


def main():
    parser = argparse.ArgumentParser(description="Fetch logs from VPN server")
    parser.add_argument("--name", type=str, help="Server name (e.g. HU-BUD-01), требует БД")
    parser.add_argument("--ip", type=str, help="Server IP (e.g. 45.12.132.94)")
    parser.add_argument("--ssh-key-path", type=str, help="Путь к PEM ключу (если без БД)")
    parser.add_argument("--ssh-password", type=str, help="SSH пароль (или переменная SSH_PASSWORD)")
    parser.add_argument("--ssh-port", type=int, default=22)
    parser.add_argument("--ssh-user", type=str, default="root")
    parser.add_argument("--xray-lines", type=int, default=200, help="XRay journalctl lines")
    parser.add_argument("--wg-lines", type=int, default=150, help="WireGuard journalctl lines")
    args = parser.parse_args()

    server = None
    has_direct_auth = args.ssh_key_path or os.environ.get("SSH_KEY_CONTENT") or args.ssh_password or os.environ.get("SSH_PASSWORD")
    if (args.name or args.ip) and not (args.ip and has_direct_auth):
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
            if not server:
                print(f"Сервер не найден в БД: name={args.name!r} ip={args.ip!r}")
                sys.exit(1)
        except Exception as e:
            print(f"БД недоступна: {e}")
            if not args.ip:
                sys.exit(1)
            print("Попробуйте: --ip 45.12.132.94 --ssh-key-path /path/to/key.pem")
            sys.exit(1)

    if not server and args.ip:
        if not (getattr(args, "ssh_key_path", None) or os.environ.get("SSH_KEY_CONTENT") or getattr(args, "ssh_password", None) or os.environ.get("SSH_PASSWORD")):
            print("Для подключения без БД укажите --ssh-key-path, --ssh-password или переменные SSH_KEY_CONTENT / SSH_PASSWORD")
            sys.exit(1)
        server = _make_server_from_args(args)

    if not server:
        print("Укажите --name (и доступ к БД) или --ip и --ssh-key-path")
        sys.exit(1)

    print(f"Сервер: {server.name} ({getattr(server, 'ip_address', server.ssh_host)}) id={getattr(server, 'id', '?')}")
    print()

    rm = RemoteVPNManager()
    if not rm.ssh_manager:
        print("Ошибка: SSHManager недоступен (paramiko?)")
        sys.exit(1)

    # XRay journalctl
    print("=" * 60)
    print("XRay (journalctl -u xray-v2)")
    print("=" * 60)
    res = rm.get_xray_logs(server, log_type="journalctl", lines=args.xray_lines)
    if res.get("success"):
        for line in res.get("logs", []):
            print(line)
    else:
        print("Ошибка:", res.get("error", "?"))

    # XRay access.log (подключения)
    print()
    print("=" * 60)
    print("XRay access.log (последние подключения)")
    print("=" * 60)
    res_acc = rm.get_xray_logs(server, log_type="access", lines=args.xray_lines)
    if res_acc.get("success") and res_acc.get("logs"):
        for line in res_acc.get("logs", []):
            print(line)
    else:
        print(res_acc.get("error") or "Пусто или файл не найден")

    # XRay error.log (ошибки, отказы)
    print()
    print("=" * 60)
    print("XRay error.log (ошибки / отказ в подключении)")
    print("=" * 60)
    res_err = rm.get_xray_logs(server, log_type="error", lines=args.xray_lines)
    if res_err.get("success") and res_err.get("logs"):
        for line in res_err.get("logs", []):
            print(line)
    else:
        print(res_err.get("error") or "Пусто или файл не найден")

    print()
    print("=" * 60)
    print("WireGuard (journalctl -u wg-quick@wg0)")
    print("=" * 60)
    wg = rm.get_wireguard_logs(server, lines=args.wg_lines)
    if wg.get("success"):
        for line in wg.get("logs", []):
            print(line)
    else:
        print("Ошибка:", wg.get("error", "?"))


if __name__ == "__main__":
    main()
