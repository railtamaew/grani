# Повторные запросы и таймауты

## ApiClient ([lib/core/api/api_client.dart](lib/core/api/api_client.dart))

- **Retry:** при определённых ошибках вызывается `_retryRequest` (один повтор, пауза 500 мс).
- Повтор выполняется при: таймаут соединения/приёма, ответы 408, 500, 503, 502.
- connectTimeout: 10 с, receiveTimeout: 15 с (уменьшено для быстрого fail при VPN/сетевых проблемах).

## AuthService ([lib/services/auth_service.dart](lib/services/auth_service.dart))

- **Refresh token:** при 401 (кроме запроса refresh-token) выполняется обновление токена и повтор запроса (один раз, флаг `auth_retry`).
- **Retry при запросах:** задержка и число попыток настраиваются (например, `retryDelay`, `retries`) для повторяемых ошибок (таймауты, сетевые ошибки).

## AppConfig ([lib/config/app_config.dart](lib/config/app_config.dart))

| Константа | Значение | Назначение |
|-----------|----------|------------|
| connectionTimeout | 30 с | Таймаут HTTP-запросов (подключение/ожидание ответа) |
| disconnectApiTimeout | 8 с | Таймаут запроса отключения через API |
| createClientTimeoutFirst | 25 с | Таймаут первого create-client (Xray), при синхронном apply до 25–30 с |
| createClientTimeoutRetry | 18 с | Таймаут повторного create-client (Xray fallback) |
| xrayGetConfigTimeout | 8 с | Таймаут GET /vpn/xray/config |

## XrayConnectionHandler — `POST /vpn/session/prepare`

- Dio: `NetworkTimeouts.xraySessionPrepareFirst/Retry` — connect **8 с**, send **15 с**, receive **22 с**.
- Дополнительно wall-clock `Timer` **22 с** на попытку (`lib/services/xray_connection_handler.dart`); перед второй попыткой пауза **1,5 с** (серверный lock после отмены первой).

## VpnService connect()

- До 3 попыток подключения с паузой 1 с при таймаутах (connection/receive) и ответах 408, 500, 503, 502 (`_shouldRetry`).
- Ошибки авторизации и VPN permission не повторяются.

## Split tunnel для API (XrayConfig)

При включённом VPN трафик к api.granilink.com идёт **через proxy** (туннель), чтобы обходить блокировки в мобильных сетях. См. `XrayConfig.kt` и `xray_config.dart` — правила routing.

Рекомендация: при доработках не увеличивать число ретраев и таймауты без необходимости, чтобы при недоступности сервера UI не блокировался надолго.
