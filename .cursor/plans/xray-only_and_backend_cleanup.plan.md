---
name: Xray-only and backend cleanup
overview: "Упрощение системы: оставить только библиотеку Xray, экраны и админку; убрать лишнюю логику на бекенде и в мобилке (все протоколы кроме Xray). Затем заново реализовать логику подключения и само подключение с учётом прошлых ошибок."
todos: []
isProject: false
---

# План: только Xray, экраны, админка + новая логика подключений

## Статус выполнения (актуализировано)

### Выполнено
- **Бекенд:** ConnectionOrchestrator, ConnectionMonitor удалены; VPNOperationsService упрощён до Xray-only; api/vpn.py connect/disconnect/status сохранены и работают; WireGuard health check удалён; DeviceManager без WireGuardManager; boring_https_gateway.py удалён; boring_https скрипты в archive.
- **Мобилка (Flutter):** VpnProtocol — только xrayVless, xrayVmess, xrayReality; graniwg/openvpn_cloak протоколы удалены; UI (payment, profile, subscription_activated) — только Xray; тесты vpn_service_test.dart обновлены.
- **Android:** VpnService.kt — только XrayAdapter, WireGuard/BoringHttps удалены; зависимость :awg-tunnel (amneziawg) удалена; WireGuardStatsExtractor удалён.

### Выполнено (Фаза 3)
- Рефакторинг vpn_service.dart: логика подключения Xray вынесена в `XrayConnectionHandler` (`lib/services/xray_connection_handler.dart`): fetch config, cache (StorageXrayConfigCache), apply to NativeVpnService. VpnService делегирует getCachedConfig/fetchConfig/applyConfig обработчику.

### Остаётся
- Поля wireguard* в Server/vpn_service — для совместимости с API, опционально упростить.
- WireGuard-скрипты на бекенде — для администрирования серверов, оставлены.

---

## Текущее состояние (исходное описание)

- **Мобильное приложение (Flutter):** только Xray протоколы; [VpnService](mobile-app/lib/services/vpn_service.dart) (~3500 строк), нативная связка Xray + tun2socks + отдельный процесс `:xray`. Экраны: home, auth, payment, profile, connecting, connected и др.
- **Бекенд (FastAPI):** [api/vpn.py](backend/api/vpn.py) (connect/disconnect/status/servers/devices), [api/xray.py](backend/api/xray.py) (create-client, config), [VPNOperationsService](backend/application/services/vpn_operations_service.py), [DeviceManager](backend/application/services/device_manager.py), XrayManager, репозитории. Админ-роуты: [api/admin.py](backend/api/admin.py), admin_auth, admin_protocols и др.
- **Админ-панель (React/TS):** дашборд, пользователи, серверы, устройства, подписки, платежи, протоколы, логи — без изменений по объёму.

---

## Фаза 1: Что оставляем

| Компонент   | Оставляем                                                                                                                                                                                                                                                                                                                                                |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Мобилка** | Библиотека Xray: [lib/protocols/xray/](mobile-app/lib/protocols/xray/), [xray_config](mobile-app/lib/protocols/xray/models/xray_config.dart), нативный слой Android (XrayNativeWrapper, XrayConfig.kt, tun2socks, XrayProcessService). Все экраны (UI и навигация). Минимальный контракт для «подключения» (заглушка или один вызов «применить конфиг»). |
| **Бекенд**  | Админ-API (admin, admin_auth, admin_*, серверы/пользователи/устройства для админки). Выдача конфига Xray для клиента: по сути [api/xray.py](backend/api/xray.py) (create-client, config) или упрощённый аналог. Auth, app_config, bootstrap — по необходимости для мобилки и админки.                                                                    |
| **Админка** | Полностью как есть (страницы и сервисы).                                                                                                                                                                                                                                                                                                                 |

---

## Фаза 2: Что сносим/упрощаем

### 2.1 Бекенд (основной объём работ)

- **Убрать или сильно упростить:**
  - Сложную оркестрацию подключений: [ConnectionOrchestrator](backend/application/services/connection_orchestrator.py), [ConnectionMonitor](backend/application/services/connection_monitor.py) — убрать или заменить одним простым «состояние устройства» (подключён/нет), без мониторинга сессий и автоматических действий.
  - Многопротокольную логику в [VPNOperationsService](backend/application/services/vpn_operations_service.py): ветки WireGuard/Graniwg, BoringHttps; оставить только путь «устройство + сервер + протокол xray» → создание/получение конфига Xray (через существующий [XrayManager](backend/infrastructure/external/xray_manager.py) или упрощённый слой).
  - Эндпоинты [api/vpn.py](backend/api/vpn.py): connect/disconnect/status — либо удалить, либо заменить на минимальный набор: например «зарегистрировать устройство», «получить конфиг для подключения» (без сложной логики connect/disconnect в бекенде). Логику «подключён/отключён» хранить минимально (например, одна запись на устройство или только client_id в Xray).
- **Оставить в упрощённом виде:**
  - Регистрация/привязка устройства к пользователю (без сложной валидации сессий).
  - Список серверов и выбор сервера для выдачи конфига.
  - [api/xray.py](backend/api/xray.py): create-client, config, delete client — как основа для «выдачи конфига»; при необходимости упростить контракт (один метод «получить конфиг» по user + server + device).
