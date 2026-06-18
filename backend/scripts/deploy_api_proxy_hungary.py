#!/usr/bin/env python3
"""
Развёртывание nginx reverse proxy и certbot на HU-BUD-01 (45.12.132.94).

Использует RemoteVPNManager — SSH ключ из БД (servers.ssh_key_content).
Запуск: python3 backend/scripts/deploy_api_proxy_hungary.py (backend/.env подхватывается автоматически)
"""
import os
import sys

_scripts_dir = os.path.dirname(os.path.abspath(__file__))
if _scripts_dir not in sys.path:
    sys.path.insert(0, _scripts_dir)
from script_env import ensure_script_environment

ensure_script_environment()

from sqlalchemy import text
from core.database import SessionLocal
from models.server import Server
from services.remote_vpn_manager import RemoteVPNManager

# Конфиги nginx — рядом с server-config
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../..'))
CONFIG_DIR = os.path.join(PROJECT_ROOT, 'server-config', 'vpn-server-api-proxy')
API_PROXY_HTTP = os.path.join(CONFIG_DIR, 'api-proxy-http-only.conf')
API_PROXY_FULL = os.path.join(CONFIG_DIR, 'api-proxy.conf')


def load_config(path: str) -> str:
    with open(path, 'r', encoding='utf-8') as f:
        return f.read()


