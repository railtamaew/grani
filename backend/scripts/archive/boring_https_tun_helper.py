#!/usr/bin/env python3
"""
TUN-хелпер для Boring HTTPS gateway (сценарий 4).

Создаёт TUN-интерфейс, слушает Unix-сокет. При получении сообщения (4 байта BE длина + IP payload):
записывает payload в TUN, читает один пакет из TUN (с таймаутом), возвращает 4 байта длина + пакет.

Требуется запуск с правами root (или CAP_NET_ADMIN). Для маршрутизации трафика в интернет
нужны IP forwarding и NAT (см. --setup-routing и документацию).

Использование:
  sudo python3 boring_https_tun_helper.py --socket /run/grani/boring_https_tun.sock
  sudo python3 boring_https_tun_helper.py --socket /run/grani/boring_https_tun.sock --tun-ip 10.0.0.1/30 --setup-routing
"""
import argparse
import fcntl
import os
import select
import socket
import struct
import subprocess
import sys

# Linux TUN
TUNSETIFF = 0x400454CA
IFF_TUN = 0x0001
IFF_NO_PI = 0x1000
IFNAMSIZ = 16


def create_tun(dev_name: str = "tun0") -> int:
    """Создаёт TUN-устройство, возвращает файловый дескриптор."""
    fd = os.open("/dev/net/tun", os.O_RDWR)
    # ifreq: name (16 bytes) + flags (2 bytes)
    ifr = struct.pack(f"{IFNAMSIZ}sH", dev_name.encode().ljust(IFNAMSIZ), IFF_TUN | IFF_NO_PI)
    fcntl.ioctl(fd, TUNSETIFF, ifr)
    return fd


def setup_tun_ip(dev_name: str, tun_ip: str) -> None:
    """Назначает адрес TUN и поднимает интерфейс."""
    subprocess.run(["ip", "addr", "add", tun_ip, "dev", dev_name], check=True)
    subprocess.run(["ip", "link", "set", dev_name, "up"], check=True)


def setup_routing(tun_cidr: str, out_interface: str | None) -> None:
    """Включает IP forwarding и NAT для подсети TUN."""
    subprocess.run(["sysctl", "-w", "net.ipv4.ip_forward=1"], check=True, capture_output=True)
    if out_interface is None:
        # Попытка определить интерфейс по маршруту по умолчанию
        r = subprocess.run(["ip", "route", "show", "default"], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            out_interface = r.stdout.split()[4] if len(r.stdout.split()) >= 5 else "eth0"
        else:
            out_interface = "eth0"
    # NAT: трафик из tun_cidr наружу через out_interface
    subprocess.run([
        "iptables", "-t", "nat", "-A", "POSTROUTING",
        "-s", tun_cidr, "-o", out_interface, "-j", "MASQUERADE"
    ], check=True)


def recv_exact(sock: socket.socket, n: int, timeout: float = 10.0) -> bytes | None:
    """Читает ровно n байт. При таймауте или EOF возвращает None."""
    sock.settimeout(timeout)
    buf = b""
    while len(buf) < n:
        try:
            chunk = sock.recv(n - len(buf))
        except socket.timeout:
            return None
        if not chunk:
            return None
        buf += chunk
    return buf


def handle_client(conn: socket.socket, tun_fd: int, recv_timeout: float) -> None:
    """Обрабатывает один запрос: 4 байта длина + payload -> TUN; читаем ответ из TUN -> 4 + payload."""
    try:
        header = recv_exact(conn, 4, timeout=5.0)
        if header is None or len(header) < 4:
            return
        length = (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3]
        if length <= 0 or length > 0xFFFF:
            return
        payload = recv_exact(conn, length, timeout=5.0)
        if payload is None:
            return
        # Запись в TUN
        os.write(tun_fd, payload)
        # Чтение одного пакета из TUN с таймаутом
        r, _, _ = select.select([tun_fd], [], [], recv_timeout)
        if not r:
            # Таймаут — отдаём пустой пакет (длина 0)
            conn.sendall(struct.pack(">I", 0))
            return
        # Читаем один IP-пакет (макс 64K)
        response = os.read(tun_fd, 65536)
        if not response:
            conn.sendall(struct.pack(">I", 0))
            return
        conn.sendall(struct.pack(">I", len(response)) + response)
    except (BrokenPipeError, ConnectionResetError, OSError):
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description="TUN-хелпер для Boring HTTPS gateway")
    parser.add_argument("--socket", required=True, help="Путь к Unix-сокету (например /run/grani/boring_https_tun.sock)")
    parser.add_argument("--tun-name", default="tun0", help="Имя TUN-интерфейса")
    parser.add_argument("--tun-ip", default="10.0.0.1/30", help="Адрес TUN; для Android-клиента (10.0.0.2/30) оставить 10.0.0.1/30")
    parser.add_argument("--setup-routing", action="store_true", help="Включить ip_forward и NAT для подсети TUN")
    parser.add_argument("--out-interface", default=None, help="Исходящий интерфейс для NAT (по умолчанию — из ip route)")
    parser.add_argument("--recv-timeout", type=float, default=5.0, help="Таймаут чтения ответа из TUN (сек)")
    args = parser.parse_args()

    if os.geteuid() != 0:
        print("Запуск требуется с правами root (CAP_NET_ADMIN).", file=sys.stderr)
        return 1

    tun_fd = create_tun(args.tun_name)
    try:
        setup_tun_ip(args.tun_name, args.tun_ip)
    except subprocess.CalledProcessError as e:
        print(f"Ошибка настройки TUN IP: {e}", file=sys.stderr)
        os.close(tun_fd)
        return 1

    if args.setup_routing:
        try:
            # CIDR для NAT — подсеть клиентов (должна совпадать с TUN; Android использует 10.0.0.2/30)
            cidr = args.tun_ip if "/" in args.tun_ip else "10.0.0.0/30"
            net = cidr.split("/")[0].rsplit(".", 1)[0] + ".0/" + cidr.split("/")[1]
            setup_routing(net, args.out_interface)
        except subprocess.CalledProcessError as e:
            print(f"Предупреждение: настройка маршрутизации: {e}", file=sys.stderr)

    sock_path = args.socket
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    os.makedirs(os.path.dirname(sock_path) or ".", exist_ok=True)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    os.chmod(sock_path, 0o660)
    server.listen(32)
    print(f"TUN-хелпер: TUN {args.tun_name} {args.tun_ip}, сокет {sock_path}", file=sys.stderr)

    try:
        while True:
            conn, _ = server.accept()
            handle_client(conn, tun_fd, args.recv_timeout)
    except KeyboardInterrupt:
        pass
    finally:
        server.close()
        if os.path.exists(sock_path):
            os.unlink(sock_path)
        os.close(tun_fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
