# Корректировка стартового экрана по данным Figma

Подход: **несоответствия выявляем по скриншоту, исправления вносим только по данным макета Figma.** Данные получаем по REST API (токен), SVG и картинки экспортируем на сервер, затем проверяем.

## 1. Токен Figma

- Задать в `docs/figma_auth_data.json` поле `figma_token`, **или**
- Переменная окружения: `export FIGMA_ACCESS_TOKEN="figd_..."`

## 2. Получение данных макета (только из Figma)

```bash
python3 scripts/figma_fetch_start_screen_design.py
```

- Запрашивает у Figma узел **516:295** (start_screen), разбирает fills, bounds, стили текста, кнопок, ссылок.
- Результат: **docs/figma_start_screen_design.json** (цвета, размеры, отступы, типографика).

Дополнительно для координат логотипа и отступа до заголовка:

```bash
python3 scripts/figma_fetch_layout.py
```

- Считает `logoToTitleGap`, bounds логотипа и textBlock по макету.

## 3. Экспорт ассетов (SVG и картинки на сервер)

```bash
python3 scripts/figma_export_start_screen_assets.py
```

- Экспортирует из frame 516:295: логотип (по id 516:306), иконку Google, иконку Email.
- Сохраняет в **mobile-app/assets/images/figma/** (google_logo.png, email_icon.png; logo при наличии URL в API).
- При необходимости логотип отдельно: `python3 scripts/figma_export_logo.py`.

## 4. Обновление кода только по данным Figma

- **theme.dart** и **start_screen.dart** используют значения из:
  - **docs/figma_start_screen_design.json** (кнопки, заголовок, подзаголовок, ссылки, отступы),
  - вывода **figma_fetch_layout.py** (логотип 37×48, y 74.4, logoToTitleGap 217).
- Не вносить в макет «от себя»: цвета, размеры, отступы — только из этих источников.

## 5. Проверка

- Сборка: `cd mobile-app && flutter build apk` (или `flutter run`).
- Визуальная сверка со скриншотом макета Figma (start_screen 516:295).

## Файлы

| Файл | Назначение |
|------|------------|
| docs/figma_auth_data.json | file_key, figma_token (или пусто при использовании env) |
| docs/figma_start_screen_design.json | Данные макета стартового экрана (генерируется скриптом) |
| scripts/figma_fetch_start_screen_design.py | Получение дизайн-данных по API |
| scripts/figma_export_start_screen_assets.py | Экспорт картинок/иконок в assets |
| scripts/figma_fetch_layout.py | Координаты и logoToTitleGap |
