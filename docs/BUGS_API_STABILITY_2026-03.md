# Баги: нестабильность API и деградация UX

**Дата:** 2026-03-19  
**Контекст:** Технический аудит VPN-приложения. Единая корневая причина — нестабильность/деградация API.

---

## Сводная таблица

| ID      | Симптом                                 | Воспроизведение                                          | Связанные компоненты                                                                                                            |
| ------- | --------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| BUG-001 | Долгое подключение к VPN                | Connect → ожидание >15–20 с                              | [vpn_service.dart](../mobile-app/lib/services/vpn_service.dart), create-client (20–25 с receive)                               |
| BUG-002 | Частые переподключения/обрывы           | См. [vpn-diagnostics](../.cursor/rules/vpn-diagnostics.mdc) | Xray, сервер, сеть                                                                                                              |
| BUG-003 | Долгая авторизация (получение кода)     | send-code / verify-code                                  | [auth_service.dart](../mobile-app/lib/services/auth_service.dart), [auth.py](../backend/api/auth.py)                           |
| BUG-004 | Недоступен список устройств             | GET /vpn/devices                                         | [devices_screen.dart](../mobile-app/lib/screens/devices_screen.dart), [vpn_service.dart](../mobile-app/lib/services/vpn_service.dart) |
| BUG-005 | UI «вечно крутится» (loader без ответа) | Любой экран при таймауте/5xx                             | Loader без fallback на ошибку, отсутствие верхней границы ожидания                                                              |

---

## BUG-001: Долгое подключение к VPN

| Поле | Значение |
|------|----------|
| **Симптом** | Пользователь ждёт подключения >15–20 с |
| **Воспроизведение** | Нажать Connect → ожидание до 20–25 с |
| **Связанные компоненты** | `mobile-app/lib/services/vpn_service.dart`, endpoint `POST /api/vpn/xray/create-client` (receive timeout 20–25 с) |
| **Причина** | Синхронный apply на бэкенде (SSH/Celery), долгий create-client |
| **См. также** | [TECHNICAL_AUDIT_CONFLICTS_2026-03.md](TECHNICAL_AUDIT_CONFLICTS_2026-03.md) §3.2 |

---

## BUG-002: Частые переподключения / обрывы

| Поле | Значение |
|------|----------|
| **Симптом** | VPN обрывается, требуется повторное подключение |
| **Воспроизведение** | См. [vpn-diagnostics](../.cursor/rules/vpn-diagnostics.mdc) — полный анализ |
| **Связанные компоненты** | Xray на VPN-сервере, сеть, `i/o timeout`, `broken pipe` |
| **Причина** | Рестарты Xray, нестабильная сеть, короткие таймауты |
| **См. также** | `logs/server/vpn-server-check-2026-03-18.md` |

---

## BUG-003: Долгая авторизация (получение кода)

| Поле | Значение |
|------|----------|
| **Симптом** | Долгое ожидание кода на email, медленная проверка кода |
| **Воспроизведение** | `POST /auth/send-code`, `POST /auth/verify-code` при медленном API |
| **Связанные компоненты** | `mobile-app/lib/services/auth_service.dart`, `backend/api/auth.py` |
| **Причина** | Медленные запросы к PostgreSQL (auth_codes), DNS до 5 с, блокировки |
| **Таймауты** | authCritical: connect 5–8 с, send 5–10 с, receive 8–15 с |

---

## BUG-004: Недоступен список устройств

| Поле | Значение |
|------|----------|
| **Симптом** | Экран «Устройства» не загружается, loader крутится |
| **Воспроизведение** | `GET /api/vpn/devices` при таймауте/5xx |
| **Связанные компоненты** | `mobile-app/lib/screens/devices_screen.dart`, `mobile-app/lib/services/vpn_service.dart` |
| **Причина** | Таймаут 8 с на экране, при ошибке — только кнопка «Повторить», нет автоматического retry |
| **Backend** | Кеш 60 с (`cache:devices:{user_id}`), cold cache → PostgreSQL |

---

## BUG-005: UI «вечно крутится» (loader без ответа)

| Поле | Значение |
|------|----------|
| **Симптом** | Loader крутится без перехода в ошибку при таймауте/5xx |
| **Воспроизведение** | Любой экран при недоступности API (таймаут, 5xx) |
| **Связанные компоненты** | DevicesScreen, AuthCodeScreen, AuthEmailScreen, HomeScreen, TrialUnifiedScreen |
| **Причина** | Loader без верхней границы ожидания, отсутствие fallback на ошибку с понятным сообщением |

---

## Сводка

| ID | Приоритет | Категория |
|----|-----------|-----------|
| BUG-001 | P1 | Backend (create-client) |
| BUG-002 | P1 | Инфраструктура (Xray, сеть) |
| BUG-003 | P0 | API + клиент (auth) |
| BUG-004 | P0 | API + клиент (devices) |
| BUG-005 | P0 | Клиент (UX) |
