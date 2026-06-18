# Система оценки VPN-сервиса по логам

Документ описывает метрики, критерии и методику оценки работы GraniVPN на основе анализа логов (adb logcat, ConnectionLogger).

---

## 1. Источники логов

| Источник | Формат | Описание |
|----------|--------|----------|
| **adb logcat** | `yyyy-MM-dd HH:mm:ss.mmm PID TID LEVEL TAG: message` | Системные логи Android, включая VpnService, Tun2SocksProc, ConnectionLogger |
| **ConnectionLogger (API)** | JSON `event_type`, `protocol`, `stage`, `duration_ms` | Структурированные события, отправляемые на `/vpn/logs/send` |

---

## 2. Метрики оценки

### 2.1 Успешность подключений

| Метрика | Паттерн в логах | Целевое значение |
|---------|-----------------|------------------|
| **Success rate** | `ПОДКЛЮЧЕНИЕ УСПЕШНО УСТАНОВЛЕНО`, `result=success` в `[Connection timing]` | ≥ 95% |
| **Connection error rate** | `connection_error`, `protocol_error`, `result=error` | ≤ 5% |

### 2.2 Скорость подключения (tap-to-connected)

| Метрика | Паттерн | Целевое значение |
|---------|---------|------------------|
| **total_ms** | `[Connection timing] result=success total_ms=(\d+)` | < 5000 ms (сеть WiFi), < 8000 ms (мобильная) |
| **get_config** | `stages={get_config=(\d+)ms` | < 2000 ms |
| **establish** | `establish=(\d+)ms` | < 1500 ms |

### 2.3 Скорость отключения

| Метрика | Паттерн | Целевое значение |
|---------|---------|------------------|
| **disconnect_start → local_disconnect** | этапы `connection_stage` с stage=disconnect_* | < 2000 ms |
| **API disconnect** | `Отключение на сервере завершено за (\d+)ms` | < 3000 ms |

### 2.4 Критические ошибки

| Ошибка | Паттерн | Влияние на оценку |
|--------|---------|-------------------|
| **Native crash tun2socks** | `pthread_mutex_lock called on a destroyed mutex`, `Fatal signal 6 (SIGABRT)` в :tun2socks | Серьёзное (снижает оценку) |
| **tcp_bind_to_netif failed** | `tcp_bind_to_netif failed` | Критическое (трафик не идёт при reconnect) |
| **no space left** | `netif func output: no space left` | Среднее (деградация трафика) |
| **ConnectionLogger timeout** | `DioException [connection timeout]`, `Ошибка отправки логов` | Низкое (не влияет на VPN) |
| **Tun2SocksProcessService bind timeout** | `[DIAG] Tun2SocksProcessService bind timeout` | Серьёзное |

### 2.5 Протоколы

| Протокол | Приоритет | Паттерн в логах |
|----------|-----------|-----------------|
| xray_reality | 1 | `protocol.*reality`, `:443` |
| xray_vless | 2 | `protocol.*vless`, `:4443` |
| xray_vmess | 3 | `protocol.*vmess`, `:8443` |

Распределение успехов/ошибок по протоколам даёт понимание стабильности каждого.

---

## 3. Этапы connect flow (для анализа таймингов)

1. `permissions` — получение разрешения VPN
2. `load_device_id` — загрузка device_id (опционально)
3. `token_validation` — валидация токена
4. `sync_state` — синхронизация с сервером
5. `select_server` — выбор сервера и протокола
6. `get_config` — получение конфигурации (API или кэш)
7. `xray_create_client` — создание клиента Xray (для Xray)
8. `establish` — создание TUN, establish(), tun2socks
9. `verify_connection` — проверка трафика

### 3.1 Мониторинг: сессия, триггер, смена сети, трафик

Для поиска пробелов при первом подключении, повторном и смене сети (WiFi ↔ mobile) в логах API и logcat используются:

| Поле / событие | Описание |
|----------------|----------|
| **connection_session_id** | Уникальный ID сессии подключения (один на цикл connect → success/error/disconnect). Группировка всех этапов одной попытки. |
| **trigger** | Причина подключения: `first_connect`, `reconnect_after_network_change`, `reconnect_from_cache`. Позволяет фильтровать метрики по типу сценария. |
| **event_type: network_change** | Смена сети (WiFi ↔ mobile) перед переподключением. В `error_details`: `network_from`, `network_to`, `trigger=reconnect_after_network_change`. |
| **stage: reconnect_start** | Начало connect после смены сети (duration_ms=0). |
| **stage: reconnect_from_cache** | Подключение из кэша без API (reconnect без получения конфига заново). |
| **stage: disconnect_done** | Полное завершение отключения (вместе с disconnect_start, local_disconnect даёт тайминги отключения). |
| **event_type: traffic_first_seen** | Первый зафиксированный трафик через туннель. В `error_details`: `rx_bytes`, `tx_bytes`. Для контроля «трафик пошёл через VPN». |

В logcat: префикс `[MONITOR] network_change` при смене сети, `[VPN_TRAFFIC]` при первом трафике (дублируют события API для локального разбора).

---

## 4. Скоринг (оценка 0–100)

```
базовая_оценка = 100
- (native_crashes × 15)
- (tcp_bind_failures × 25)
- (no_space_left_count / 10)  # каждые 10 раз −1
- (connection_errors / total_attempts × 30)
- (connection_timeout_avg_over_8000ms ? 5 : 0)
- (disconnect_duration_avg_over_3000ms ? 5 : 0)
итог = max(0, min(100, базовая_оценка))
```

### 4.1 Уровни оценки

| Диапазон | Уровень | Рекомендация |
|----------|---------|--------------|
| 90–100 | Отлично | Продакшен-ready |
| 70–89 | Хорошо | Минорные улучшения |
| 50–69 | Удовлетворительно | Разобрать ошибки, проверить устройства |
| 0–49 | Требует внимания | Критические проблемы |

---

## 5. Использование инструмента

```bash
# Анализ файла логов
python3 tools/vpn_log_evaluator/vpn_log_evaluator.py --input logs.txt

# Анализ из stdin (adb logcat)
adb logcat -d | python3 tools/vpn_log_evaluator/vpn_log_evaluator.py

# С фильтром по тегу
adb logcat -d -s VpnService:* Tun2SocksProc:* ConnectionLogger:* | python3 tools/vpn_log_evaluator/vpn_log_evaluator.py
```

---

## 6. Выходной отчёт

Скрипт выводит:

1. **Сводка**: успехи/ошибки, протоколы, оценка 0–100
2. **Тайминги**: avg/min/max connection time, disconnect time
3. **Ошибки**: список паттернов и количество
4. **Рекомендации**: по уровню оценки

---

## 7. Ссылки

- [VPN_SERVICE_ANALYSIS.md](VPN_SERVICE_ANALYSIS.md) — анализ архитектуры и оптимизаций
- [TESTING_RECOMMENDATIONS.md](../TESTING_RECOMMENDATIONS.md) — ключевые сообщения в логах
- [ConnectionLogger](../lib/services/connection_logger.dart) — сервис логирования подключений
