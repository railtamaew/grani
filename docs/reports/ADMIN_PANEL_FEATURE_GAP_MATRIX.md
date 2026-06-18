# Матрица функций админ‑панели (Firebase‑уровень)

Цель: сопоставить текущую реализацию админ‑панели GRANI с уровнем возможностей консоли Firebase, зафиксировать разрывы и приоритеты.

## Легенда
- ✅ Готово
- 🟡 Частично
- ❌ Нет

## 1) Пользователи и устройства
| Функция | Статус | Где есть | Разрыв |
|---|---|---|---|
| Список пользователей с фильтрами | ✅ | `backend/api/admin.py` (`GET /api/admin/users`), `admin-panel/src/pages/UsersPage.tsx` | — |
| Карточка пользователя (детали) | ✅ | `GET /api/admin/users/{id}`, `admin-panel/src/pages/UserDetailPage.tsx` | — |
| Управление устройствами пользователя | ✅ | `GET /api/admin/users/{id}`, `POST /api/admin/users/{id}/devices/reset`, `DELETE /api/admin/devices/{device_id}` | Нет массовых действий |
| Блокировка/разблокировка пользователя | ✅ | `PUT /api/admin/users/{id}/block`, `PUT /api/admin/users/{id}/unblock` | — |
| История событий пользователя | 🟡 | `GET /api/admin/users/{id}/events` (телеметрия + коннекты), `UserDetailPage` (вкладка История) | Нужен удобный UI‑таймлайн и фильтры |
| Экспорт/массовые действия | ❌ | — | CSV/массовые операции |

## 2) Подписки, планы, триалы, платежи
| Функция | Статус | Где есть | Разрыв |
|---|---|---|---|
| Список подписок | ✅ | `GET /api/admin/subscriptions`, `admin-panel/src/pages/SubscriptionsPage.tsx` | Нет действий (pause/cancel/extend) |
| Ручное продление/создание подписки | ✅ | `POST /api/admin/users/{id}/subscription`, `UserDetailPage` | Нет массовых/авто‑сценариев |
| Управление trial | ✅ | `POST /api/admin/users/{id}/trial`, `UserDetailPage` | Нужна история trial |
| Планы/тарифы | ✅ | `GET /api/admin/plans` | Нет UI для CRUD планов |
| Платежи (список/детали) | ✅ | `GET /api/admin/payments`, `GET /api/admin/payments/{id}`, `admin-panel/src/pages/PaymentsPage.tsx` | Нет возвратов/чарджбеков |
| Статистика платежей | ✅ | `GET /api/admin/payments/stats` | Нужна визуализация |

## 3) Аутентификация и регистрация (Email/Google)
| Функция | Статус | Где есть | Разрыв |
|---|---|---|---|
| Email‑регистрация (код) | ✅ | `backend/api/auth.py` (`/send-code`, `/verify-code`) | — |
| Google OAuth | ✅ | `POST /api/auth/google/callback` | — |
| Отчет по провайдерам | 🟡 | `GET /api/admin/stats/auth-providers` | Нет UI |
| Просмотр кодов авторизации | ✅ | `GET /api/admin/auth-codes`, `admin-panel/src/pages/AuthCodesPage.tsx` | — |

## 4) Серверы, мониторинг, протоколы
| Функция | Статус | Где есть | Разрыв |
|---|---|---|---|
| Инвентарь серверов | ✅ | `GET /api/admin/servers`, `ServersPage` | — |
| Управление сервером (CRUD) | ✅ | `POST/PUT/DELETE /api/admin/servers` | Нет bulk‑операций |
| Статусы/нагрузка/активные сессии | ✅ | `/servers/{id}/stats`, `/servers/{id}/active-sessions` | Нужны алерты и SLA |
| Протоколы (список/статистика) | ✅ | `admin_protocols.py`, `ProtocolsPage` | Нет полного редактора схем |
| Рекомендации протоколов | ✅ | `/api/admin/protocols/recommendations` | Нет UI |
| Нагрузочные предупреждения | ✅ | `/api/admin/load/alerts` | Нет UI/алертов |

## 5) Инциденты, ошибки, логи
| Функция | Статус | Где есть | Разрыв |
|---|---|---|---|
| Список инцидентов + фильтры | ✅ | `admin_incidents.py`, `admin-panel/src/pages/IncidentsPage.tsx` | Нет экспортов |
| Карточка инцидента + таймлайн | ✅ | `GET /api/admin/incidents/{id}` | Нужны действия по исправлению |
| Логи клиента (device logs) | ✅ | `GET /api/admin/logs/clients`, `ClientLogsPage` | Нет связки с пользователем |
| Audit Log (действия админов) | ✅ | `GET /api/admin/audit-log`, `AuditLogPage` | Нет детализации old/new |

## 6) Админ‑RBAC и настройки
| Функция | Статус | Где есть | Разрыв |
|---|---|---|---|
| Роли и доступы (RBAC) | ✅ | `backend/core/rbac.py`, фильтрация меню в `Sidebar.tsx` | Нужен экран матрицы прав |
| Управление админами | ✅ | `GET/POST/PATCH /api/admin/settings/admins`, `SettingsPage` | Нет логов изменений ролей |
| Feature flags и min versions | ✅ | `GET/PUT /api/admin/settings`, `SettingsPage`, `AppConfigService` | Нужна история изменений |

## 7) UX уровня Firebase (что требуется добавить)
- Единый раздел Observability: метрики, алерты, инциденты, логи, экспорт.
- Расширенная аналитика: retention, конверсии, LTV/ARPU, источники регистраций.
- Глобальный поиск по пользователям/устройствам/платежам.
- Массовые операции: блок, рассылка, смена тарифа, экспорт.
- Полный контроль протоколов и конфигураций (schema editor).

## Итог: приоритет разрывов
1) Observability (логи, алерты, экспорты) — высокая ценность для поддержки.
2) Подписки/платежи (полный жизненный цикл, возвраты) — высокая бизнес‑ценность.
3) UX‑консистентность (таблицы, фильтры, статусы, пустые состояния) — снижение ошибок.
4) Admin‑RBAC и аудит (гранулярность и истории изменений) — безопасность.
