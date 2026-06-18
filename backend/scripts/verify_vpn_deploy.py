#!/usr/bin/env python3
"""
Проверка конфигурации после деплоя API (VPN-оптимизации).
Запуск из корня backend: python scripts/verify_vpn_deploy.py
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))


def main():
    ok = 0
    warn = 0

    print("Проверка конфигурации деплоя (VPN/Redis/Celery)\n")

    # Redis
    redis_url = os.getenv("REDIS_URL", "").strip()
    if redis_url and redis_url.startswith("redis://"):
        print("  [OK] REDIS_URL задан")
        ok += 1
    else:
        print("  [!!] REDIS_URL не задан или неверен — Celery и Redis-кэш не будут работать")
        warn += 1

    # Cache / rate limit (рекомендация при нескольких воркерах)
    cache = os.getenv("CACHE_BACKEND", "memory").lower()
    rate = os.getenv("RATE_LIMIT_STORE", "memory").lower()
    workers = os.getenv("GUNICORN_WORKERS", os.getenv("USE_GUNICORN", ""))
    multi_worker = str(workers).strip() and str(workers) != "0"
    if multi_worker:
        if cache == "redis" and rate == "redis":
            print("  [OK] CACHE_BACKEND=redis, RATE_LIMIT_STORE=redis (для нескольких воркеров)")
            ok += 1
        else:
            print("  [!!] При нескольких воркерах задайте CACHE_BACKEND=redis и RATE_LIMIT_STORE=redis")
            warn += 1
    else:
        print("  [--] Один процесс (GUNICORN не используется) — memory-кэш допустим")

    # Celery (опционально: пинг воркера)
    try:
        from services.celery_app import celery_app
        inspector = celery_app.control.inspect(timeout=2.0)
        ping = inspector.ping() if inspector else None
        if ping:
            print("  [OK] Celery worker доступен (vpn.apply_xray_config будет в очереди)")
            ok += 1
        else:
            print("  [!!] Celery worker не отвечает — create-client будет применять конфиг синхронно по SSH")
            warn += 1
    except Exception as e:
        print(f"  [!!] Celery недоступен: {e}")
        warn += 1

    print()
    if warn:
        print(f"Итого: {ok} проверок OK, {warn} предупреждений. Устраните предупреждения для продакшена.")
    else:
        print("Конфигурация в порядке для продакшена.")
    return 0 if warn == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
