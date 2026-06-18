#!/usr/bin/env python3
"""
Диагностика порта 4443 на VPN сервере 45.12.132.94:
- Какой inbound слушает порт 4443
- Есть ли plain VLESS (security=none) на этом порту
- Есть ли UUID b665c7a3-6fab-47f8-87fa-938c54075c0f в списке клиентов

Запуск:
  PYTHONPATH=/opt/grani/backend python3 scripts/diagnose_port_4443.py
  PYTHONPATH=/opt/grani/backend python3 scripts/diagnose_port_4443.py --ip 45.12.132.94 --ssh-key-path /path/to/key.pem
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

TARGET_UUID = "b665c7a3-6fab-47f8-87fa-938c54075c0f"
TARGET_PORT = 4443
CONFIG_PATHS = ["/usr/local/etc/xray/config.json", "/etc/xray/config.json"]


def _make_server_from_args(args):
    """Минимальный объект сервера для get_ssh_config."""
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
            self.xray_config_path = None

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
    parser = argparse.ArgumentParser(description="Диагностика порта 4443 на VPN сервере")
    parser.add_argument("--ip", type=str, default="45.12.132.94", help="IP сервера")
    parser.add_argument("--name", type=str, help="Имя сервера в БД (вместо --ip)")
    parser.add_argument("--ssh-key-path", type=str, help="Путь к PEM ключу")
    parser.add_argument("--ssh-password", type=str, help="SSH пароль")
    parser.add_argument("--ssh-port", type=int, default=22)
    parser.add_argument("--ssh-user", type=str, default="root")
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
            sys.exit(1)

    if not server and has_direct_auth:
        server = _make_server_from_args(args)

    if not server:
        print("Укажите --name или --ip и --ssh-key-path / SSH_KEY_CONTENT / SSH_PASSWORD")
        sys.exit(1)

    from services.remote_vpn_manager import RemoteVPNManager
    rm = RemoteVPNManager()
    try:
        cfg = rm.get_ssh_config(server)
    except Exception as e:
        print(f"Ошибка SSH конфига: {e}")
        sys.exit(1)

    def run(cmd, desc):
        r = rm.ssh_manager.execute_command(
            cfg["host"], cmd, cfg["port"], cfg["username"],
            cfg.get("key_path"), cfg.get("key_content"), cfg.get("password"),
        )
        out = (r.get("stdout") or "") + (r.get("stderr") or "")
        return out.strip(), r.get("success", False)

    print("=" * 70)
    print("  ДИАГНОСТИКА ПОРТА 4443 — 45.12.132.94")
    print("=" * 70)
    print(f"\nСервер: {server.name} ({server.ip_address})")

    # 1. Xray status
    out, ok = run("systemctl is-active xray-v2", "Xray status")
    print(f"\n1. Xray: {out}")

    # 2. Порты
    out, _ = run("ss -tlnp | grep -E '443|4443|8443'", "Порты")
    print(f"\n2. Порты:\n{out or '(пусто)'}")

    # 3. Читаем config.json
    config_path = getattr(server, "xray_config_path", None) or "/usr/local/etc/xray/config.json"
    out, ok = run(f"cat {config_path} 2>/dev/null || cat /etc/xray/config.json 2>/dev/null", "Config")
    if not out:
        print("\n3. Конфиг не найден")
        sys.exit(1)

    try:
        config = json.loads(out)
    except json.JSONDecodeError as e:
        print(f"\n3. Ошибка парсинга JSON: {e}")
        sys.exit(1)

    inbounds = config.get("inbounds", [])
    inbound_4443 = None
    for ib in inbounds:
        if ib.get("port") == TARGET_PORT:
            inbound_4443 = ib
            break

    print(f"\n3. Inbound на порту {TARGET_PORT}:")
    if not inbound_4443:
        print("   НЕ НАЙДЕН")
        print("\n   Все inbounds:")
        for ib in inbounds:
            print(f"   - port={ib.get('port')} protocol={ib.get('protocol')} tag={ib.get('tag', '')}")
        sys.exit(0)

    protocol = inbound_4443.get("protocol", "")
    stream = inbound_4443.get("streamSettings", {}) or {}
    security = stream.get("security", "none")
    tcp_settings = stream.get("tcpSettings", {}) or {}
    accept_proxy = tcp_settings.get("acceptProxyProtocol", False)
    settings = inbound_4443.get("settings", {}) or {}
    clients = settings.get("clients", [])
    decryption = settings.get("decryption", "none")

    print(f"   protocol: {protocol}")
    print(f"   streamSettings.security: {security}")
    print(f"   decryption: {decryption}")
    print(f"   tcpSettings.acceptProxyProtocol: {accept_proxy}")
    print(f"   tag: {inbound_4443.get('tag', '(нет)')}")

    is_plain_vless = protocol == "vless" and security == "none"
    print(f"\n4. Plain VLESS (security=none) на порту {TARGET_PORT}: {'ДА' if is_plain_vless else 'НЕТ'}")

    uuids = [c.get("id") for c in clients if c.get("id")]
    has_uuid = TARGET_UUID in uuids
    print(f"\n5. UUID {TARGET_UUID} в clients: {'ДА' if has_uuid else 'НЕТ'}")
    if clients:
        print(f"   Всего клиентов: {len(clients)}")
        for c in clients[:10]:
            uid = c.get("id", "")[:8] + "..."
            email = c.get("email", "")
            print(f"   - {uid} {email}")
        if len(clients) > 10:
            print(f"   ... и ещё {len(clients) - 10}")

    # 6. Логи по UUID
    out, _ = run(f"grep '{TARGET_UUID}' /var/log/xray/access.log 2>/dev/null | tail -5", "Access.log")
    if out:
        print(f"\n6. Access.log (последние 5):\n{out}")
    else:
        out, _ = run("tail -3 /var/log/xray/access.log 2>/dev/null", "Access.log tail")
        print(f"\n6. Access.log tail:\n{out or '(пусто)'}")

    out, _ = run(f"grep '{TARGET_UUID}' /var/log/xray/error.log 2>/dev/null | tail -5", "Error.log")
    if out:
        print(f"\n7. Error.log по UUID:\n{out}")

    # 8. Прокси перед Xray (haproxy, nginx)
    print("\n" + "-" * 70)
    print("8. ПРОКСИ ПЕРЕД XRAY (haproxy, nginx)")
    out, _ = run("ps aux | grep -E 'haproxy|nginx|caddy' | grep -v grep", "Процессы haproxy/nginx/caddy")
    print(out or "   Не найдены")
    out, _ = run("ss -tlnp | grep -E ':443|:4443|:80'", "Кто слушает 80/443/4443")
    print(out or "   (пусто)")
    for p in ["/etc/haproxy/haproxy.cfg", "/etc/nginx/nginx.conf", "/etc/caddy/Caddyfile"]:
        out, _ = run(f"test -f {p} && grep -E '4443|backend|upstream' {p} 2>/dev/null | head -20 || true", f"Конфиг {p}")
        if out:
            print(f"   {p}:\n{out[:500]}")

    # 9. Firewall, NAT, MTU
    print("\n" + "-" * 70)
    print("9. СЕТЕВОЙ ПУТЬ (firewall, NAT, MTU)")
    out, _ = run("iptables -L INPUT -n -v 2>/dev/null | head -25 || ufw status 2>/dev/null || true", "Firewall (iptables/ufw)")
    print(out or "   (нет доступа)")
    out, _ = run("ip route get 8.8.8.8 2>/dev/null | head -3", "Маршрут наружу")
    print(out or "   (пусто)")
    out, _ = run("ip link show | grep -E 'mtu|state'", "MTU интерфейсов")
    print(out or "   (пусто)")

    # 10. Внешние подключения к 4443 (последние)
    print("\n" + "-" * 70)
    print("10. ВНЕШНИЕ ПОДКЛЮЧЕНИЯ К 4443")
    out, _ = run("ss -tn state established '( dport = :4443 )' 2>/dev/null | head -10", "Established на 4443")
    print(out or "   (нет established)")
    out, _ = run("ss -tn state time-wait '( dport = :4443 )' 2>/dev/null | head -5", "TIME-WAIT на 4443")
    print(out or "   (пусто)")

    print("\n" + "=" * 70)
    print("  ИТОГ")
    print("=" * 70)
    if inbound_4443 and is_plain_vless and has_uuid:
        if accept_proxy:
            print("  ВНИМАНИЕ: acceptProxyProtocol=true при отсутствии прокси перед Xray.")
            print("  Клиент подключается напрямую — Xray ожидает PROXY header, connection reset.")
            print("  Рекомендация: установить acceptProxyProtocol: false в tcpSettings.")
        else:
            print("  Inbound на 4443 — VLESS plain (security=none), UUID в списке. Ожидаемо OK.")
    elif inbound_4443 and not is_plain_vless:
        print("  ВНИМАНИЕ: На 4443 НЕ plain VLESS (security != none). Клиент с encryption=none не сможет подключиться.")
    elif inbound_4443 and not has_uuid:
        print("  ВНИМАНИЕ: UUID отсутствует в clients. Добавьте клиента через create_vless_client.")
    else:
        print("  Inbound на 4443 не найден или не VLESS.")
    print()


if __name__ == "__main__":
    main()
