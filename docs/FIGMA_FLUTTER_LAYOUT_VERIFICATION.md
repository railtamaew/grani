# Проверка реализации экранов по универсальному промпту вёрстки (Figma → Flutter, GRANI)

Экраны: **StartScreen**, **AuthEmailScreen**, **AuthCodeScreen**.

---

## 1. Язык и стек

| Критерий | Статус |
|----------|--------|
| Код на Dart, Flutter | OK — все три экрана в `.dart`, импорт `flutter/material.dart`. |

---

## 2. Порядок работы с Figma MCP

| Критерий | Статус |
|----------|--------|
| get_design_context → get_screenshot → код | Не проверяется по коду (процесс вёрстки). В коде есть комментарии с node-id макета (516:295, 516:206, 516:223). |

---

## 3. Выбор узлов в Figma

| Критерий | Статус |
|----------|--------|
| Выбирать компоненты/блоки, а не целый экран | В коде используются целые экраны (516:295, 516:206, 516:223) для координат и отступов. Отдельные блоки вынесены во виджеты: `AuthLogo`, `AuthTextBlock`, кнопки. Для точечных правок по макету можно вызывать MCP по дочерним узлам. |

---

## 4. Layout во Flutter

| Экран | Column/Row/Stack + Positioned | Тени из темы |
|-------|-------------------------------|--------------|
| StartScreen | OK — `Stack` + `Positioned` (navigation bar, AuthLogo, AuthTextBlock, блок кнопок). Внутри — `Column` для кнопок. | OK — `GraniTheme.buttonShadowStandard` на кнопках. |
| AuthEmailScreen | OK — `Column` (зона A логотип, `Expanded` + `SingleChildScrollView` с `Column` внутри). | OK — `GraniTheme.inputFieldShadow`, `GraniTheme.primaryButtonShadowWithInset`. |
| AuthCodeScreen | OK — `Column` (зона A логотип, `Expanded` + `SingleChildScrollView` с `Column`). | OK — `GraniTheme.cardShadowWithInset` на PIN-карточке. |

---

## 5. Единый источник стилей (GraniTheme)

| Критерий | Статус |
|----------|--------|
| Цвета, типографика, отступы только из темы | OK — градиент `GraniTheme.backgroundGradient`, отступы `authScreenHorizontalPadding`, `logoWidth`/`logoHeight`, `titleSubtitleGap`, `inputFieldWidth`, `buttonHeight`, `radiusButton`, `paddingXLarge`, `buttonIconSize`, `buttonIconGap`, стили текста `headingLarge`, `bodyLarge`, `buttonTextSecondary`, `buttonTextMedium`, `privacyLinkText`, `emailInputText`, `emailPlaceholder` и т.д. |
| Нет хардкода hex/fontSize в экранах | OK — прямых `Color(0x...)` / `Colors.grey` на этих экранах нет. Размеры шрифтов задаются как `40 * scaleX`, `16 * scaleX` и т.д. с базой из макета; стили берутся из темы (`.copyWith(fontSize: ...)`). |

---

## 6. Шрифты и ассеты

| Критерий | Статус |
|----------|--------|
| Montserrat в теме | OK — в `theme.dart`: `fontFamily: 'Montserrat'` в теме и в текстовых стилях. |
| Montserrat в pubspec | Замечание — в `pubspec.yaml` секция `fonts:` отсутствует. Если шрифт не подключён через pubspec, на устройстве может подставляться системный. Рекомендация: добавить в `flutter.fonts` путь к файлам Montserrat (например, в `assets/fonts/`). |
| Ассеты из макета | OK — пути к ассетам локальные: `assets/images/figma/logo_grani_new.png`, `email_icon.png`, `google_logo.png`. Нет localhost/плейсхолдеров. |

---

## 7. Когда использовать MCP Figma

