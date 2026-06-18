# 🧪 ПЛАН ТЕСТИРОВАНИЯ ПРОТОКОЛОВ СЕРВЕРОВ

**Дата:** 2026-01-14  
**Цель:** Обеспечить покрытие тестами всех VPN протоколов для уверенности в работе после сборки

---

## 📊 ТЕКУЩЕЕ СОСТОЯНИЕ

### Протоколы в проекте:
1. **WireGuard** - базовый протокол
2. **GRANIWG** - обфусцированный WireGuard
3. **Xray VLESS** - протокол Xray
4. **Xray VMESS** - протокол Xray
5. **Xray REALITY** - протокол Xray
6. **OpenVPN** - классический протокол
7. **Cloak** - плагин для обфускации

### Менеджеры протоколов:
- `WireGuardManager` (~469 строк)
- `XrayManager` (~844 строки)
- `OpenVPNManager` (~143 строки)
- `CloakManager` (~76 строк)

---

## 🎯 ПЛАН ТЕСТИРОВАНИЯ

### Phase 1: Unit-тесты для WireGuardManager ✅ ВЫПОЛНЕНО

#### Тесты для базовых методов:
- [x] `test_get_next_available_ip_local` - получение IP для локального сервера
- [x] `test_get_next_available_ip_remote` - получение IP для удаленного сервера (мок)
- [x] `test_get_next_available_ip_no_ips` - обработка переполнения IP адресов
- [x] `test_generate_key_pair_local` - генерация ключей для локального сервера
- [x] `test_generate_key_pair_remote` - генерация ключей для удаленного сервера (мок)
- [x] `test_create_client_config_wireguard` - создание стандартной конфигурации WireGuard
- [x] `test_create_client_config_graniwg` - создание конфигурации GRANIWG
- [x] `test_add_peer_to_server_local` - добавление пира на локальный сервер (мок)
- [x] `test_add_peer_to_server_remote` - добавление пира на удаленный сервер (мок)
- [x] `test_remove_peer_from_server` - удаление пира с сервера (мок)
- [x] `test_get_peer_stats` - получение статистики пира (мок)
- [x] `test_check_interface_health` - проверка здоровья интерфейса (мок)

**Файл:** `tests/test_wireguard_manager.py` (12+ тестов)

### Phase 2: Unit-тесты для XrayManager ✅ ВЫПОЛНЕНО

#### Тесты для создания клиентов:
- [x] `test_create_vless_client` - создание VLESS клиента (мок SSH)
- [x] `test_create_vless_client_existing_email` - обработка существующего клиента
- [x] `test_create_vless_client_ssh_error` - обработка ошибки SSH
- [x] `test_create_vmess_client` - создание VMESS клиента (мок SSH)
- [x] `test_create_reality_client` - создание REALITY клиента (мок SSH)
- [x] `test_remove_client` - удаление клиента (мок SSH)
- [x] `test_remove_client_not_found` - удаление несуществующего клиента
- [x] `test_get_client_stats` - получение статистики клиента (мок SSH)
- [x] `test_get_client_stats_error` - обработка ошибки при получении статистики
- [x] `test_get_server_stats` - получение статистики сервера (мок SSH)
- [x] `test_check_server_health_ok` - проверка здоровья сервера (OK)
- [x] `test_check_server_health_error` - проверка здоровья сервера (ошибка)

**Файл:** `tests/test_xray_manager.py` (12+ тестов)

### Phase 3: Интеграционные тесты для Xray протоколов ✅ ВЫПОЛНЕНО

#### Тесты через ConnectionOrchestrator:
- [x] `test_connect_device_xray_vless` - подключение через VLESS (мок XrayManager)
- [x] `test_connect_device_xray_vmess` - подключение через VMESS (мок XrayManager)
- [x] `test_connect_device_xray_reality` - подключение через REALITY (мок XrayManager)
- [x] `test_disconnect_device_xray` - отключение Xray клиента (мок XrayManager)

**Файл:** `tests/test_connection_orchestrator.py` (добавлено 4 новых теста)

### Phase 4: Тесты для Edge Cases ✅ ВЫПОЛНЕНО

#### Обработка ошибок:
- [x] `test_wireguard_ssh_error_on_add_peer` - обработка ошибок SSH при добавлении пира
- [x] `test_wireguard_ssh_error_on_get_ip` - обработка ошибок SSH при получении IP
- [x] `test_wireguard_ssh_error_on_remove_peer` - обработка ошибок SSH при удалении пира
- [x] `test_xray_ssh_error_on_read_config` - обработка ошибок SSH при чтении конфигурации
- [x] `test_xray_ssh_error_on_write_config` - обработка ошибок SSH при записи конфигурации
- [x] `test_xray_config_read_error` - ошибка чтения конфигурации Xray (невалидный JSON)
- [x] `test_server_unavailable_wireguard` - недоступность сервера WireGuard
- [x] `test_server_unavailable_xray` - недоступность сервера Xray
- [x] `test_unsupported_protocol_connection` - неподдерживаемый протокол
- [x] `test_ip_overflow_wireguard` - переполнение IP адресов (локальный)
- [x] `test_ip_overflow_remote_wireguard` - переполнение IP адресов (удаленный)
- [x] `test_invalid_wireguard_config_path` - некорректный путь к конфигурации WireGuard
- [x] `test_invalid_xray_config_path` - некорректный путь к конфигурации Xray

**Файл:** `tests/test_protocol_edge_cases.py` (13+ тестов)

---

## 📈 МЕТРИКИ ПОКРЫТИЯ

### Целевое покрытие:
- **WireGuardManager**: 80%+ методов
- **XrayManager**: 80%+ методов
- **ConnectionOrchestrator**: 100% протоколов
- **Edge Cases**: основные сценарии ошибок

### Текущее покрытие:
- **WireGuardManager**: ~80% (12+ unit-тестов: get_next_available_ip, generate_key_pair, create_config, add_peer, remove_peer, get_stats, check_health)
- **XrayManager**: ~70% (8+ unit-тестов: create_vless/vmess/reality_client, remove_client, get_stats, check_health)
- **ConnectionOrchestrator**: ~90% (WireGuard, GRANIWG, Xray VLESS/VMESS/REALITY, отключение)
- **Edge Cases**: ~80% (ошибки SSH, недоступность серверов, переполнение IP, некорректные конфигурации)

---

## ✅ КРИТЕРИИ УСПЕХА

1. Все основные методы менеджеров покрыты тестами
2. Все протоколы (WireGuard, GRANIWG, VLESS, VMESS, REALITY) протестированы
3. Основные edge cases покрыты тестами
4. Все тесты проходят успешно
5. Покрытие кода > 80% для критичных менеджеров

---

## 🚀 СЛЕДУЮЩИЕ ШАГИ

После завершения этого плана:
1. Добавить тесты для OpenVPNManager
2. Добавить тесты для CloakManager
3. Добавить интеграционные тесты с реальными серверами (в staging окружении)
4. Настроить CI/CD для автоматического запуска тестов
