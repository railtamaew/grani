# Анализ размера APK и сборка

## Анализ размера (analyze-size)

Перед изменениями зависимостей или ассетов рекомендуется зафиксировать текущий размер и дерево:

```bash
cd mobile-app
flutter build apk --analyze-size --target-platform android-arm64
```

Отчёт выводится в консоль; при необходимости сохраните вывод в файл:

```bash
flutter build apk --analyze-size --target-platform android-arm64 2>&1 | tee apk_size_report.txt
```

Интерпретация:
- **Dart** — код приложения и пакетов; смотреть на крупные пакеты при добавлении зависимостей.
- **Native libs** — нативные библиотеки (Xray, WireGuard и т.д.); обычно не уменьшаются без смены протоколов.
- **Assets** — шрифты, изображения, прочие ресурсы; кандидаты на оптимизацию (WebP, удаление неиспользуемого).

## Рекомендации

- При добавлении новых зависимостей — пересобрать с `--analyze-size` и проверить прирост.
- В CI (если будет) можно добавить шаг сборки с `--analyze-size` и проверку порога размера.

## Текущая release-конфигурация (android/app/build.gradle)

- `minifyEnabled true` — включён ProGuard/R8.
- `shrinkResources true` — удаление неиспользуемых ресурсов.
- `abiFilters 'arm64-v8a'` — только 64-bit ARM (один ABI для уменьшения размера).

Исключения в ProGuard добавлять только при необходимости (краши из-за обфускации).

## Аудит ассетов

Каталоги: `assets/images/`, `assets/images/figma/`, `assets/icons/`.

Используемые в коде (по grep): logo_grani_new.png, pic1_welcome_babushka.png, google_logo.png, button_connecting.png, screen2_connecting.png, menu_icon.png, share_icon.png, email_icon.png, pic1_profile.png, telegram_icon.png, payment_failed_icon_only.svg, pic_success.png, logo_new.svg. Иконка приложения: assets/icons/icon_01.png (flutter_launcher_icons).

Рекомендации: удалять файлы из figma/ и images/, которые не встречаются в коде; тяжёлые PNG при необходимости конвертировать в WebP (Flutter поддерживает Image.asset('...webp')); оставить только нужные начертания Montserrat в pubspec.
