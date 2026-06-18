# Анализ логов Firebase Test Lab - 20 января 2026

## 📊 Результаты анализа логов

**Дата анализа:** 20 января 2026  
**Matrix ID:** matrix-2vor42kxd4au2  
**Источник:** `/tmp/firebase_logs/`

---

## ✅ Что работает

### 1. Передача конфигурации sing-box

**Логи показывают:**
```
01-20 00:38:05.850 D VpnServiceTest: DEBUG: singbox_config_b64 from args: ewogICJsb2ciOiB7CiAgICAibGV2ZWwiOiAiaW5mbyIKICB9LA...
01-20 00:38:05.851 D VpnServiceTest: DEBUG: Found config in instrumentation args: singbox_config_b64
01-20 00:38:05.851 D VpnServiceTest: DEBUG: Config after read: {
  "log": { "level": "info" },
  "inbounds": [{ "type": "tun", "tag": "tun-i...
01-20 00:38:05.851 D VpnServiceTest: DEBUG: Config is null or blank: false
```

**Вывод:** ✅ Конфигурация sing-box **передается и читается корректно**!

---

## ❌ Проблемы

### Проблема 1: WireGuard конфигурация не передается

**Логи:**
```
01-20 00:38:05.842 D VpnServiceTest: DEBUG: wireguard_config_b64 from args: null...
01-20 00:38:05.842 D VpnServiceTest: DEBUG: wireguard_config_b64 from env: null...
01-20 00:38:05.842 W VpnServiceTest: DEBUG: Config not found in args or env: wireguard_config_b64 / wireguard_config
01-20 00:38:05.842 D VpnServiceTest: DEBUG: Config is null or blank: true
01-20 00:38:05.843 E TestRunner: org.junit.AssumptionViolatedException: wireguard_config not provided
```

**Причина:** Мы передали только `singbox_config_b64`, но не передали `wireguard_config_b64`.

**Решение:** Это нормально, если мы тестируем только sing-box. WireGuard тест пропускается, что ожидаемо.

---

### Проблема 2: VPN разрешение не выдается автоматически

**Временная шкала:**
```
01-20 00:38:05.852 D VpnServiceTest: DEBUG: Requesting VPN permission...
01-20 00:38:05.854 I ActivityTaskManager: START u0 {flg=0x10000000 cmp=com.android.vpndialogs/.ConfirmDialog} from uid 10177
01-20 00:38:22.969 D VpnServiceTest: DEBUG: VPN permission final status: false
01-20 00:38:22.969 D VpnServiceTest: DEBUG: VPN permission granted: false
```

**Анализ:**
- ✅ Диалог VPN **открывается** (ActivityTaskManager показывает запуск ConfirmDialog)
- ❌ UI Automator **не находит кнопку** для нажатия
- ⏱️ Прошло **17 секунд** (с 00:38:05 до 00:38:22), но разрешение не выдано

**Проблема:** UI Automator не может найти кнопку в диалоге VPN в Firebase Test Lab.

---

## 🔍 Детальный анализ VPN диалога

### Что происходит:

1. **00:38:05.852** - Запрос VPN разрешения
2. **00:38:05.854** - Диалог открывается (`com.android.vpndialogs/.ConfirmDialog`)
3. **00:38:22.969** - Проверка разрешения (через 17 секунд) - **false**

### Почему UI Automator не находит кнопку:

**Возможные причины:**

1. **Диалог имеет другую структуру в Firebase Test Lab**
   - Может быть другой layout
   - Может быть другой resource ID
   - Может быть другой текст кнопки

2. **Диалог появляется с задержкой**
   - UI Automator ищет кнопку слишком рано
   - Нужно больше времени на появление диалога

3. **UI Automator не имеет доступа к системному диалогу**
   - Firebase Test Lab может ограничивать доступ к системным диалогам
   - Может потребоваться специальные разрешения

4. **Кнопка имеет другой селектор**
   - Не `android:id/button1`
   - Не текст "OK"/"Allow"/"Разрешить"
   - Может быть другой структуры

---

## 💡 Решения

### Решение 1: Улучшить поиск кнопки VPN диалога

**Проблема:** Текущий код ищет кнопку по `android:id/button1`, но в Firebase Test Lab может быть другая структура.

**Что сделать:**

1. **Добавить больше селекторов:**
   ```kotlin
   // Попробовать разные resource IDs
   - android:id/button1
   - android:id/button_positive
   - android:id/ok
   - android:id/allow
   ```

