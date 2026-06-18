# Инфраструктура лаборатории для сценариев обхода блокировок

Описание стенда по плану [VPN_BYPASS_EXECUTION_PLAN.md](VPN_BYPASS_EXECUTION_PLAN.md): симулятор DPI/SNI, скрипты анализа трафика, тестовый клиент. Переиспользуется для всех сценариев (6, 4, 1, 3, 2, 5, 7).

---

## 1. Симулятор DPI/SNI

Эмуляция цензора: разрыв соединений по SNI и при необходимости по отпечатку JA3.

### Вариант: mitmproxy с addon

- **Скрипт:** `backend/scripts/sni_block_simulator_addon.py`
- **Запуск:** `mitmproxy -s backend/scripts/sni_block_simulator_addon.py` (прокси на 127.0.0.1:8080)
- **Настройка:** в файле задать `BLOCKED_SNI` — список доменов, при совпадении SNI с которыми соединение разрывается (`flow.kill()`). Опционально `BLOCKED_JA3` — список JA3-отпечатков (значения взять из анализа pcap).
- **Клиент:** настроить HTTP-прокси на 127.0.0.1:8080 и установить CA mitmproxy (для TLS).

Подробнее: [VPN_BYPASS_SNI_SIMULATOR.md](VPN_BYPASS_SNI_SIMULATOR.md).

---

## 2. Скрипты анализа трафика

### Захват и разбор pcap

- **Скрипт:** `backend/scripts/bypass_lab_capture_traffic.py`
- **Захват (требуются права на интерфейс):**
  ```bash
  sudo python3 backend/scripts/bypass_lab_capture_traffic.py --duration 30 --out /tmp/capture.pcap
  ```
- **Анализ существующего pcap:**
  ```bash
  python3 backend/scripts/bypass_lab_capture_traffic.py --analyze /tmp/capture.pcap
  ```
- **Вывод:** порты назначения (топ), SNI (TLS Client Hello), JA3 (если есть в tshark), размеры первых пакетов. Результаты использовать для сравнения с эталоном и для заполнения BLOCKED_JA3 в симуляторе.

Для JA3/JA4 и размеров пакетов нужен **tshark** (Wireshark).

---

## 3. Тестовый клиент (без приложения)

### PoC «прикрывающий» домен (один POST)

- **Скрипт:** `backend/scripts/boring_https_poc_client.py`
- **Назначение:** один или несколько POST к выбранному HTTPS URL (прикрывающий домен); для записи трафика и проверки SNI/JA3.
- **Запуск:** `python3 backend/scripts/boring_https_poc_client.py --url https://www.google.com/generate_204 --repeat 5`

### Bootstrap (сценарий 6): DoH и загрузка конфига

- **Скрипт:** `backend/scripts/bypass_lab_bootstrap_poc.py`
- **Назначение:** проверка доступности DoH (резолв через Cloudflare DoH) и загрузка bootstrap JSON (GET api_base_urls) с указанного URL. Ручной тест: конфиг скачивается и парсится.
- **Запуск:**
  ```bash
  python3 backend/scripts/bypass_lab_bootstrap_poc.py --doh api.granilink.com
  python3 backend/scripts/bypass_lab_bootstrap_poc.py --url https://api.granilink.com/api/vpn/bootstrap
  ```

### Адаптивный выбор стратегии (сценарий 3)

- **Скрипт:** `backend/scripts/bypass_lab_adaptive_selector.py`
- **Назначение:** логика выбора стратегии по результатам зондов (DoH, основной домен, SNI, прикрывающий домен). Unit-тесты: `python3 backend/scripts/bypass_lab_adaptive_selector.py`.

### Мимикрия под сервис (сценарий 1)

- **Скрипт:** `backend/scripts/bypass_lab_mimicry_poc.py`
- **Назначение:** один туннельный запрос с опциональным TLS-отпечатком под браузер (curl_cffi, impersonate=chrome). Для сравнения с эталоном: записать pcap скрипта и браузера, сравнить JA3 и размеры через `--analyze`.
- **Запуск:** `pip install curl_cffi` затем `python3 backend/scripts/bypass_lab_mimicry_poc.py --url https://.../api/vpn/tunnel --impersonate chrome`

### Туннельный клиент Boring HTTPS (gateway)

- **Скрипт:** `backend/scripts/bypass_lab_tunnel_client.py`
- **Назначение:** подключение к Boring HTTPS gateway (POST /tunnel), health check и опционально один туннельный фрейм (4 байта длина + payload). Для проверки «трафик идёт» в лаборатории.
- **Запуск:**
  ```bash
  python3 backend/scripts/bypass_lab_tunnel_client.py --url http://127.0.0.1:8799/api/vpn/tunnel
  python3 backend/scripts/bypass_lab_tunnel_client.py --url https://gate.example.com/api/vpn/tunnel --frame "test" --insecure
  ```

---

## 4. Порядок использования в лаборатории

1. **Подготовить стенд:** установить tcpdump, tshark, при необходимости mitmproxy. Задать BLOCKED_SNI (и при необходимости BLOCKED_JA3) в addon.
2. **Захват трафика:** запустить захват, в другом окне — тестовый клиент или PoC; остановить захват, выполнить `--analyze`.
3. **Проверка обхода:** направить клиента через симулятор (прокси); «прикрывающий» домен не должен быть в BLOCKED_SNI; соединение не должно разрываться.
4. **Туннель (сценарий 4):** для Boring HTTPS использовать `bypass_lab_tunnel_client.py` к локальному или тестовому gateway (`--url http://127.0.0.1:PORT/api/vpn/tunnel`). Убедиться, что health check и туннельный фрейм возвращают 200 и ответ в формате 4 байта длина + payload. Записать pcap во время запроса и проверить SNI/JA3 через `--analyze`; прогнать через симулятор (прикрывающий домен не в BLOCKED_SNI).

См. также [VPN_BYPASS_LAB_EVALUATION.md](VPN_BYPASS_LAB_EVALUATION.md) и [VPN_BYPASS_LAB_RESULTS.md](VPN_BYPASS_LAB_RESULTS.md).
