# Установка ADB на Windows

## Быстрая установка (рекомендуется)

### Способ 1: Через Android SDK Platform Tools (самый простой)

1. **Скачайте Android SDK Platform Tools:**
   - Перейдите на: https://developer.android.com/studio/releases/platform-tools
   - Или прямая ссылка: https://dl.google.com/android/repository/platform-tools-latest-windows.zip

2. **Распакуйте архив:**
   - Создайте папку, например: `C:\Android\platform-tools`
   - Распакуйте туда содержимое архива

3. **Добавьте в PATH:**
   - Нажмите `Win + R`, введите `sysdm.cpl`, нажмите Enter
   - Вкладка "Дополнительно" → "Переменные среды"
   - В "Системные переменные" найдите `Path` → "Изменить"
   - "Создать" → введите путь: `C:\Android\platform-tools`
   - "ОК" везде

4. **Перезапустите PowerShell** и проверьте:
   ```powershell
   adb version
   ```

### Способ 2: Через Chocolatey (если установлен)

```powershell
choco install adb
```

### Способ 3: Через Scoop (если установлен)

```powershell
scoop install adb
```

### Способ 4: Временное использование (без установки)

Если не хотите устанавливать, можно использовать напрямую:

1. Скачайте и распакуйте Platform Tools (как в Способе 1)
2. В PowerShell перейдите в папку:
   ```powershell
   cd C:\Android\platform-tools
   ```
3. Используйте с полным путем:
   ```powershell
   .\adb.exe devices
   .\adb.exe tcpip 5555
   .\adb.exe connect 172.16.105.33:5555
   ```

## Проверка установки

После установки откройте **новый** PowerShell и выполните:

```powershell
adb version
```

Должно показать версию ADB.

## После установки ADB

Выполните команды для настройки:

```powershell
# 1. Проверьте подключение устройства
adb devices

# 2. Включите TCP/IP режим
adb tcpip 5555

# 3. Подключитесь к устройству локально
adb connect 172.16.105.33:5555

# 4. Проверьте
adb devices
```

## Альтернатива: Использование Android Studio

Если у вас установлен Android Studio:
- ADB уже установлен
- Обычно находится в: `C:\Users\ВашеИмя\AppData\Local\Android\Sdk\platform-tools`
- Добавьте этот путь в PATH (как в Способе 1, шаг 3)

## Быстрая проверка пути ADB

Если ADB уже установлен, но не в PATH, найдите его:

```powershell
# Поиск adb.exe на диске C:
Get-ChildItem -Path C:\ -Filter adb.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 FullName
```

Затем используйте полный путь или добавьте в PATH.





