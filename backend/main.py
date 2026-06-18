from fastapi import FastAPI, Depends
from fastapi import HTTPException
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, FileResponse, PlainTextResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.staticfiles import StaticFiles
from sqlalchemy.orm import Session
from datetime import datetime
from time import perf_counter
import logging
import time
import logging.handlers
import os

# Импорт всех моделей для правильной инициализации relationships
# Это нужно сделать ДО импорта роутеров, чтобы все модели были зарегистрированы в SQLAlchemy
# Импортируем в правильном порядке: сначала базовые модели, потом зависимые
# ВАЖНО: импортируем все модели, чтобы они были в SQLAlchemy registry
import models.subscription  # Импортируем первым, так как на него ссылаются другие модели
import models.payment
import models.auth_code
import models.protocol_stats
import models.protocol
import models.telemetry
import models.audit_log
import models.admin_login_log
import models.system_setting
import models.observability
from models.subscription import Subscription, Plan
from models.payment import Payment
from models.auth_code import AuthCode
from models.protocol_stats import ProtocolStats
from models.protocol import Protocol
from models.telemetry import TelemetryEvent
from models.audit_log import AuditLog
from models.admin_login_log import AdminLoginLog
from models.system_setting import SystemSetting
from models.observability import ObservabilityEvent, ObservabilityIncident, EventDictionary
from models.user import User, Device  # Импортируем после subscription
from models.server import Server, ConnectionLog  # Импортируем после user
from models.client_log import ClientLog  # Модель для логов от клиентов
import models.user
import models.server
import models.client_log
import models.edge_node_assignment

# Импорт роутеров
from api import auth, admin, vpn, xray, xray_v2, internal_node, simple_vpn
from api import telegram_support
from api import admin_auth
from api import admin_observability
from api import bootstrap
try:
    from api import client_logs
except ImportError as e:
    print(f"Warning: Failed to import client_logs: {e}")
    client_logs = None
try:
    from api import payments
except ImportError:
    payments = None

# Импорт новых админ-роутеров
try:
    from api import admin_protocols
except ImportError as e:
    print(f"Warning: Failed to import admin_protocols: {e}")
    admin_protocols = None

try:
    from api import admin_incidents
except ImportError as e:
    print(f"Warning: Failed to import admin_incidents: {e}")
    admin_incidents = None

try:
    from api import admin_audit
except ImportError as e:
    print(f"Warning: Failed to import admin_audit: {e}")
    admin_audit = None

try:
    from api import admin_settings
except ImportError as e:
    print(f"Warning: Failed to import admin_settings: {e}")
    admin_settings = None

try:
    from api import admin_metrics
except ImportError as e:
    raise RuntimeError(
        "Critical admin diagnostics router import failed: api.admin_metrics"
    ) from e

try:
    from api import telemetry
except ImportError as e:
    print(f"Warning: Failed to import telemetry: {e}")
    telemetry = None

try:
    from api import app_config
except ImportError as e:
    print(f"Warning: Failed to import app_config: {e}")
    app_config = None

try:
    from api import servers
except ImportError:
    servers = None
try:
    from api import vpn_servers
except ImportError:
    vpn_servers = None

try:
    from schemas.common import ErrorResponse, ErrorBody
except ImportError:
    # Fallback если schemas нет
    from typing import Dict, Any, List, Optional
    class ErrorBody:
        def __init__(self, code: str, message: str, details: Optional[List[Dict[str, Any]]] = None):
            self.code = code
            self.message = message
            self.details = details or []
        def dict(self):
            result = {"code": self.code, "message": self.message}
            if self.details:
                result["details"] = self.details
            return result
    class ErrorResponse:
        def __init__(self, error: ErrorBody):
            self.error = error
        def dict(self):
            return {"error": self.error.dict()}
from core.config import settings
from core.exception_handlers import register_exception_handlers
from core.database import get_db
from core.request_context import (
    RequestIdMiddleware,
    attach_request_id_filter_to_root_logger,
    get_request_id,
)
from core.perf_logging import perf_logger, setup_perf_logging

# Настройка логирования
_log_path = settings.backend_log_file
_log_dir = os.path.dirname(_log_path)
if _log_dir:
    try:
        os.makedirs(_log_dir, exist_ok=True)
    except OSError:
        pass
# WARNING снижает sync I/O от логов на hot path; [perf] и ошибки — через logger.warning/error.
log_level = logging.WARNING
_stream = logging.StreamHandler()
_file = logging.handlers.RotatingFileHandler(
    _log_path,
    maxBytes=max(1, int(settings.backend_log_max_bytes)),
    backupCount=max(0, int(settings.backend_log_backup_count)),
    encoding="utf-8",
)
logging.basicConfig(
    level=log_level,
    handlers=[_stream, _file],
    force=True,
)

