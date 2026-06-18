"""
Константы приложения.
Централизованное хранение всех констант для упрощения поддержки и изменения.
"""

# ============================================================================
# ВРЕМЕННЫЕ КОНСТАНТЫ
# ============================================================================

# JWT токены
ACCESS_TOKEN_EXPIRE_MINUTES = 60  # 1 час (безопаснее, чем 30 дней)
REFRESH_TOKEN_EXPIRE_DAYS = 90  # 90 дней для refresh token

# Email коды
EMAIL_CODE_TTL_MINUTES = 10  # Время жизни кода подтверждения (минуты)
MAX_VERIFICATION_ATTEMPTS = 5  # Максимальное количество попыток верификации кода

# Admin Auth Rate Limiting
ADMIN_MAX_LOGIN_ATTEMPTS = 10  # Максимальное количество попыток входа
ADMIN_LOCKOUT_DURATION_MINUTES = 15  # Длительность блокировки в минутах

# Auth Rate Limiting (для обычных пользователей)
AUTH_SEND_CODE_RATE_LIMIT_IP = 5  # Максимальное количество запросов отправки кода с одного IP в минуту
AUTH_SEND_CODE_RATE_LIMIT_EMAIL = 3  # Максимальное количество запросов отправки кода на один email в минуту
AUTH_VERIFY_CODE_RATE_LIMIT_IP = 10  # Максимальное количество попыток проверки кода с одного IP в минуту
AUTH_VERIFY_CODE_RATE_LIMIT_EMAIL = 5  # Максимальное количество попыток проверки кода на один email в минуту
AUTH_RATE_LIMIT_PERIOD_SECONDS = 60  # Период для rate limiting (секунды)

# ============================================================================
# СЕТЕВЫЕ КОНСТАНТЫ
# ============================================================================

# WireGuard
WIREGUARD_DEFAULT_PORT = 51820
WIREGUARD_DEFAULT_INTERFACE = "wg0"
WIREGUARD_DEFAULT_CONFIG_PATH = "/etc/wireguard/wg0.conf"

# Xray
# 443 часто занят nginx (API reverse proxy на нодах вроде HU-BUD-01) — REALITY по умолчанию на 2053.
# Узлы без API на 443 могут задать servers.xray_port = 443 для REALITY.
XRAY_DEFAULT_PORT = 443  # Fallback для legacy / не-Reality
XRAY_REALITY_DEFAULT_PORT = 2053  # REALITY (альтернатива 443; 500 — IKE, не используем)
XRAY_VLESS_DEFAULT_PORT = 4443  # VLESS без REALITY (отдельно от 443)
XRAY_VMESS_DEFAULT_PORT = 8443  # VMESS (отдельный порт, чтобы не конфликтовать)
# Экспериментальные анти-DPI профили (терминируются на 443 через nginx).
XRAY_VLESS_WS_TLS_DEFAULT_PORT = 443
XRAY_VLESS_GRPC_TLS_DEFAULT_PORT = 443
XRAY_DEFAULT_CONFIG_PATH = "/usr/local/etc/xray/config.json"
XRAY_DEFAULT_BINARY_PATH = "/usr/local/bin/xray"
XRAY_API_PORT = 10085  # Порт для Xray Stats API

# OpenVPN
OPENVPN_DEFAULT_PORT = 1194

# ============================================================================
# ЛИМИТЫ И ПОРОГИ
# ============================================================================

# Серверы
DEFAULT_MAX_USERS_PER_SERVER = 1000  # Максимальное количество пользователей на сервере по умолчанию
DEFAULT_MAX_LOAD_PERCENTAGE = 80.0  # Максимальная нагрузка сервера (%)

# Устройства
MAX_DEVICES_PER_USER = 5  # Максимальное количество устройств на пользователя (для тестирования отключено)

# Подключения
CONNECTION_TIMEOUT_SECONDS = 30  # Таймаут подключения (секунды)
DEFAULT_PING_THRESHOLD_MS = 100  # Порог пинга для определения качества сервера

# ============================================================================
# ВЕСА ДЛЯ РАСЧЕТА НАГРУЗКИ СЕРВЕРА
# ============================================================================

# Формула нагрузки: load = (
#     (active_users / max_users) * LOAD_WEIGHT_USERS +
#     (bandwidth_used / bandwidth_limit) * LOAD_WEIGHT_BANDWIDTH +
#     (cpu_usage / 100) * LOAD_WEIGHT_CPU +
#     (ping_ms / 100) * LOAD_WEIGHT_PING
# ) * 100

