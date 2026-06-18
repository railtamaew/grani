# Отчёт по логам после пересборки и теста (2026-02-11)

По логам приложения `com.granivpn.mobile` (release, 64-bit) после пересборки и ручного теста.

---

## 1. Google OAuth

- **Старт:** `Google OAuth: Вызов GoogleSignIn.signIn()...`
- **Результат:** успех (`Google OAuth: успешная авторизация, user_id: 1` / `user_id: 4`).
- **Замечание:** первый запрос к `https://api.granilink.com/api/auth/google/callback` даёт таймаут/сеть, повтор через 2 с — затем ответ 200, токен получен. Таймаут на первом запросе может быть из-за холодного старта или сети.

---

## 2. Лимит устройств (5)

**Текст в логах:**  
`VpnException: Ошибка регистрации устройства: Достигнут лимит устройств (5)` (DeviceLimitException).

- При первом подключении после входа регистрация устройства возвращает 400 (лимит 5 устройств).
- После перехода в профиль и обновления статуса (`AuthService: Статус пользователя обновлен`) позже регистрация проходит: `VpnService._registerDeviceIfNeeded: ✅ Устройство успешно зарегистрировано, statusCode=200`.
- **Вывод:** лимит 5 устройств на аккаунт; при переполнении нужно удалять устройство в ЛК или на бэкенде.

---

## 3. ConnectionLogger (логи на сервер)

- **404 NOT_FOUND:**  
  `Устройство не найдено. Запрошенный device_id: '...'` при `POST /api/vpn/logs/send` — устройство ещё не зарегистрировано или другой device_id.
- **400 при повторной регистрации:** после 404 вызывается `_registerDeviceRetry` → 400 (лимит устройств).
- **receive timeout 10s:**  
  `DioException [receive timeout]: The request took longer than 0:00:10.000000` для `https://api.granilink.com/api/vpn/logs/send` — логи возвращаются в очередь для повторной попытки.
- После успешной регистрации устройства логи уходят: `ConnectionLogger._flushLogs: ✅ Логи успешно отправлены: 26 шт.` / `2 шт.`.

**Рекомендация:** при 404 по device_id не слать логи до успешной регистрации устройства (или один раз зарегистрировать, затем слать логи).

---

## 4. requestCode 53293 не обработан VPN-плагином

```
MainActivity: VPN плагин не обработал requestCode: 53293
```

- 53293 — типичный requestCode от Google Sign-In (`SignInIntent`).
- Результат Sign-In приходит в `MainActivity.onActivityResult`; если плагин не обрабатывает этот код, это ожидаемо: обработка в Flutter/Google Sign-In. На работу входа это не влияет (OAuth завершается успешно).

---

## 5. callGcSupression NPE

Многократно в логах:
`callGcSupression: java.lang.NullPointerException: Attempt to invoke virtual method 'java.lang.Object java.lang.reflect.Method.invoke(java.lang.Object, java.lang.Object[])' on a null object reference`.

- Источник — системный/прошивка (Oplus/ColorOS), не код приложения. На функциональность приложения не влияет.

---

## 6. OplusScrollToTopManager — Receiver not registered

```
OplusScrollToTopManager: unregisterSystemUIBroadcastReceiver failed java.lang.IllegalArgumentException: Receiver not registered
```

- При закрытии `SignInHubActivity` и при закрытии MainActivity. Реализация OEM; не из кода приложения.

---

## 7. Двойной вызов connect и блокировка

- При первом нажатии «подключить»: `_isConnecting=true`, синхронизация с сервером, регистрация устройства (успех 200), получение Xray-конфига, старт VPN.
- Параллельно (из-за обновления статуса/навигации) снова вызывается `connect`:
  - `VpnService.connect: ❌ БЛОКИРОВКА - Уже подключено или идет подключение` (`_isConnecting: true`).
- То есть повторный вызов connect при уже идущем подключении корректно блокируется.

---

## 8. Два START_VPN (startId=1 и startId=2)

- `onStartCommand: action=START_VPN, startId=1` — первый запуск VPN, конфиг применён, Xray запущен.
- Позже `onStartCommand: action=START_VPN, startId=2` при уже запущенном VPN:
  - `GraniVpnService: VPN уже запущен`, `onStartCommand: старт VPN не удался`.
- При этом плагин всё равно получает подтверждение: `startVpnConnection: VPN подтвердил запуск` — т.е. второй вызов не ломает уже установленное подключение.

**Рекомендация:** при `isRunning=true` не возвращать «ошибку» в логах как критичную; при необходимости обновлять конфиг или явно отвечать «уже запущен».

---

## 9. Проверка подключения (IP и трафик)

- Предупреждение:  
  `VpnService: ⚠️ IP адрес не совпадает (ожидался: 45.12.132.94, получен: 94.180.243.40)`.
- Ожидаемый IP — адрес сервера; фактический — внешний IP после выхода в интернет (exit-IP). Для Reality/прокси такое расхождение возможно.
- Трафик и DNS в норме: `VpnService: ✅ Трафик обнаружен`, `VpnService: ✅ DNS работает`, `VpnService: ✅ REALITY probe успешен`.

---

## 10. Xray: connection ends / context canceled

В логах Xray:
- `connection ends > proxy/socks: connection ends > context canceled`
- `failed to process outbound traffic > proxy/vless/outbound: failed to find an available destination > common/retry: [context canceled dial tcp 45.12.132.94:443: operation was canceled]`

Обычно при закрытии соединения или таймауте. После этого новые соединения продолжают подниматься (логи с `accepted tcp: ... [socks-in -> proxy]`), т.е. VPN в целом работает.

---

## 11. Итог по сценарию

| Этап                         | Результат |
|-----------------------------|-----------|
| Google OAuth                | Успех (с повтором при первом таймауте) |
| Регистрация устройства      | Сначала 400 (лимит 5), позже 200 после смены статуса/профиля |
| Отправка логов (ConnectionLogger) | 404 до регистрации, таймаут 10 с, затем успешная отправка после регистрации |
| Подключение VPN (Xray Reality) | Успешно: конфиг получен, VPN запущен, трафик есть |
| Двойной connect/START_VPN   | Блокировка повторного connect; второй START_VPN — «VPN уже запущен» |
| Системные/ОЕМ сообщения     | NPE в callGcSupression, Receiver not registered — не из приложения |

---

## 12. Рекомендации

1. **Лимит устройств:** в UI при 400 «Достигнут лимит устройств (5)» показывать явный текст и ссылку на управление устройствами в ЛК.
2. **ConnectionLogger:** не слать логи по `/vpn/logs/send` до успешной регистрации устройства (или один раз зарегистрировать и затем слать).
3. **Таймаут 10 с:** при необходимости увеличить `receiveTimeout` для `/vpn/logs/send` или не блокировать UI.
4. **Второй START_VPN:** при `isRunning=true` не логировать как «старт VPN не удался», а фиксировать как «уже запущен» и при необходимости только обновлять конфиг.

Документ составлен по логам от 2026-02-11.
