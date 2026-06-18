# Симулятор блокировки по SNI (фаза 1.1.3)

Использование: эмуляция цензора, который обрывает соединения при определённом SNI в TLS Client Hello. Нужен для проверки кандидатов (например, Boring HTTPS): запрос к «прикрывающему» домену не должен дропаться.

## Вариант 1: mitmproxy с addon

1. Установить mitmproxy: `pip install mitmproxy` или из пакетов.
2. Запустить с addon: `mitmproxy -s backend/scripts/sni_block_simulator_addon.py`
3. На клиенте указать прокси (HTTP proxy) на `127.0.0.1:8080` и установить CA mitmproxy (для TLS клиент доверяет прокси).
4. В addon задать список блокируемых SNI (например, домен вашего VPN API). При совпадении соединение разрывается.

Addon см. в `backend/scripts/sni_block_simulator_addon.py`.

## Вариант 2: Без перехвата TLS (только логирование)

Если не нужна блокировка, а только просмотр SNI — используйте `tshark` после захвата:

```bash
tshark -r capture.pcap -Y "tls.handshake.type == 1" -T fields -e tls.handshake.extensions_server_name
```

Или установите tshark для анализа в скрипте `bypass_lab_capture_traffic.py --analyze`.

## Блок-лист для тестов

Рекомендуется для симулятора блокировать только «подозрительные» домены (например, домен вашего API или известный VPN-домен), а «прикрывающий» домен (CDN/облако) оставлять разрешённым — тогда PoC Boring HTTPS должен проходить.