LOAD_WEIGHT_USERS = 0.4  # Вес активных пользователей (40%)
LOAD_WEIGHT_BANDWIDTH = 0.3  # Вес пропускной способности (30%)
LOAD_WEIGHT_CPU = 0.2  # Вес CPU (20%)
LOAD_WEIGHT_PING = 0.1  # Вес пинга (10%)

# ============================================================================
# ПРОТОКОЛЫ VPN
# ============================================================================

# Поддерживаемые протоколы
PROTOCOL_WIREGUARD = "wireguard"
PROTOCOL_GRANIWG = "graniwg"
PROTOCOL_XRAY_VLESS = "xray_vless"
PROTOCOL_XRAY_VMESS = "xray_vmess"
PROTOCOL_XRAY_REALITY = "xray_reality"
PROTOCOL_XRAY_VLESS_WS_TLS = "xray_vless_ws_tls"
PROTOCOL_XRAY_VLESS_GRPC_TLS = "xray_vless_grpc_tls"
PROTOCOL_OPENVPN_CLOAK = "openvpn_cloak"

# Список всех поддерживаемых протоколов
SUPPORTED_PROTOCOLS = [
    PROTOCOL_WIREGUARD,
    PROTOCOL_GRANIWG,
    PROTOCOL_XRAY_VLESS,
    PROTOCOL_XRAY_VMESS,
    PROTOCOL_XRAY_REALITY,
    PROTOCOL_XRAY_VLESS_WS_TLS,
    PROTOCOL_XRAY_VLESS_GRPC_TLS,
    PROTOCOL_OPENVPN_CLOAK,
]

# Xray протоколы (без префикса xray_)
XRAY_PROTOCOLS = [
    "vless",
    "vmess",
    "reality",
    "vless_ws_tls",
    "vless_grpc_tls",
]

# ============================================================================
# ПУТИ К ФАЙЛАМ
# ============================================================================

# Конфигурационные файлы
WIREGUARD_CONFIG_PATH = "/etc/wireguard/wg0.conf"
XRAY_CONFIG_PATH = "/usr/local/etc/xray/config.json"

# Бинарные файлы
XRAY_BINARY_PATH = "/usr/local/bin/xray"

# ============================================================================
# HTTP КОНСТАНТЫ
# ============================================================================

# Статус коды (для удобства)
HTTP_OK = 200
HTTP_BAD_REQUEST = 400
HTTP_UNAUTHORIZED = 401
HTTP_FORBIDDEN = 403
HTTP_NOT_FOUND = 404
HTTP_CONFLICT = 409
HTTP_UNPROCESSABLE_ENTITY = 422
HTTP_INTERNAL_SERVER_ERROR = 500

# ============================================================================
# СТАТУСЫ И СОСТОЯНИЯ
# ============================================================================

# Статусы серверов
SERVER_STATUS_HEALTHY = "healthy"
SERVER_STATUS_WARNING = "warning"
SERVER_STATUS_CRITICAL = "critical"
SERVER_STATUS_OFFLINE = "offline"

# Статусы подключений
CONNECTION_STATUS_CONNECTED = "connected"
CONNECTION_STATUS_DISCONNECTED = "disconnected"
CONNECTION_STATUS_CONNECTING = "connecting"
CONNECTION_STATUS_ERROR = "error"

# ============================================================================
# СООБЩЕНИЯ ОБ ОШИБКАХ
# ============================================================================

# Общие сообщения
ERROR_DEVICE_NOT_FOUND = "Устройство не найдено"
ERROR_SERVER_NOT_FOUND = "Сервер не найден или неактивен"
ERROR_PROTOCOL_NOT_SUPPORTED = "Сервер не поддерживает протокол"
ERROR_UNAUTHORIZED = "Не авторизован"
ERROR_VALIDATION_FAILED = "Ошибка валидации данных"

# ============================================================================
# РАЗМЕРЫ И ЛИМИТЫ ДАННЫХ
# ============================================================================

# Размеры запросов
MAX_REQUEST_SIZE_MB = 10  # Максимальный размер запроса (MB)
MAX_FILE_SIZE_MB = 5  # Максимальный размер файла (MB)

# Пагинация
DEFAULT_PAGE_SIZE = 20  # Размер страницы по умолчанию
MAX_PAGE_SIZE = 100  # Максимальный размер страницы
DEFAULT_PAGE = 1  # Номер страницы по умолчанию