| Критерий | Статус |
|----------|--------|
| get_design_context, get_screenshot, get_metadata, get_variable_defs | Использование MCP не отражено в коде; при дальнейших правках по макету вызывать MCP по нужным узлам (компоненты/блоки) для контекста и скриншотов. |

---

## 8. Когда использовать токен (скрипты)

| Критерий | Статус |
|----------|--------|
| Координаты и отступы | OK — значения logoToTitleGap (217, 290) и размеры из макета зафиксированы в коде и в `scripts/README_FIGMA_LAYOUT.md`; скрипт `figma_fetch_layout.py` используется для получения координат. |
| Экспорт ассетов | OK — логотип экспортируется через `scripts/figma_export_logo.py` в `logo_grani_new.png`. |

---

## 9. Чеклист при обновлении по макету

| Критерий | Статус |
|----------|--------|
| Картинки/иконки — экспорт и замена в assets/ | OK — логотип обновляется скриптом; иконки email и Google лежат в `assets/images/figma/`. При изменении в Figma их нужно переэкспортировать и заменить файлы. |
| Отступы, размеры, цвета — константы/тема + scaleX/scaleY | OK — designWidth 412, designHeight 917, scaleX/scaleY применяются; отступы и размеры из темы или локальных констант по макету. |

---

## 10. Разделение «верстаю по макету» и «надо скачать и заменить»

| Тип | Реализация |
|-----|------------|
| Числа (позиции, отступы, размеры) | В коде/теме: logoToTitleGap, authScreenHorizontalPadding, logoWidth/Height, масштабирование 412×917. |
| Картинки/иконки | Файлы в `assets/images/figma/`; логотип обновляется скриптом экспорта. Пути в коде не меняются при замене файла. |

---

## 11. Иконки и картинки при переверстке экрана (новый пункт промпта)

При переверстке экрана по макету старые ресурсы **не оставлять**: список ресурсов определить по макету (get_design_context / get_metadata), старые файлы удалить или заменить, новые экспортировать из того же узла Figma.

**Ассеты по экранам (для чеклиста переверстки):**

| Экран | Figma node | Файлы в assets (экспорт из того же макета) |
|-------|------------|--------------------------------------------|
| StartScreen | 516:295 | `logo_grani_new.png`, `google_logo.png`, `email_icon.png` |
| AuthEmailScreen | 516:206 | `logo_grani_new.png`, `email_icon.png` |
| AuthCodeScreen | 516:223 | `logo_grani_new.png` |
| TrialEndedScreen | 562:488 | `menu_icon.png`, `logo_grani_new.png`, `share_icon.png` |

Логотип общий для нескольких экранов; при переверстке любого из них логотип брать из соответствующего фрейма макета (562:488 для TrialEndedScreen) и перезаписывать `assets/images/figma/logo_grani_new.png` (или обновить скрипт экспорта под нужный node).

| Критерий | Статус |
|----------|--------|
| Ресурсы экрана экспортируются из того же макета, по которому верстаем | OK — логотип экспортирован скриптом из StartScreen; иконки в `figma/` используются по путям. При следующей переверстке: явно экспортировать/заменить все файлы из таблицы выше. |

---

## Итог

- **Соответствует промпту:** язык Dart/Flutter, layout (Column/Row/Stack + Positioned), тени из темы, стили и отступы из GraniTheme, масштабирование по макету 412×917, экспорт логотипа скриптом, разделение чисел и ассетов. Пункт «иконки и картинки при переверстке» зафиксирован в правиле и в таблице ассетов по экранам.
- **Рекомендация:** добавить в `pubspec.yaml` секцию `fonts:` и подключить Montserrat (например, из `assets/fonts/`), чтобы шрифт гарантированно совпадал с макетом на всех устройствах.
- **При следующей переверстке любого из трёх экранов:** по правилу — получить контекст по узлу макета, экспортировать и заменить все картинки/иконки этого экрана из того же макета (см. таблицу в п. 11), затем править код.
