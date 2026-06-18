"""
Конфигурация pytest для тестов.
"""
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

# Импортируем все модели в правильном порядке для инициализации relationships
import domain.models.subscription as models_subscription  # Первым, так как на него ссылаются другие модели
import models.subscription  # Обратная совместимость
import models.payment
import models.auth_code
import models.protocol_stats
import models.protocol
import models.telemetry
import models.audit_log
import models.system_setting
import models.admin_login_log
import models.observability
from models.subscription import Subscription, Plan
from models.payment import Payment
from models.auth_code import AuthCode
from models.protocol_stats import ProtocolStats
from models.protocol import Protocol
from models.telemetry import TelemetryEvent
from models.audit_log import AuditLog
from models.system_setting import SystemSetting
from models.admin_login_log import AdminLoginLog
from models.observability import ObservabilityEvent, ObservabilityIncident, EventDictionary
from models.user import User, Device
from models.server import Server, ConnectionLog
from models.client_log import ClientLog
from models import UserVpnConnection
import models.user
import models.server
import models.client_log

from core.database import Base


@pytest.fixture(scope="function")
def db_session():
    """
    Создает временную БД в памяти для каждого теста.
    """
    # Создаем БД в памяти для тестов
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    
    # Создаем все таблицы
    Base.metadata.create_all(bind=engine)
    
    # Создаем сессию
    TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    session = TestingSessionLocal()
    
    try:
        yield session
    finally:
        session.close()
        Base.metadata.drop_all(bind=engine)


@pytest.fixture
def test_user(db_session):
    """
    Создает тестового пользователя.
    """
    from services.auth_service import AuthService
    
    auth_service = AuthService(db_session)
    user = auth_service.create_user(
        email="test@example.com",
        password="TestPassword123"
    )
    return user


@pytest.fixture
def auth_service(db_session):
    """
    Создает экземпляр AuthService для тестов.
    """
    from services.auth_service import AuthService
    return AuthService(db_session)


@pytest.fixture(autouse=True)
def cache_backend():
    """
    Use in-memory cache for all tests so they do not require Redis.
    Resets cache backend after each test.
    """
    from core.cache_backend import InMemoryCacheBackend
    from core.cache import set_cache_backend
    backend = InMemoryCacheBackend()
    set_cache_backend(backend)
    try:
        yield backend
    finally:
        set_cache_backend(None)


@pytest.fixture
def redis_cache_backend(request):
    """
    Use Redis cache backend. Skip test if Redis is unavailable.
    Mark test with @pytest.mark.redis to use.
    """
    import pytest
    from core.cache_backend import RedisCacheBackend
    from core.cache import set_cache_backend
    from core.config import settings
    try:
        backend = RedisCacheBackend(settings.redis_url)
    except Exception as e:
        pytest.skip("Redis unavailable: %s" % e)
    set_cache_backend(backend)
    try:
        yield backend
    finally:
        set_cache_backend(None)
