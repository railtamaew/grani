# Размеры иконок для Android и iOS

## 📱 Android

### Исходная иконка (source image)
- **Размер:** 1024×1024 px
- **Формат:** PNG
- **Путь:** `assets/icons/icon_01.png`
- **Требования:** 
  - Квадратное изображение
  - Без прозрачности (или с белым фоном для adaptive icon)
  - Рекомендуется использовать формат PNG 32-bit

### Adaptive Icon (foreground)
- **Размер:** 1024×1024 px
- **Безопасная зона:** Центральные 512×512 px (контент не должен выходить за пределы)
- **Фон:** Белый (#FFFFFF) - указан в `pubspec.yaml`

### Автоматически генерируемые размеры
Пакет `flutter_launcher_icons` автоматически создаст иконки для следующих плотностей:

| Плотность | Размер | Директория |
|-----------|--------|------------|
| MDPI      | 48×48 px   | `mipmap-mdpi/ic_launcher.png` |
| HDPI      | 72×72 px   | `mipmap-hdpi/ic_launcher.png` |
| XHDPI     | 96×96 px   | `mipmap-xhdpi/ic_launcher.png` |
| XXHDPI    | 144×144 px | `mipmap-xxhdpi/ic_launcher.png` |
| XXXHDPI   | 192×192 px | `mipmap-xxxhdpi/ic_launcher.png` |

Также создаются adaptive icon файлы:
- `drawable-*/ic_launcher_foreground.png` (для разных плотностей)
- `mipmap-anydpi-v26/ic_launcher.xml` (конфигурация adaptive icon)

### Google Play Store
- **Размер:** 512×512 px (high-res icon)
- **Формат:** PNG
- Генерируется автоматически из исходного изображения

---

## 🍎 iOS

### Исходная иконка (source image)
- **Размер:** 1024×1024 px
- **Формат:** PNG
- **Путь:** `assets/icons/icon_01.png` (тот же файл, что и для Android)

### Автоматически генерируемые размеры

Пакет `flutter_launcher_icons` автоматически создаст все необходимые размеры для iOS:

| Размер (pt) | @1x | @2x | @3x | Применение |
|-------------|-----|-----|-----|------------|
| 20pt        | 20×20 | 40×40 | 60×60 | Notification (iOS 7+) |
| 29pt        | 29×29 | 58×58 | 87×87 | Settings (iOS 7+) |
| 40pt        | 40×40 | 80×80 | 120×120 | Spotlight (iOS 7+) |
| 60pt        | - | 120×120 | 180×180 | App Icon (iPhone) |
| 76pt        | 76×76 | 152×152 | - | App Icon (iPad) |
| 83.5pt      | - | 167×167 | - | App Icon (iPad Pro) |
| 1024pt      | 1024×1024 | - | - | App Store |

Все иконки создаются в директории:
`ios/Runner/Assets.xcassets/AppIcon.appiconset/`

---

## 📋 Инструкции по подготовке иконок

### Способ 1: Экспорт из Figma (рекомендуется)

1. **Откройте файл в Figma:**
   ```
   https://www.figma.com/design/TZYqJZyQtl31Zao6JC8GSl/GRANI?node-id=1050-374
   ```

2. **Выделите фрейм с иконкой** (node-id: 1050:374 — фирменная G)

3. **В правой панели найдите раздел 'Export'**

4. **Нажмите '+' для добавления параметров экспорта**

5. **Установите параметры:**
   - Format: **PNG**
   - Size: **1024×1024 px** (или 1x)
   - Можно также экспортировать 2x (2048×2048) для более высокого качества

6. **Нажмите 'Export' и сохраните файл как:**
   ```
   mobile-app/assets/icons/icon_01.png
   ```

### Способ 2: Использование скрипта (требует Figma API токен)

Если у вас есть Figma Personal Access Token:

```bash
# Установите токен (один раз)
export FIGMA_TOKEN="your-token-here"

# Экспортируйте иконку из макета (фон + иконка)
cd /path/to/grani
python3 scripts/figma_export_app_icon.py
# затем в mobile-app:
flutter pub run flutter_launcher_icons
```

Получить токен можно здесь: https://www.figma.com/developers/api#access-tokens

---

## 🚀 Генерация иконок после подготовки

После того, как файл `assets/icons/icon_01.png` готов:

### Для Android (текущая конфигурация)
```bash
cd mobile-app
flutter pub get
flutter pub run flutter_launcher_icons
```

### Для iOS (после включения в конфигурации)
Если нужно включить генерацию для iOS, обновите `pubspec.yaml`:
```yaml
flutter_launcher_icons:
  android: true
  ios: true  # изменить на true
  image_path: "assets/icons/icon_01.png"
  adaptive_icon_background: "#FFFFFF"
  adaptive_icon_foreground: "assets/icons/icon_01.png"
```

Затем запустите:
```bash
flutter pub run flutter_launcher_icons
```

---

## ✅ Проверка результата

### Android
Проверьте, что иконки созданы:
```bash
ls -la mobile-app/android/app/src/main/res/mipmap-*/ic_launcher.png
ls -la mobile-app/android/app/src/main/res/drawable-*/ic_launcher_foreground.png
```

### iOS
Проверьте, что иконки созданы:
```bash
ls -la mobile-app/ios/Runner/Assets.xcassets/AppIcon.appiconset/
```

---

## 📝 Примечания

1. **Безопасная зона для Android Adaptive Icon:**
   - Центральные 512×512 px из исходного изображения 1024×1024
   - Важные элементы должны находиться в этой зоне, чтобы не обрезались на разных устройствах

2. **Формат:**
   - Используйте PNG без прозрачности для основного изображения
   - Для Android adaptive icon фон может быть отдельным (сейчас используется цвет #FFFFFF)

3. **Качество:**
   - Используйте изображение высокого качества (1024×1024 минимум)
   - Можно использовать 2048×2048 для еще лучшего качества, но 1024×1024 достаточно

4. **Обновление иконок:**
   - После изменения `assets/icons/icon_01.png` всегда запускайте `flutter pub run flutter_launcher_icons`
   - Это пересоздаст все размеры для обеих платформ