setup_perf_logging(settings)

attach_request_id_filter_to_root_logger()

app = FastAPI(
    title="GRANI API",
    description="API для VPN-сервиса GRANI",
    version="1.0.0",
    docs_url="/docs" if not settings.is_production else None,
    redoc_url="/redoc" if not settings.is_production else None,
)

# Сквозной X-Request-ID (ближе всего к приложению — contextvars для всех логов в обработчике)
app.add_middleware(RequestIdMiddleware)

# Регистрация централизованных обработчиков ошибок
register_exception_handlers(app)

# Метрики запросов
@app.middleware("http")
async def metrics_middleware(request, call_next):
    from core.metrics import metrics_registry

    if not settings.metrics_enabled:
        return await call_next(request)

    start = perf_counter()
    route_path = request.scope.get("route").path if request.scope.get("route") else request.url.path
    method = request.method
    status_code = 500
    try:
        response = await call_next(request)
        status_code = response.status_code
        return response
    except Exception:
        status_code = 500
        raise
    finally:
        duration_ms = (perf_counter() - start) * 1000
        metrics_registry.record_request(f"{method} {route_path}", duration_ms, status_code)

# Сжатие ответов (GZip)
app.add_middleware(GZipMiddleware, minimum_size=1000)

# Настройка CORS
# В production разрешаем только production домены
# В development/staging разрешаем localhost и все домены
cors_origins = settings.allowed_origins.copy()
if not settings.is_production:
    # В development/staging разрешаем все localhost порты через regex
    import re
    cors_allow_origin_regex = r"http://localhost:\d+|http://127\.0\.0\.1:\d+"
else:
    # В production используем только явно указанные домены
    cors_allow_origin_regex = None

