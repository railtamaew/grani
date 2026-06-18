"""
Addon для mitmproxy: симулятор DPI/SNI для лаборатории обхода блокировок (план new_vpn_bypass_scenarios).
Правила: блок по SNI (разрыв соединения = RST-подобное поведение); опционально блок по JA3.
Задайте BLOCKED_SNI и при необходимости BLOCKED_JA3 (значения JA3 из pcap: bypass_lab_capture_traffic.py --analyze).
Запуск: mitmproxy -s sni_block_simulator_addon.py
Клиент должен использовать прокси 127.0.0.1:8080 и доверять CA mitmproxy.
"""
from mitmproxy import ctx, connection

# Домены, которые «цензор» блокирует (разрыв соединения при таком SNI).
BLOCKED_SNI = [
    # "api.granilink.com",
    # "vpn.example.com",
]

# JA3-отпечатки для блокировки (заполнить из pcap: python bypass_lab_capture_traffic.py --analyze capture.pcap).
# Если список непуст и mitmproxy передаёт JA3 в событии — соединение с таким отпечатком разрывается.
BLOCKED_JA3 = []


def sni_value(conn: connection.Server) -> str:
    sni = getattr(conn, "sni", None) or ""
    return (sni or "").strip().lower()


def request(flow):
    sni = sni_value(flow.server_conn) if flow.server_conn else ""
    if not sni:
        return
    for blocked in BLOCKED_SNI:
        if blocked.lower() in sni or sni == blocked.lower():
            ctx.log.warn(f"[DPI/SNI simulator] Block (SNI): {sni}")
            flow.kill()
            return
    # Блок по JA3: если в flow есть атрибут с отпечатком (зависит от версии mitmproxy)
    if BLOCKED_JA3 and hasattr(flow, "client_conn"):
        ja3 = getattr(flow.client_conn, "ja3", None) or getattr(flow.client_conn, "tls_fingerprint", None)
        if ja3 and ja3 in BLOCKED_JA3:
            ctx.log.warn(f"[DPI/SNI simulator] Block (JA3): {ja3}")
            flow.kill()
            return