def deploy():
    db = SessionLocal()
    try:
        print("=" * 60)
        print("  Deploy API proxy на HU-BUD-01 (45.12.132.94)")
        print("=" * 60)

        # 1. Сервер из БД
        result = db.execute(text("""
            SELECT id, name, ip_address, ssh_host, ssh_port, ssh_user,
                   ssh_key_path, ssh_key_content, ssh_password
            FROM servers
            WHERE ip_address = '45.12.132.94' OR name ILIKE '%HU-BUD%'
            LIMIT 1
        """))
        row = result.first()
        if not row:
            print("❌ Сервер HU-BUD-01 (45.12.132.94) не найден в БД")
            return False

        server = db.query(Server).filter(Server.id == row[0]).first()
        if not server:
            print("❌ Не удалось загрузить объект сервера")
            return False

        rm = RemoteVPNManager()
        cfg = rm.get_ssh_config(server)
        host, port, user = cfg['host'], cfg['port'], cfg['username']
        print(f"✅ Сервер: {server.name} ({host})")

        if not os.path.exists(API_PROXY_HTTP) or not os.path.exists(API_PROXY_FULL):
            print(f"❌ Конфиги не найдены: {CONFIG_DIR}")
            return False

        http_conf = load_config(API_PROXY_HTTP)
        full_conf = load_config(API_PROXY_FULL)
        sm = rm.ssh_manager

        # 2. Nginx
        print("\n[1/5] Проверка nginx...")
        r = sm.execute_command(host, "which nginx || (apt-get update -qq && apt-get install -y nginx)",
                               port, user, cfg.get('key_path'), cfg.get('key_content'), cfg.get('password'))
        if not r['success'] and 'nginx' not in r.get('stdout', ''):
            print(f"   ⚠️ {r.get('stderr', r.get('stdout', ''))[:200]}")
        else:
            print("   ✅ nginx готов")

        # 3. HTTP-only конфиг
        print("\n[2/5] Копирование HTTP-only конфига...")
        ok = sm.upload_content(host, http_conf, "/tmp/api-proxy.conf", port, user,
                               cfg.get('key_path'), cfg.get('key_content'), cfg.get('password'))
        if not ok:
            print("   ❌ Ошибка загрузки конфига")
            return False
        r = sm.execute_command(host, "cp /tmp/api-proxy.conf /etc/nginx/conf.d/api-proxy.conf && nginx -t && systemctl reload nginx",
                               port, user, cfg.get('key_path'), cfg.get('key_content'), cfg.get('password'))
        if not r['success']:
            print(f"   ❌ nginx: {r.get('stderr', r.get('stdout', ''))}")
            return False
        print("   ✅ HTTP конфиг применён")

        # 4. Certbot: SAN api.granilink.com + api.granilink.com (Cloudflare вариант A → HU-BUD)
        print("\n[3/5] Сертификат Let's Encrypt (api.granilink.com + api.granilink.com)...")
        sm.command_timeout = 120
        install_certbot = "(which certbot 2>/dev/null) || (apt-get update -qq && apt-get install -y certbot python3-certbot-nginx)"
        # --expand: добавить api.granilink.com к существующему сертификату; иначе первичная выдача на оба -d
        # Цепочка: expand SAN → новая выдача на оба имени → только granilink (если granilink.com ещё не указывает на ноду)
        certbot_base = "certbot certonly --nginx --non-interactive --agree-tos -m admin@granilink.com"
        certbot_chain = (
            f"({certbot_base} --expand -d api.granilink.com -d api.granilink.com) || "
            f"({certbot_base} -d api.granilink.com -d api.granilink.com) || "
            f"({certbot_base} -d api.granilink.com)"
        )
        certbot_try = f"{install_certbot} && {certbot_chain}"
        r = sm.execute_command(host, certbot_try, port, user, cfg.get('key_path'), cfg.get('key_content'), cfg.get('password'))
        if r['success']:
            print("   ✅ Certbot выполнен (проверьте SAN: openssl x509 -in /etc/letsencrypt/live/api.granilink.com/fullchain.pem -noout -text | grep DNS)")
        else:
            out = (r.get('stderr') or r.get('stdout') or '')[:600]
            print(f"   ⚠️ Certbot: {out[:300]}")
            r2 = sm.execute_command(host, "test -d /etc/letsencrypt/live/api.granilink.com && echo exists || echo missing",
                                    port, user, cfg.get('key_path'), cfg.get('key_content'), cfg.get('password'))
            if r2.get('stdout', '').strip() != 'exists':
                print("   ❌ Нет сертификата api.granilink.com")
                return False
            print("   ✅ Есть сертификат granilink; при появлении api.granilink.com на этой ноде перезапустите скрипт для SAN")

        # 5. Полный конфиг с SSL
        print("\n[4/5] Копирование полного конфига с SSL...")
        ok = sm.upload_content(host, full_conf, "/tmp/api-proxy.conf", port, user,
                               cfg.get('key_path'), cfg.get('key_content'), cfg.get('password'))
        if not ok:
            print("   ❌ Ошибка загрузки конфига")
            return False
        r = sm.execute_command(host, "cp /tmp/api-proxy.conf /etc/nginx/conf.d/api-proxy.conf && nginx -t && systemctl reload nginx",
                               port, user, cfg.get('key_path'), cfg.get('key_content'), cfg.get('password'))
        if not r['success']:
            print(f"   ❌ nginx: {r.get('stderr', r.get('stdout', ''))}")
            return False
        print("   ✅ SSL конфиг применён")

        # 5b. ufw: запасной HTTPS API на 8444 (8443 = VMESS, не трогаем)
        print("\n[4b/5] Firewall ufw (8444/tcp для nginx API)...")
        ufw_cmd = (
            "if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -q active; then "
            "ufw allow 8444/tcp comment 'nginx-api-https-alt' || true; "
            "echo ufw_ok; else echo ufw_skip; fi"
        )
        r_ufw = sm.execute_command(host, ufw_cmd, port, user, cfg.get('key_path'), cfg.get('key_content'), cfg.get('password'))
        print(f"   {r_ufw.get('stdout', '').strip() or r_ufw.get('stderr', '')[:120]}")

        # 6. Проверка (443 и 8444)
        print("\n[5/5] Проверка...")
        r = sm.execute_command(host, "curl -s -o /dev/null -w '%{http_code}' https://127.0.0.1/api/vpn/bootstrap -k -H 'Host: api.granilink.com' 2>/dev/null || echo 000",
                               port, user, cfg.get('key_path'), cfg.get('key_content'), cfg.get('password'))
        code = (r.get('stdout') or '').strip() or '000'
        print(f"   443 → bootstrap HTTP код: {code}")
        r2 = sm.execute_command(host, "curl -s -o /dev/null -w '%{http_code}' https://127.0.0.1:8444/api/vpn/bootstrap -k -H 'Host: api.granilink.com' 2>/dev/null || echo 000",
                                  port, user, cfg.get('key_path'), cfg.get('key_content'), cfg.get('password'))
        code_alt = (r2.get('stdout') or '').strip() or '000'
        print(f"   8444 → bootstrap HTTP код: {code_alt}")
        r3 = sm.execute_command(host, "curl -s -o /dev/null -w '%{http_code}' https://127.0.0.1/api/vpn/bootstrap -k -H 'Host: api.granilink.com' 2>/dev/null || echo 000",
                                 port, user, cfg.get('key_path'), cfg.get('key_content'), cfg.get('password'))
        print(f"   443 → bootstrap (Host api.granilink.com): {(r3.get('stdout') or '').strip() or '000'}")

        print("\n" + "=" * 60)
        print("  Готово. Откройте TCP 8444 в firewall облака (DigitalOcean и т.д.). 8443 = VMESS.")
        print("  Проверьте снаружи:")
        print("  curl -s -o /dev/null -w '%{http_code}' https://api.granilink.com/api/vpn/bootstrap")
        print("  curl -s -o /dev/null -w '%{http_code}' https://api.granilink.com/api/vpn/bootstrap")
        print("  curl -s -o /dev/null -w '%{http_code}' https://api.granilink.com:8444/api/vpn/bootstrap")
        print("  curl -s https://api.granilink.com/health")
        print("=" * 60)
        return True

    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        db.close()


if __name__ == "__main__":
    success = deploy()
    sys.exit(0 if success else 1)