app.add_middleware(
    CORSMiddleware,
    allow_origins=cors_origins,
    allow_origin_regex=cors_allow_origin_regex if not settings.is_production else None,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def timing_middleware(request, call_next):
    """Полное wall time запроса (очередь + handler + middleware ниже по стеку)."""
    t0 = time.monotonic()
    status_code = 500
    response = await call_next(request)
    status_code = getattr(response, "status_code", 500)
    dt_ms = (time.monotonic() - t0) * 1000
    rid = getattr(getattr(request, "state", None), "request_id", None) or get_request_id()
    perf_logger.warning(
        "[perf] middleware_total dt_ms=%.1f method=%s path=%s status=%s req_id=%s",
        dt_ms,
        request.method,
        request.url.path,
        status_code,
        rid,
    )
    return response


# Подключение роутеров
app.include_router(auth.router, prefix="/api/auth", tags=["auth"])
app.include_router(admin_auth.router, prefix="/api/admin/auth", tags=["admin-auth"])
app.include_router(admin.router, prefix="/api/admin", tags=["admin"])
app.include_router(admin_observability.router, tags=["admin-observability"])

# Новые админ-роутеры (если импортированы)
if admin_protocols:
    app.include_router(admin_protocols.router, prefix="/api/admin", tags=["admin-protocols"])
if admin_incidents:
    app.include_router(admin_incidents.router, prefix="/api/admin", tags=["admin-incidents"])
if admin_audit:
    app.include_router(admin_audit.router, prefix="/api/admin", tags=["admin-audit"])
if admin_settings:
    app.include_router(admin_settings.router, prefix="/api/admin", tags=["admin-settings"])
if admin_metrics:
    app.include_router(admin_metrics.router, prefix="/api/admin", tags=["admin-metrics"])
if telemetry:
    app.include_router(telemetry.router, prefix="/api", tags=["telemetry"])
if app_config:
    app.include_router(app_config.router, prefix="/api", tags=["app-config"])

if payments:
    app.include_router(payments.router, prefix="/api/payments", tags=["payments"])
app.include_router(vpn.router, prefix="/api/vpn", tags=["vpn"])
app.include_router(simple_vpn.router)
app.include_router(telegram_support.router)
app.include_router(
    internal_node.router,
    prefix="/api/internal/node/v1",
    tags=["internal-node"],
)
app.include_router(bootstrap.router)
app.include_router(xray.router, tags=["Xray VPN"])
app.include_router(xray_v2.router, tags=["Xray VPN V2"])
if client_logs:
    app.include_router(client_logs.router, tags=["VPN Client Logs"])
if servers:
    app.include_router(servers.router, prefix="/api/servers", tags=["servers"])
if vpn_servers:
    app.include_router(vpn_servers.router, tags=["vpn-servers"])

# Статические файлы
static_dir = os.path.join(os.path.dirname(__file__), "static")
if os.path.exists(static_dir):
    app.mount("/static", StaticFiles(directory=static_dir), name="static")

# Страница просмотра кодов
@app.get("/codes")
async def codes_page():
    """HTML страница для просмотра кодов авторизации"""
    codes_html_path = os.path.join(os.path.dirname(__file__), "static", "auth_codes.html")
    if os.path.exists(codes_html_path):
        return FileResponse(codes_html_path)
    else:
        raise HTTPException(status_code=404, detail="Страница не найдена")

@app.get("/")
async def root():
    return {"message": "GRANI API", "version": "1.0.0"}

@app.get("/health")
async def health_check(db: Session = Depends(get_db)):
    """Проверка здоровья системы"""
    from services.health_service import HealthService
    health_service = HealthService(db)
    return health_service.get_full_health()


@app.get("/api/health")
async def api_health_check(db: Session = Depends(get_db)):
    """Тот же ответ, что и GET /health (удобно при базовом URL с префиксом /api)."""
    from services.health_service import HealthService
    health_service = HealthService(db)
    return health_service.get_full_health()


@app.get("/health/queues")
async def health_celery_queues():
    """Только глубина очередей Celery в Redis (без БД, для мониторинга)."""
    from services.health_service import HealthService
    return HealthService.check_celery_queues()


@app.get("/api/health/queues")
async def api_health_celery_queues():
    """То же, что GET /health/queues, при базовом URL с префиксом /api."""
    from services.health_service import HealthService
    return HealthService.check_celery_queues()


@app.get("/metrics/prometheus", response_class=PlainTextResponse)
async def prometheus_metrics():
    """
    Метрики в формате Prometheus text (для scrape).
    Включите METRICS_PROMETHEUS_ENABLED=1; в production ограничьте доступ в nginx (internal IP).
    """
    from core.metrics import metrics_registry

    if not settings.metrics_enabled or not settings.metrics_prometheus_enabled:
        raise HTTPException(status_code=404, detail="Not found")
    return PlainTextResponse(
        metrics_registry.prometheus_text(),
        media_type="text/plain; charset=utf-8; version=0.0.4",
    )


@app.get("/api/metrics/prometheus", response_class=PlainTextResponse)
async def api_prometheus_metrics():
    """То же, что GET /metrics/prometheus, при базовом URL с префиксом /api."""
    return await prometheus_metrics()

@app.get("/api/test")
async def test_endpoint():
    return {"message": "API работает!", "status": "success"}


@app.on_event("startup")
async def startup_warm_caches():
    """Pre-warm caches on startup to avoid cold latency on first auth."""
    import asyncio
    try:
        from services.google_oauth_service import warm_jwks_cache
        await asyncio.to_thread(warm_jwks_cache)
    except Exception as e:
        logging.getLogger(__name__).warning("Startup warm JWKS: %s", e)


@app.on_event("startup")
async def startup_voided_purchases_scheduler():
    """Запуск периодической проверки voided purchases (каждые 6 часов)."""
    import asyncio

    async def _loop():
        await asyncio.sleep(60)
        while True:
            try:
                from api.payments import check_voided_purchases
                from core.database import SessionLocal
                db = SessionLocal()
                try:
                    await asyncio.to_thread(check_voided_purchases, db)
                finally:
                    db.close()
            except Exception as e:
                logging.getLogger(__name__).warning("voided_purchases_scheduler: %s", e)
            await asyncio.sleep(6 * 3600)

    asyncio.create_task(_loop())


@app.on_event("startup")
async def startup_warm_xray_cache():
    """Прогрев кэша конфигов Xray для активных серверов (в фоне, короткая задержка после старта)."""
    import asyncio

    async def _warm():
        await asyncio.sleep(0.5)
        try:
            from core.database import SessionLocal
            from services.xray_manager import warm_xray_config_cache_for_active_servers
            db = SessionLocal()
            try:
                await asyncio.to_thread(warm_xray_config_cache_for_active_servers, db)
            finally:
                db.close()
        except Exception as e:
            logging.getLogger(__name__).warning("Startup warm Xray cache: %s", e)

    asyncio.create_task(_warm())


# Глобальные обработчики ошибок регистрируются через register_exception_handlers()
# См. core/exception_handlers.py

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=False
    )