- **Удалить/не использовать:**
  - BoringHttps gateway, WireGuard-специфичные скрипты/таски на бекенде (если не нужны админке).
  - Лишние скрипты в [backend/scripts/](backend/scripts/) по другим протоколам (оставить только то, что нужно для Xray и админки).

### 2.2 Мобильное приложение

- **Убрать:**
  - Протоколы не-Xray: [Graniwg](mobile-app/lib/protocols/graniwg/graniwg_protocol.dart), [OpenVPN Cloak](mobile-app/lib/protocols/openvpn_cloak/openvpn_cloak_protocol.dart), BoringHttps из [vpn_protocol.dart](mobile-app/lib/models/vpn_protocol.dart) и из VpnService. В [vpn_protocol_handler](mobile-app/lib/core/vpn_protocol_handler/vpn_protocol_handler.dart) оставить только реализацию для Xray (или один класс, без абстракции под несколько протоколов).
  - Нативный WireGuard/Amnezia в Android (если есть отдельные вызовы/библиотеки) — отключить или удалить из пути подключения.
- **Не переписывать целиком:** [VpnService](mobile-app/lib/services/vpn_service.dart) пока не заменять полностью; оставить только ветку Xray (убрать ветки по другим протоколам и неиспользуемые поля), чтобы приложение продолжало собираться и экраны работали. Полную замену логики подключения — в Фазе 3.

---

## Фаза 3: Новая логика подключения и само подключение

Учитывая прошлые ошибки (петля маршрутизации, DNS через proxy, краш при отключении, смешение ответственности):

### 3.1 Принципы

- Один протокол — Xray (VLESS/Reality или один выбранный вариант).
- Прямая цепочка: **экран «Подключиться» → получение конфига с бекенда → передача в нативный Xray → отображение статуса.** Без сложной state machine на бекенде (оркестратор/монитор не восстанавливать).
- Бекенд не хранит «реальное» состояние подключения устройства; только: устройство зарегистрировано, выдан client_id (или конфиг) для Xray. Опционально: флаг «последний запрос конфига» как грубый индикатор «использовалось недавно».
- На мобилке: тонкий слой «ConnectionService» или упрощённый VpnService: запрос конфига (один endpoint), вызов существующего нативного Xray (текущая библиотека + tun2socks), обновление UI. Вся сложность — в нативном коде (routing, DNS, корректное отключение уже правили ранее).

### 3.2 Бекенд

- Один (или два) чётких endpoint'а:
  - Регистрация/привязка устройства (если ещё нет).
  - «Получить конфиг для подключения»: вход — user (из токена), server_id, device_id; выход — готовая строка конфига Xray (или JSON для нативного слоя). Внутри: создание/получение клиента Xray на выбранном сервере, возврат конфига.
- При отключении на клиенте: опционально вызывать удаление/деактивацию клиента на сервере (один вызов), без сложной синхронизации состояний.

### 3.3 Мобилка

- Экраны остаются; точка входа «Подключиться» вызывает новую упрощённую логику:
  1. Проверка разрешения VPN.
  2. Выбор сервера (из списка с бекенда).
  3. Запрос конфига (новый/упрощённый API).
  4. Применение конфига через существующий Xray-слой (без добавления новых протоколов).
  5. Отображение «Подключено» / ошибки.
- Постепенно вынести дублирующую логику из VpnService в отдельный модуль «подключение Xray» (use case или сервис), чтобы VpnService не разрастался.

### 3.4 Учёт прошлых ошибок

- Маршрутизация: правила direct для адреса VPN-сервера и DNS уже добавлены в [xray_config](mobile-app/lib/protocols/xray/models/xray_config.dart) и [XrayConfig.kt](mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/XrayConfig.kt) — сохранить.
- Отключение: задержка после stop tun2socks и обработка DeadObjectException в [stopXrayFull](backend/...) уже в мобильном коде — сохранить; на бекенде не дублировать состояние «подключён».
- Тесты: после упрощения бекенда — обновить/добавить тесты только для нового минимального API (получение конфига, регистрация устройства).

---

## Порядок выполнения

1. **Бекенд:** удалить ConnectionOrchestrator, ConnectionMonitor; упростить VPNOperationsService до «Xray + устройство + сервер → конфиг»; заменить или убрать connect/disconnect/status в api/vpn.py на минимальный набор (или заглушки), сохранить api/xray.py и админ-роуты.
2. **Мобилка:** убрать протоколы не-Xray из кода и из UI (enum, обработчики); отключить путь WireGuard/Amnezia в нативном слое; в VpnService оставить только ветку Xray.
3. **Новый контракт:** описать и реализовать на бекенде endpoint(ы) «получить конфиг»; на мобилке — вызов этого API и передача конфига в Xray.
4. **Интеграция:** подключить экран «Подключиться» к новой логике; проверка полного цикла: выбор сервера → конфиг → подключение → отключение.
5. **Чистка:** удалить неиспользуемые скрипты и код; обновить тесты.

---

## Результат

- Работает только Xray; экраны и админка сохранены.
- Бекенд без тяжёлой оркестрации и мониторинга подключений; только выдача конфига и админ-функции.
- Логика подключения и само подключение пересобраны по простой схеме с учётом исправленных ошибок (routing, DNS, отключение).
