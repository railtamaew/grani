# Промпт: проверка и правка вёрстки по макету Figma

Ниже — **готовый промпт**, который можно копировать и передавать ассистенту. Ассистент по нему проверяет экран на несоответствия макету (градиенты, размеры, цвета, расположение, ассеты) и вносит правки или верстает.

---

## Краткая форма (подставить и отправить)

```
Проверь экран [Start Screen / Auth Email / …] на соответствие макету Figma и внеси правки. Экран в Figma: [516:295]. Файл: [mobile-app/lib/screens/start_screen.dart]. Правила: только данные из Figma API (токен в docs/figma_auth_data.json); проверить фон (в т.ч. градиент на корневом фрейме), размеры, цвета, расположение, типографику, ассеты по именам слоёв; скрипты figma_fetch_start_screen_design.py и figma_export_start_screen_assets.py (или аналог для экрана); правки в тему и экран по design JSON; сборку не запускать.
```

---

## Полный текст промпта (копировать)

```
Проверь экран [НАЗВАНИЕ_ЭКРАНА] на соответствие макету Figma и внеси правки.

Экран в Figma: [ID фрейма, например 516:295 для StartScreen].
Файл реализации: [путь, например mobile-app/lib/screens/start_screen.dart].

Правила:
1. Источник истины — только данные из макета Figma. Получать данные через Figma REST API (токен в docs/figma_auth_data.json или FIGMA_ACCESS_TOKEN). Не опираться на предположения.

2. Проверить и при необходимости исправить:
   - Фон: цвет или градиент. Градиент может быть на корневом фрейме (fills у узла экрана), а не только у backgroundBox. Парсить GRADIENT_LINEAR (gradientStops) и выводить в design JSON.
   - Размеры: ширина, высота, cornerRadius всех блоков и кнопок (из absoluteBoundingBox и cornerRadius в API).
   - Точные цвета: заливки (fills) у каждого элемента — hex из Figma. Для градиентов — цвета и stops.
   - Расположение: x, y, отступы между блоками (из absoluteBoundingBox и вычисленных gap).
   - Типографика: fontSize, fontWeight, letterSpacing, lineHeightPx, fontFamily, цвет текста (из style и fills у TEXT-узлов).
   - Ассеты: иконки и картинки искать по текущим именам слоёв в макете (Layers в Figma), не по старым именам или фиксированным node id. Скачивать через Figma Images API и сохранять в mobile-app/assets/images/figma/. Пути в коде менять только при смене имени файла.

3. Скрипты:
   - Данные макета (включая градиент с корневого фрейма): python3 scripts/figma_fetch_start_screen_design.py → docs/figma_start_screen_design.json. Для других экранов — добавить/адаптировать скрипт под node id экрана.
   - Координаты и отступы (логотип, textBlock, gap): python3 scripts/figma_fetch_layout.py (NODE_IDS должен включать id экрана).
   - Экспорт ассетов по именам слоёв: python3 scripts/figma_export_start_screen_assets.py (для стартового экрана) или аналог для других экранов.

4. После получения данных: обновить theme.dart (константы, градиенты, цвета) и экран во Flutter так, чтобы использовались только значения из design JSON или из вывода скриптов. Масштабирование — по design 412×917 (scaleX, scaleY).

5. Не запускать сборку, если не попросили отдельно — только правки кода и скриптов.
```

---

## Как подставлять значения

| Поле | Пример для стартового экрана | Для другого экрана |
|------|------------------------------|---------------------|
| НАЗВАНИЕ_ЭКРАНА | Start Screen (стартовый экран) | Auth Email, Auth Code, Trial Start, Home… |
| ID фрейма | 516:295 | 516:206, 517:387, 562:732… (из Figma или docs/figma_auth_data.json) |
| Файл реализации | mobile-app/lib/screens/start_screen.dart | mobile-app/lib/screens/auth_email_screen.dart и т.д. |

Список экранов и node id — в `docs/figma_auth_data.json` (поле `screens`) и в `docs/AUTH_FLOW_SCREENS_ACCESS.md`.

---

## Чеклист проверки (что именно сверять)

- [ ] **Фон** — цвет или линейный градиент; градиент с корневого фрейма (fills у 516:295 и т.п.), не только у дочернего backgroundBox.
- [ ] **Градиенты** — разбор type GRADIENT_LINEAR, gradientStops → colors_hex и stops в JSON; в коде LinearGradient с этими значениями.
- [ ] **Размеры** — width, height, cornerRadius кнопок/карточек/полей из absoluteBoundingBox и cornerRadius в API.
- [ ] **Цвета** — все заливки в hex из fills (SOLID → color_to_hex; градиент → gradient_to_design).
- [ ] **Расположение** — x, y, отступы (gap между логотипом и заголовком, между кнопками и т.д.) из bounds и скрипта figma_fetch_layout.
- [ ] **Типографика** — fontSize, fontWeight, letterSpacing, lineHeight, цвет из style и fills у TEXT-узлов.
- [ ] **Ассеты** — поиск по актуальным именам слоёв в макете (например "logo", не только "logoGrani"); экспорт в assets; путь в коде без смены, если имя файла не менялось.

---

## Порядок для нескольких экранов

1. **Стартовый экран** — уже настроены скрипты и design JSON; проверять по промпту выше.
2. **Остальные экраны (Auth Email, Auth Code, Trial, Home…):**
   - Добавить node id экрана в скрипт получения данных (или создать отдельный скрипт по аналогии с `figma_fetch_start_screen_design.py`). Для **Auth Email** (516:206): `python3 scripts/figma_fetch_auth_email_design.py` → `docs/figma_auth_email_design.json`. Для **Auth Code** (516:223): `python3 scripts/figma_fetch_auth_code_design.py` → `docs/figma_auth_code_design.json`. Для **Trial Unified** (562:732): `python3 scripts/figma_fetch_trial_unified_design.py` → `docs/figma_trial_unified_design.json`. Для **кнопки подключения** (939:555): `python3 scripts/figma_fetch_connection_button_design.py` → `docs/figma_connection_button_design.json`.
   - Вывести design JSON для этого экрана (например `docs/figma_auth_email_design.json`).
   - Добавить экспорт ассетов по именам слоёв этого фрейма (по аналогии с `figma_export_start_screen_assets.py`).
   - Проверить по чеклисту и внести правки в тему и экран.

Передавай промпт с подставленным названием экрана, node id и путём к файлу — ассистент выполнит проверку и правки по макету.
