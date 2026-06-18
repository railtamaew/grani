from pydantic_settings import BaseSettings
from typing import Optional, List, Dict, Any
from pydantic import field_validator, model_validator, ConfigDict
import json
import os

# Безопасная загрузка переменных окружения
# Приоритет: переменные окружения > безопасные файлы > .env файлы
def _load_env_file():
    """Загружает переменные из .env файла в os.environ (только если не установлены)"""
    # Сначала пробуем безопасные пути (для production)
    safe_paths = [
        '/etc/grani/secrets.env',  # Production secrets
        '/run/secrets/grani.env',  # Docker secrets
    ]
    
    for safe_path in safe_paths:
        if os.path.exists(safe_path):
            try:
                with open(safe_path, 'r', encoding='utf-8') as f:
                    for line in f:
                        line = line.strip()
                        if line and not line.startswith('#') and '=' in line:
                            key, value = line.split('=', 1)
                            key = key.strip()
                            value = value.strip().strip('"').strip("'")
                            # Устанавливаем только если еще не установлено
                            if key not in os.environ:
                                os.environ[key] = value
                # Если нашли безопасный файл, не загружаем .env
                return
            except (IOError, PermissionError) as e:
                import logging
                logger = logging.getLogger(__name__)
                logger.warning(f"Could not load secrets from {safe_path}: {e}")
    
    # Fallback: загружаем .env только для development
    env_file = os.path.join(os.path.dirname(__file__), '..', '.env')
    env = os.getenv("ENV", os.getenv("APP_ENV", "development")).lower()
    
    # В production не загружаем .env файлы из проекта
    if env == "production" and env_file.startswith(os.path.dirname(__file__)):
        import logging
        logger = logging.getLogger(__name__)
        logger.warning("Production mode: skipping .env file from project directory. Use environment variables or /etc/grani/secrets.env")
        return
    
    if os.path.exists(env_file):
        with open(env_file, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    key = key.strip()
                    value = value.strip().strip('"').strip("'")
                    # Устанавливаем только если еще не установлено
                    if key not in os.environ:
                        os.environ[key] = value

# Загружаем .env перед созданием Settings
_load_env_file()


def _safe_json_loads(value: str):
    """Парсит JSON, возвращает строку при ошибке."""
    if not isinstance(value, str):
        return value
    try:
        return json.loads(value)
    except Exception:
        return value

class Settings(BaseSettings):
    # Basic. В production обязательно: ENV=production
    env: str = "development"  # development|staging|production

    # Database. В production обязательно: DATABASE_URL (не использовать дефолтный пароль)
    database_url: str = "postgresql://granivpn_user:granivpn_password@localhost:5432/granivpn"
    # Pool per process. Итого: workers × (pool_size + max_overflow) < PostgreSQL max_connections.
    # Дефолт 5+5 снижает риск saturation при GUNICORN_WORKERS=8 (~80 коннектов).
    database_pool_size: int = 5
    database_max_overflow: int = 5

    # Redis
    redis_url: str = "redis://localhost:6379/0"

    # Cache backend: "memory" (default) or "redis". Use redis for multi-worker.
    cache_backend: str = "memory"

    # Rate limit store: "memory" (default) or "redis". Use redis for multi-worker.
    rate_limit_store: str = "memory"

    # Диагностика: DISABLE_RATE_LIMIT=1 — пропускает check_rate_limit (только для staging/нагрузочных тестов).
    disable_rate_limit: bool = False

    # Google Play review access. Disabled by default; enabled only when both values are set.
    play_review_email: Optional[str] = None
    play_review_code: Optional[str] = None

    # Отдельный файл для [perf] (grani-perf.log рядом с backend_log_file, если не задано иное).
    perf_log_file: Optional[str] = None

    # Логи приложения (RotatingFileHandler в main). В Docker: смонтируйте том и задайте путь, напр. /var/log/grani/grani-backend.log
    backend_log_file: str = "/tmp/grani-backend.log"
    backend_log_max_bytes: int = 10 * 1024 * 1024  # ротация после N байт (по умолчанию 10 MiB)
    backend_log_backup_count: int = 5  # число архивов .log.1, .log.2, ...
    backend_log_json: bool = False  # если True — файл в формате JSON lines (stdout остаётся текстом)
    # Каталог для POST /api/vpn/logs/test (тестовые логи клиентов). В Docker можно смонтировать на хост.
    client_test_logs_dir: str = "/opt/grani/logs/test_apps"

    # Metrics
    metrics_enabled: bool = True
    metrics_window_size: int = 2000
    slow_query_ms: int = 200
    metrics_prometheus_enabled: bool = False  # GET /metrics/prometheus (text/plain), закрыть в nginx по IP

    # Observability analytics backend: postgres|clickhouse|loki.
    # На текущем этапе clickhouse/loki включаются как отдельный контур чтения и
    # могут быть постепенно переведены с fallback на postgres.
    observability_events_backend: str = "postgres"

    # JWT. В production обязательно: SECRET_KEY через env (минимум 32 символа, без "change-this")
    secret_key: str = "grani-super-secret-key-2024-change-this-in-production"
    # Поддержка ротации SECRET_KEY: старый ключ для проверки существующих токенов
    # Установите SECRET_KEY_OLD для graceful migration без logout пользователей
    secret_key_old: Optional[str] = None
    algorithm: str = "HS256"
    access_token_expire_minutes: int = 60  # 1 час - из constants.py (безопаснее, чем 30 дней)
    refresh_token_expire_days: int = 90  # 90 дней для refresh token - из constants.py
    
    # Admin Auth Rate Limiting
    admin_max_login_attempts: int = 10  # Максимальное количество попыток входа - из constants.py
    admin_lockout_duration_minutes: int = 15  # Длительность блокировки в минутах - из constants.py

    # CORS
    # В production разрешены только production домены
    # В development/staging разрешены localhost и все домены
    allowed_origins: List[str] = [
        "http://localhost:3000",  # Для локальной разработки
        "http://localhost:8080",  # Для локальной разработки
        "http://localhost:3001",  # Для локальной разработки
        "https://admin.grani.ru",
        "https://admin.granilink.com",
        "https://admin.granilink.com",
        "https://app.grani.ru",
        "https://app.granilink.com",
        "https://granilink.com",
        "https://www.granilink.com",
        "https://app.granilink.com",
    ]
    
    @property
    def is_production(self) -> bool:
        """Проверка, что приложение работает в production окружении"""
        return self.env.lower() == "production"

    # WireGuard
    wireguard_config_path: str = "/etc/wireguard/wg0.conf"
    wireguard_interface: str = "wg0"
    wireguard_server_ip: str = "94.131.107.227"
    wireguard_port: int = 51820
    
    # Xray
    xray_config_path: str = "/etc/xray/config.json"
    xray_binary_path: str = "/usr/local/bin/xray"
    xray_api_port: int = 10085
    # Предпочтительный systemd unit для управления Xray на VPN нодах.
    # Можно задать "xray-v2", при этом менеджер автоматически fallback-нет на "xray".
    xray_systemd_unit: str = "xray-v2"
    # Отложенный retry применения Xray-конфига, когда на ноде есть активные сессии.
    xray_apply_retry_delay_sec: int = 60
    # Окно (сек), в котором connection_logs считаются "активной сессией" при отсутствии disconnected_at.
    xray_active_session_lookback_sec: int = 900
    # Минимальный интервал между apply, чтобы сгладить частые изменения конфига.
    xray_apply_min_interval_sec: int = 25
    # Edge enqueue debounce: не плодить pending apply чаще этого окна.
    xray_edge_enqueue_debounce_sec: int = 45
    # Максимум времени (сек) для defer dispatch при активных сессиях.
    # После этого assignment всё равно отдается edge-агенту, чтобы избежать вечного pending.
    xray_edge_dispatch_defer_max_sec: int = 150
    # Поэтапное включение: если True, /session/prepare сохраняет staged-конфиг без немедленного apply.
    xray_prepare_stage_only: bool = False
    # Разрешение apply из prepare-пайплайна (можно отключить аварийно).
    xray_prepare_apply_enabled: bool = True
    # Аварийный режим: применять Xray-конфиг синхронно в hot path (без edge/celery async).
    # По умолчанию выключен, чтобы connect/create-client не блокировались на SSH/restart.
    xray_force_sync_apply: bool = False
    # Если True, /vpn/session/prepare не мутирует конфиг и не создает клиентов.
    session_prepare_read_only: bool = True
    # Таймаут (сек) ожидания подтверждения apply на connect/create-client.
    # Увеличен до worst-case окна edge dispatch/apply, чтобы исключить ложные 503.
    xray_connect_apply_timeout_sec: int = 90
    # Если True, create-client ждет подтверждение apply (старый блокирующий режим).
    # По умолчанию False: create-client возвращает queued/applying без long blocking.
    xray_connect_require_apply_confirmed: bool = False
    # v2 connect: по умолчанию уводим xray_vless из heavy-path на throughput profile.
    xray_v2_force_throughput_profile_for_vless: bool = True
    xray_v2_default_traffic_profile: str = "throughput"
    # Авто-блок apply при деградации пайплайна.
    xray_apply_auto_block_enabled: bool = True
    # Окно и порог ошибок для авто-блока.
    xray_apply_autoblock_window_sec: int = 300
    xray_apply_autoblock_min_events: int = 5
    xray_apply_autoblock_error_ratio: float = 0.6
    # TTL блокировки apply.
    xray_apply_autoblock_ttl_sec: int = 180
    
    # Compatibility aliases
    @property
    def WIREGUARD_CONFIG_PATH(self) -> str:  # noqa: N802
        return self.wireguard_config_path
    
    @property
    def WIREGUARD_INTERFACE(self) -> str:  # noqa: N802
        return self.wireguard_interface
    
    @property
    def XRAY_CONFIG_PATH(self) -> str:  # noqa: N802
        return self.xray_config_path
    
    @property
    def XRAY_BINARY_PATH(self) -> str:  # noqa: N802
        return self.xray_binary_path
    
    @property
    def XRAY_API_PORT(self) -> int:  # noqa: N802
        return self.xray_api_port
    
    @property
    def ACCESS_TOKEN_EXPIRE_MINUTES(self) -> int:  # noqa: N802
        return self.access_token_expire_minutes
    
    @property
    def REFRESH_TOKEN_EXPIRE_DAYS(self) -> int:  # noqa: N802
        return self.refresh_token_expire_days
    
    @property
    def SECRET_KEY(self) -> str:  # noqa: N802
        return self.secret_key
    
    @property
    def ALGORITHM(self) -> str:  # noqa: N802
        return self.algorithm

    # Google Play Billing
    google_play_service_account: Optional[str] = None  # Path to service account JSON
    google_play_package_name: str = "com.granivpn.mobile"

    # Google OAuth
    google_oauth_client_ids: List[str] = []
    google_oauth_default_client_id: Optional[str] = None

    # Domain. В production: API_URL (например https://api.granilink.com)
    domain: str = "grani.ru"
    api_url: str = "http://localhost:8000"
    # Запасные URL API для bootstrap (сценарий 6). Через запятую, например: https://alt1.example/api,https://alt2.example/api
    api_base_url_fallbacks: str = ""

    # Boring HTTPS (сценарий 4): URL шлюза туннеля и опциональный SNI для прикрытия
    boring_https_gateway_url: str = ""  # например https://gate.example.com/vpn/tunnel или https://<api>/api/vpn/tunnel (встроенный gateway)
    boring_https_sni: Optional[str] = None  # например www.google.com; если пусто — хост из gateway_url
    # Путь к Unix-сокету TUN-хелпера для маршрутизации пакетов в интернет. Если задан — gateway пересылает фреймы туда.
    boring_https_tun_socket: str = ""  # например /run/grani/boring_https_tun.sock

    # Test users (bypass проверки для тестирования)
    test_user_emails: List[str] = ["vpn-test-bypass@grani.local"]

    # AmneziaWG параметры (JSON строка или dict). Пример:
    # {"Jc": 4, "Jmin": 5, "Jmax": 60, "S1": 15, "S2": 35, "H1": 31, "H2": 37, "H3": 41, "H4": 43}
    awg_params: Dict[str, Any] = {}

    # Email SMTP Settings
    smtp_host: str = "smtp.gmail.com"
    smtp_port: int = 587
    smtp_username: Optional[str] = None  # Email для отправки
    smtp_password: Optional[str] = None  # Пароль приложения или пароль
    smtp_from_email: str = "noreply@grani.ru"
    smtp_from_name: str = "GRANI"
    smtp_use_tls: bool = True
    smtp_use_ssl: bool = False  # Для порта 465 (SSL)
    
    # AWS SES / Yandex Cloud Postbox Settings (альтернатива SMTP)
    # Для Yandex Cloud Postbox установите:
    #   - aws_region = "ru-central1"
    #   - aws_ses_endpoint = "https://postbox.cloud.yandex.net"
    #   - aws_ses_from_email = "support@granilink.com"
    #   - aws_ses_from_name = "GRANI Account"
    aws_region: str = "us-east-1"  # Для Yandex Postbox: "ru-central1"
    aws_access_key_id: Optional[str] = None
    aws_secret_access_key: Optional[str] = None
    aws_ses_from_email: str = "support@granilink.com"  # Закреплено для Yandex Postbox
    aws_ses_from_name: str = "GRANI Account"  # Закреплено для Yandex Postbox
    use_aws_ses: bool = False  # Переключение между SMTP и AWS SES / Yandex Cloud Postbox
    aws_ses_endpoint: Optional[str] = None  # Для Yandex Cloud Postbox: https://postbox.cloud.yandex.net
    
    # Email Logo Settings
    email_logo_url: Optional[str] = None  # URL белого логотипа для email шаблонов

    # Firebase Cloud Messaging (Push-уведомления)
    firebase_service_account_path: str = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "grani-479612-firebase-adminsdk-fbsvc-3538a0a203.json"
    )

    # Telegram support bot
    telegram_support_bot_token: Optional[str] = None
    telegram_support_chat_id: Optional[str] = None
    telegram_support_webhook_secret: Optional[str] = None
    telegram_support_privacy_url: str = "https://granilink.com/privacy"

    @property
    def allowed_google_client_ids(self) -> List[str]:
        if self.google_oauth_client_ids:
            return self.google_oauth_client_ids
        if self.google_oauth_default_client_id:
            return [self.google_oauth_default_client_id]
        # Fallback: часто на сервере задают ALLOWED_GOOGLE_CLIENT_IDS (через запятую)
        raw = os.environ.get("ALLOWED_GOOGLE_CLIENT_IDS", "").strip()
        if raw:
            ids = [x.strip() for x in raw.split(",") if x.strip()]
            if ids:
                return ids
        return []

    @field_validator("allowed_origins", mode="before")
    @classmethod
    def _parse_allowed_origins(cls, value):
        if value is None:
            return []
        if isinstance(value, list):
            return value
        if isinstance(value, str):
            # Парсим JSON если это JSON строка
            if value.strip().startswith('[') and value.strip().endswith(']'):
                try:
                    import json
                    parsed = json.loads(value)
                    if isinstance(parsed, list):
                        return parsed
                except:
                    pass
            # Иначе парсим через запятую
            items = [item.strip() for item in value.split(",") if item.strip()]
            return items
        return value
    
    @field_validator("allowed_origins", mode="after")
    @classmethod
    def _normalize_origins(cls, v: List[str]) -> List[str]:
        # Trim spaces and drop empties/duplicates
        cleaned = []
        seen = set()
        for o in v:
            if not o:
                continue
            o2 = o.strip()
            if not o2 or o2 in seen:
                continue
            cleaned.append(o2)
            seen.add(o2)
        return cleaned
    
    @field_validator("google_oauth_client_ids", mode="before")
    @classmethod
    def _parse_google_client_ids(cls, value):
        if value is None:
            return []
        if isinstance(value, list):
            return value
        if isinstance(value, str):
            items = [item.strip() for item in value.split(",") if item.strip()]
            return items
        return value

    @field_validator("test_user_emails", mode="before")
    @classmethod
    def _parse_test_user_emails(cls, value):
        if value is None:
            return []
        if isinstance(value, list):
            return value
        if isinstance(value, str):
            items = [item.strip() for item in value.split(",") if item.strip()]
            return items
        return value

    @field_validator("awg_params", mode="before")
    @classmethod
    def _parse_awg_params(cls, value):
        if value is None:
            return {}
        if isinstance(value, dict):
            return value
        if isinstance(value, str):
            try:
                import json
                parsed = json.loads(value)
                if isinstance(parsed, dict):
                    return parsed
            except Exception:
                pass
        return {}

    @field_validator("use_aws_ses", mode="before")
    @classmethod
    def _parse_use_aws_ses(cls, value):
        """Преобразует строку 'true'/'false' в boolean"""
        if isinstance(value, bool):
            return value
        if isinstance(value, str):
            return value.lower() in ('true', '1', 'yes', 'on')
        return False
    
    @field_validator("secret_key")
    @classmethod
    def _validate_secret_key(cls, v: str, info):
        env = os.getenv("ENV", os.getenv("APP_ENV", "development")).lower()
        if env == "production" and (not v or "change-this" in v or len(v) < 32):
            raise ValueError(
                "SECRET_KEY must be set for production (env SECRET_KEY) and be at least 32 characters. "
                "Generate: python -c 'import secrets; print(secrets.token_urlsafe(32))'"
            )
        return v

    @model_validator(mode="after")
    def _validate_production_config(self):
        """Блокирует запуск в production с дефолтными/небезопасными значениями."""
        if not self.is_production:
            return self
        # В production отключаем test users
        self.test_user_emails = []
        errs = []
        if "granivpn_password" in (self.database_url or ""):
            errs.append(
                "DATABASE_URL must be set in production (do not use default password). "
                "Set DATABASE_URL env var."
            )
        if (self.api_url or "").strip().startswith("http://localhost:8000"):
            errs.append(
                "API_URL must be set in production (not localhost). Set API_URL env var."
            )
        if errs:
            raise ValueError("Production config invalid: " + "; ".join(errs))
        # Google Play Billing: не блокируем старт API, но предупреждаем в логах (grep: GOOGLE_PLAY_PROD_CONFIG).
        import logging

        _log = logging.getLogger(__name__)
        sa = (self.google_play_service_account or "").strip()
        if not sa:
            _log.warning(
                "GOOGLE_PLAY_PROD_CONFIG: google_play_service_account / GOOGLE_PLAY_SERVICE_ACCOUNT "
                "not set — POST /api/payments/google-play/verify cannot call Publisher API."
            )
        else:
            import os as _os

            if not _os.path.isfile(sa):
                _log.warning(
                    "GOOGLE_PLAY_PROD_CONFIG: service account path is not a file: %s",
                    sa,
                )
        pkg = (self.google_play_package_name or "").strip()
        if pkg != "com.granivpn.mobile":
            _log.warning(
                "GOOGLE_PLAY_PROD_CONFIG: google_play_package_name=%s (expected com.granivpn.mobile for app id).",
                pkg,
            )
        return self

    @property
    def jwt_secret_keys(self) -> List[str]:
        """Возвращает список секретных ключей для проверки JWT (новый + старый для ротации)"""
        keys = [self.secret_key]
        if self.secret_key_old:
            keys.append(self.secret_key_old)
        return keys

    model_config = ConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",  # Игнорируем неизвестные поля из переменных окружения
        env_ignore_empty=True,  # Игнорируем пустые значения
        json_loads=_safe_json_loads,
    )

    @classmethod
    def _load_env_file(cls, env_file: str) -> dict:
        """Загружает переменные из .env файла"""
        import os
        env_vars = {}
        if os.path.exists(env_file):
            with open(env_file, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#') and '=' in line:
                        key, value = line.split('=', 1)
                        key = key.strip()
                        value = value.strip().strip('"').strip("'")
                        env_vars[key] = value
        return env_vars

settings = Settings()
