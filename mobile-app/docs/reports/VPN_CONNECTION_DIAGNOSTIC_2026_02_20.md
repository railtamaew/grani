# Диагностика VPN: «даже первое подключение не удачное»

**Дата:** 2026-02-20  
**Устройство:** Oplus (OnePlus/Oppo), ColorOS  
**Клиент:** com.granivpn.mobile

---

## 1. Краткий вывод

| Компонент | Статус |
|-----------|--------|
| Сервер (45.12.132.94:4443 VLESS) | ✅ Подключения проходят |
| Xray (libXray) | ✅ Стартует, SOCKS 10808 слушает |
| TUN-интерфейс | ✅ Создаётся |
| tun2socks | ⚠️ Работает, но **массовые "no space left"** |
| Трафик (первый connect) | ⚠️ Идёт, но **деградирует** из‑за переполнения буфера TUN |
| Трафик (reconnect) | ❌ **Пакеты не доходят до tun2socks** (нет proxy/socks) |

---

## 2. Основная проблема: `netif func output: no space left`

### Что происходит

1. **Первый connect (12:18:44)**  
   - Трафик сразу идёт (`proxy/socks`, `proxy/vless` в логах).  
   - Примерно через 1.5 с после старта tun2socks:  
     `WARNING(tun2socks): netif func output: no space left`  
   - Сообщение повторяется десятки раз.

2. **Reconnect (12:19:36, 12:20:12, 12:20:39)**  
   - tun2socks стартует, но **нет ни одной строки `proxy/socks`**.  
   - Есть только `netif func output: no space left`.

### Техническая суть

`netif func output` в badvpn/lwIP — это функция записи пакетов **из** tun2socks **в** TUN.  
«No space left» соответствует `ENOBUFS`: буфер записи TUN-интерфейса переполнен, ядро не принимает новые пакеты.

Это приводит к:

- потере пакетов (в т.ч. ответов Xray → приложение);
- таймаутам и «connection timeout» при отправке логов.

---

## 3. Вторая проблема: reconnect без трафика

При reconnect:

- Xray и tun2socks запускаются;
- В логах tun2socks **нет `proxy/socks`** — пакеты не попадают в tun2socks.

Вероятная причина — маршрутизация: `Builder.establish()` вызывается не из main thread, ConnectivityService может некорректно обновлять маршруты, из‑за чего трафик идёт не через новый TUN.

---

## 4. Сопутствующие наблюдения

| Симптом | Причина |
|---------|---------|
| `ConnectionLogger: DioException [connection timeout]` | Связка «no space left» + возможная фоновая работа приложения |
| `api.granilink.com` в direct | Роутинг корректен, direct работает (`proxy/freedom: connection opened`) |
| `callGcSupression NullPointerException` | Специфика Oplus/ColorOS, не ошибка приложения |
| `ip route get 8.8.8.8: Permission denied` | Обычное ограничение в контексте VPN, не критично |

---

## 5. Рекомендации

### 5.1. Буфер TUN: «no space left»

1. **Снизить MTU**  
   - В конфиге уже `mtu=1280`.  
   - Проверить, что это значение действительно используется для TUN и tun2socks (сейчас по умолчанию 1420).  
   - Экспериментально можно пробовать ещё ниже (например, 1200).

2. **Буферы сокетов (если возможно)**  
   - В Linux TUN буферы задаются `ioctl(TUNSETSNDBUF)` / `TUNSETRCVBUF`.  
   - На Android это зависит от VpnService и ядра.  
   - В tun2socks/lib нужно проверить, есть ли поддержка увеличения буферов.

3. **Защита сокетов**  
   - Убедиться, что все сокеты Xray и tun2socks защищены через `protect()`, иначе Oplus/ColorOS может ограничивать их трафик.

### 5.2. Reconnect без трафика

1. **Вызов `establish()` из main thread**  
   - Как описано в `NATIVE_RECONNECT_ANALYSIS.md`: выполнять `Builder.establish()` через `Handler(Looper.getMainLooper()).post {}`, чтобы ConnectivityService корректно обновил маршруты при reconnect.

2. **Задержка перед `establish()`**  
   - Давать системе время снять маршруты старого TUN перед созданием нового (проверить `RECONNECT_DELAY_BEFORE_ESTABLISH_MS` и при необходимости скорректировать).

### 5.3. Логирование

- Добавить лог фактического MTU, передаваемого в TUN и tun2socks.  
- Временно увеличить логирование tun2socks (если есть debug-режим), чтобы видеть поведение при ENOBUFS.

---

## 6. Конфигурация

| Параметр | Значение |
|----------|----------|
| Сервер | 45.12.132.94:4443 |
| Протокол | VLESS TCP (plain) |
| Клиент | 8c4b1099-5414-4ec3-b5f2-405240eff778 |
| MTU (config) | 1280 |
| MTU (по умолчанию в коде) | 1420 |
| TUN IP | 10.0.0.2/30 |
| Xray SOCKS | 127.0.0.1:10808 |
| api.granilink.com | direct (159.223.199.122) |

---

## 7. Что делать дальше

1. ~~Проверить, что MTU=1280 действительно используется~~ — **ИСПРАВЛЕНО**: MTU теперь передаётся из `XrayNativeWrapperTun2Socks` в `XrayNativeWrapper`, TUN и tun2socks используют одно значение (1280 из конфига).  
2. ~~Внедрить вызов `establish()` на main thread~~ — **СДЕЛАНО**: основной `startVpn` использует `establishOnMainThread(builder)`.  
3. Собрать APK с изменениями и повторить тест на том же устройстве Oplus.  
4. Если «no space left» сохранится — рассмотреть альтернативы badvpn tun2socks (например, go-tun2socks или tun2socks из Xray/других проектов), где может быть другой подход к ENOBUFS.

## 8. Внесённые правки

- **XrayNativeWrapperTun2Socks.kt**: MTU передаётся в `XrayNativeWrapper.startVpn(mtu = tunMtu)`, чтобы TUN и tun2socks использовали одинаковый MTU (1280 из конфига вместо 1420 по умолчанию). Добавлен лог `[DIAG] startVpn: MTU=$tunMtu`.
- **XrayNativeWrapper.kt**: Основной путь `startVpn` теперь вызывает `establishOnMainThread(builder)` вместо `builder.establish()` — ConnectivityService может ожидать `establish()` на main thread для корректного обновления маршрутов при reconnect.