2. **Использовать более широкий поиск:**
   ```kotlin
   // Искать все кнопки в диалоге
   val buttons = device.findObjects(By.clazz("android.widget.Button"))
   buttons.forEach { button ->
       val text = button.text?.toString()?.lowercase() ?: ""
       if (text.contains("ok") || text.contains("allow") || text.contains("разрешить")) {
           button.click()
       }
   }
   ```

3. **Увеличить таймауты и добавить ожидание:**
   ```kotlin
   // Ждать появления диалога
   Thread.sleep(3000) // Дать время на появление диалога
   
   // Увеличить timeout для поиска кнопки
   val timeoutMs = 15000L // Вместо 10000
   ```

### Решение 2: Использовать Accessibility Service

**Альтернатива:** Вместо UI Automator использовать Accessibility Service для поиска элементов.

**Проблема:** Требует дополнительных разрешений и может быть сложнее в реализации.

### Решение 3: Предварительно выдать разрешение

**Вариант:** Выдать VPN разрешение до запуска тестов через ADB:

```bash
# Выдать VPN разрешение через ADB (если возможно)
adb shell pm grant com.granivpn.mobile android.permission.BIND_VPN_SERVICE
```

**Проблема:** VPN разрешение нельзя выдать через `pm grant`, оно требует интерактивного подтверждения.

### Решение 4: Использовать скриншоты для диагностики

**Что сделать:** В Firebase Test Lab доступны скриншоты. Можно посмотреть, как выглядит диалог VPN и какой у него layout.

**Где посмотреть:** В Firebase Console → Test Results → Screenshots

---

## 📋 Рекомендуемое решение

### Приоритет 1: Улучшить поиск кнопки

**Изменения в `ensureVpnPermission()`:**

1. **Добавить ожидание появления диалога:**
   ```kotlin
   context.startActivity(intent)
   Thread.sleep(3000) // Дать время на появление диалога
   ```

2. **Использовать более широкий поиск кнопок:**
   ```kotlin
   // Искать все кнопки в диалоге
   val buttons = device.findObjects(By.clazz("android.widget.Button"))
   for (button in buttons) {
       val text = button.text?.toString()?.lowercase() ?: ""
       if (text.contains("ok") || text.contains("allow") || 
           text.contains("разрешить") || text.contains("yes")) {
           Log.d(TAG, "DEBUG: Found button with text: ${button.text}")
           button.click()
           Thread.sleep(2000)
           if (VpnService.prepare(context) == null) {
               return true
           }
       }
   }
   ```

3. **Попробовать разные resource IDs:**
   ```kotlin
   val resourceIds = listOf(
       "android:id/button1",
       "android:id/button_positive",
       "android:id/ok",
       "android:id/allow"
   )
   
   for (resId in resourceIds) {
       val button = device.wait(Until.findObject(By.res(resId)), 2000L)
       if (button != null) {
           button.click()
           Thread.sleep(2000)
           if (VpnService.prepare(context) == null) {
               return true
           }
       }
   }
   ```

4. **Использовать координаты экрана (fallback):**
   ```kotlin
   // Если не нашли кнопку, попробовать нажать в центре экрана
   // (обычно кнопка "OK" находится внизу по центру)
   val display = device.displayWidth
   val height = device.displayHeight
   device.click(display / 2, height - 200) // Примерные координаты кнопки
   ```

---

## 📊 Статистика из логов

| Событие | Время | Статус |
|---------|-------|--------|
| Запрос VPN разрешения | 00:38:05.852 | ✅ |
| Диалог открывается | 00:38:05.854 | ✅ |
| Поиск кнопки button1 | 00:38:05.854+ | ❌ Не найдена |
| Поиск кнопки "OK" | 00:38:05.854+ | ❌ Не найдена |
| Поиск кнопки "Allow" | 00:38:05.854+ | ❌ Не найдена |
| Поиск кнопки "Разрешить" | 00:38:05.854+ | ❌ Не найдена |
| Финальная проверка | 00:38:22.969 | ❌ Разрешение не выдано |

**Время ожидания:** 17 секунд  
**Результат:** Разрешение не выдано

---

## 🎯 Выводы

1. ✅ **Конфигурация передается корректно** - sing-box конфигурация читается из `InstrumentationRegistry.getArguments()`
2. ❌ **VPN разрешение не выдается** - UI Automator не может найти кнопку в диалоге
3. ⚠️ **WireGuard конфигурация не передается** - это нормально, если тестируем только sing-box

**Основная проблема:** UI Automator не находит кнопку в VPN диалоге в Firebase Test Lab.

**Решение:** Улучшить логику поиска кнопки, добавить больше селекторов и увеличить таймауты.

---

**Дата:** 20 января 2026  
**Версия:** 1.0  
**Статус:** Требуется улучшение логики выдачи VPN разрешения
