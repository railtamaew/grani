# Запуск тестов в Firebase Test Lab - 20 января 2026

## ✅ Тесты запущены

**Дата:** 20 января 2026, 08:08 UTC  
**Проект:** grani-479612  
**Matrix ID:** matrix-32pdsudonqsll  
**Устройство:** Pixel2.arm, Android 30

---

## 📊 Результаты

**Статус:** ⚠️ Тесты пропущены (SKIPPED)

**Детали:**
- **0 test cases failed** - нет провалившихся тестов
- **2 skipped** - оба теста пропущены

**Тесты:**
1. `start_singbox_with_provided_config()` - пропущен
2. `start_wireguard_with_provided_config()` - пропущен

**Время выполнения:** 15 секунд

---

## 🔍 Анализ проблемы

### Возможные причины пропуска тестов

Тесты используют `assumeTrue()`, который **пропускает** тест, если условие не выполнено:

1. **Конфигурация не передана:**
   ```kotlin
   assumeTrue("singbox_config not provided", !config.isNullOrBlank())
   ```
   - Если конфигурация пустая или null, тест пропускается

2. **VPN разрешение не выдано:**
   ```kotlin
   assumeTrue("VPN permission not granted", ensureVpnPermission(context))
   ```
   - Если `ensureVpnPermission()` возвращает `false`, тест пропускается

### Что было передано

**Конфигурация:**
- ✅ Файл: `test_configs/singbox_minimal.json`
- ✅ Кодирование: base64
- ✅ Передача: через `environment-variables` как `singbox_config_b64`

**Скрипт запуска:**
```bash
./scripts/run_firebase_tests.sh \
    --singbox-config test_configs/singbox_minimal.json \
    --device-model Pixel2.arm \
    --device-version 30
```

---

## 🔧 Диагностика

### Проверка передачи конфигурации

**В скрипте (`run_firebase_tests.sh`):**
```bash
SINGBOX_B64=$(base64 -w 0 < "$SINGBOX_CONFIG")
ENV_VARS="$ENV_VARS,singbox_config_b64=$SINGBOX_B64"
```

**В тесте (`VpnServiceIntegrationTest.kt`):**
```kotlin
private fun readConfigArg(plainKey: String, b64Key: String): String? {
    val args = InstrumentationRegistry.getArguments()
    val b64 = args.getString(b64Key)  // Ищет "singbox_config_b64"
    if (!b64.isNullOrBlank()) {
        return String(Base64.decode(b64, Base64.DEFAULT))
    }
    return args.getString(plainKey)  // Fallback на "singbox_config"
}
```

**Проблема:** Firebase Test Lab передает environment variables через `InstrumentationRegistry.getArguments()`, но возможно:
- Переменная не передается правильно
- Или имя переменной не совпадает

### Проверка VPN разрешения

**Функция `ensureVpnPermission()`:**
- Использует UI Automator для автоматического нажатия кнопки "OK"/"Allow"
- Работает в Firebase Test Lab (подтверждено ранее)
- Но может не сработать, если диалог не появляется или появляется с задержкой

---

## 📝 Следующие шаги

### 1. Проверить детали в Firebase Console

**Ссылка:**
```
https://console.firebase.google.com/project/grani-479612/testlab/histories/bh.26be956619bb9aa6/matrices/6417405261606256780
```

**Что проверить:**
- Логи тестов (test logs)
- Скриншоты (если доступны)
- Детали пропуска тестов (assumption violations)

### 2. Добавить логирование в тесты

Добавить логи для диагностики:
```kotlin
@Test
fun start_singbox_with_provided_config() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val args = InstrumentationRegistry.getArguments()
    
    // Логирование для диагностики
    println("DEBUG: All args keys: ${args.keySet()}")
    println("DEBUG: singbox_config_b64 present: ${args.getString("singbox_config_b64") != null}")
    println("DEBUG: singbox_config_b64 length: ${args.getString("singbox_config_b64")?.length ?: 0}")
    
    val config = readConfigArg("singbox_config", "singbox_config_b64")
    println("DEBUG: Config after read: ${config?.take(100)}...")
    
    assumeTrue("singbox_config not provided", !config.isNullOrBlank())
    // ...
}
```

### 3. Проверить формат передачи environment variables

Firebase Test Lab может требовать другой формат. Проверить документацию:
- https://firebase.google.com/docs/test-lab/android/command-line#test_arguments

### 4. Альтернативный способ передачи конфигурации

Вместо environment variables использовать:
- Файл в APK (assets)
- Или передавать через test arguments в другом формате

---

## 📊 Статистика

| Метрика | Значение |
|---------|----------|
| Время загрузки APK | ~1 минута |
| Время выполнения тестов | 15 секунд |
| Время обработки результатов | 3 секунды |
| Общее время | ~2 минуты |

---

## ✅ Что работает

1. ✅ Авторизация в Firebase
2. ✅ Загрузка APK в Firebase Test Lab
3. ✅ Запуск тестов на устройстве
4. ✅ Получение результатов

## ⚠️ Что требует исправления

1. ⚠️ Передача конфигурации через environment variables
2. ⚠️ Автоматическая выдача VPN разрешения (возможно)

---

**Дата:** 20 января 2026  
**Версия:** 1.0  
**Статус:** Требуется диагностика пропущенных тестов
