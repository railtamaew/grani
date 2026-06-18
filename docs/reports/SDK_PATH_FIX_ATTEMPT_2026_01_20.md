# Попытка исправления проблемы с SDK path - 20 января 2026

## 🔍 Анализ проблемы

### Ошибка
```
FATAL | Broken AVD system path. Check your ANDROID_SDK_ROOT value [/opt/android-sdk]!
WARNING | emulator has searched the above paths but found no valid sdk root directory.
```

### Что было исправлено

1. ✅ Добавлено поле `image.sysdir.1` в config.ini для grani_optimized
2. ✅ Добавлены поля `tag.display` и `tag.id`
3. ✅ Обновлен скрипт `recreate_avd_optimized.sh` для включения этих полей

### Результат

❌ Проблема сохраняется. Эмулятор все еще не может найти SDK root.

## 🔬 Детальный анализ

### Что проверено

1. ✅ Структура SDK:
   - `/opt/android-sdk/platforms/android-30/android.jar` - существует
   - `/opt/android-sdk/system-images/android-30/default/x86_64/system.img` - существует
   - `/opt/android-sdk/system-images/android-30/default/x86_64/build.prop` - существует

2. ✅ Переменные окружения:
   - `ANDROID_SDK_ROOT=/opt/android-sdk` - установлена
   - `ANDROID_HOME=/opt/android-sdk` - установлена
   - `PATH` включает пути к SDK

3. ✅ Config.ini:
   - `image.sysdir.1 = system-images/android-30/default/x86_64/` - добавлено
   - `android.sdk.path = /opt/android-sdk` - установлено
   - `tag.display` и `tag.id` - добавлены

### Что не работает

Эмулятор версии 36.3.10.0 имеет проблему с определением SDK root. Даже при правильной структуре и конфигурации он не может найти SDK.

## 💡 Возможные причины

1. **Проблема с версией эмулятора**
   - Версия 36.3.10.0 может иметь баг
   - Требуется обновление или откат версии

2. **Проблема с правами доступа**
   - Эмулятор может проверять права на чтение определенных файлов
   - Нужно проверить права на `/opt/android-sdk`

3. **Проблема с путями в config.ini**
   - Эмулятор может ожидать абсолютные пути
   - Или относительные пути от определенной директории

4. **Проблема с отсутствующими файлами**
   - Эмулятор может искать специфические файлы-маркеры
   - Например, `.android` в корне SDK или другие файлы

## 🚀 Решения

### Решение 1: Использовать рабочий AVD (grani_light)

**Статус:** ✅ Работает

```bash
export AVD_NAME=grani_light
/opt/grani/scripts/start_combined_testing.sh manual
```

### Решение 2: Обновить/откатить эмулятор

```bash
# Обновить эмулятор
sdkmanager --update
sdkmanager "emulator" --channel=0

# Или откатить на старую версию
sdkmanager "emulator;30.0.0"
```

### Решение 3: Создать новый AVD через avdmanager

```bash
# Удалить проблемный AVD
avdmanager delete avd -n grani_optimized

# Создать новый через avdmanager (автоматически настроит все поля)
echo "no" | avdmanager create avd \
  -n grani_optimized \
  -k "system-images;android-30;default;x86_64" \
  -d pixel_5 \
  --force

# Затем настроить параметры вручную
```

### Решение 4: Использовать физическое устройство

Подключить Android устройство через USB и использовать его вместо эмулятора.

## 📝 Выводы

1. **Проблема исправима**, но требует дополнительной диагностики
2. **Рабочее решение:** Использовать `grani_light` AVD, который работает
3. **Долгосрочное решение:** Обновить/откатить эмулятор или создать новый AVD через avdmanager

## ✅ Текущий статус

- ✅ `grani_light` AVD работает
- ✅ Система может быть запущена с `grani_light`
- ❌ `grani_optimized` AVD не работает (проблема с SDK path detection)

---

**Дата:** 20 января 2026  
**Версия:** 1.0
