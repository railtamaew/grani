from sqlalchemy import create_engine, event
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import QueuePool
from core.config import settings
import logging
from time import perf_counter

from core.metrics import metrics_registry
from core.perf_logging import perf_logger

logger = logging.getLogger(__name__)

# Оптимизированные настройки пула соединений (настраиваются через env: DATABASE_POOL_SIZE, DATABASE_MAX_OVERFLOW)
engine = create_engine(
    settings.database_url,
    poolclass=QueuePool,
    pool_size=getattr(settings, "database_pool_size", 10),
    max_overflow=getattr(settings, "database_max_overflow", 5),
    pool_pre_ping=True,  # Проверка соединений перед использованием
    pool_recycle=3600,  # Пересоздание соединений каждый час
    echo=False,  # Отключить SQL логирование в продакшене
    connect_args={
        "connect_timeout": 10,
        "application_name": "granivpn_backend"
    }
)

# Создаем фабрику сессий
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# Базовый класс для моделей
Base = declarative_base()

# Функция для получения сессии БД
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

# События пула: при LOG LEVEL=DEBUG видно churn коннектов (диагностика «пул забит / pre_ping»).
@event.listens_for(engine, "checkout")
def _pool_checkout(dbapi_connection, connection_record, connection_proxy):
    perf_logger.debug("[perf] db_checkout")


@event.listens_for(engine, "checkin")
def _pool_checkin(dbapi_connection, connection_record):
    perf_logger.debug("[perf] db_checkin")


# Логирование событий пула (только для отладки)
@event.listens_for(engine, "connect")
def set_sqlite_pragma(dbapi_conn, connection_record):
    """Оптимизация для PostgreSQL"""
    if 'postgresql' in settings.database_url:
        with dbapi_conn.cursor() as cursor:
            # Увеличиваем work_mem для лучшей производительности
            cursor.execute("SET work_mem = '16MB'")
            # shared_buffers нельзя изменить без перезапуска PostgreSQL, убираем


@event.listens_for(engine, "before_cursor_execute")
def before_cursor_execute(conn, cursor, statement, parameters, context, executemany):
    if not settings.metrics_enabled:
        return
    conn.info.setdefault("query_start_time", []).append(perf_counter())


@event.listens_for(engine, "after_cursor_execute")
def after_cursor_execute(conn, cursor, statement, parameters, context, executemany):
    if not settings.metrics_enabled:
        return
    start_times = conn.info.get("query_start_time", [])
    if not start_times:
        return
    start_time = start_times.pop()
    duration_ms = (perf_counter() - start_time) * 1000
    is_slow = duration_ms >= settings.slow_query_ms
    metrics_registry.record_db_query(duration_ms, is_slow)

    if is_slow:
        trimmed = statement.replace("\n", " ").strip()
        logger.warning("Slow query %.1fms: %s", duration_ms, trimmed[:300])