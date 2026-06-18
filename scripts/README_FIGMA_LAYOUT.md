# Получение координат из Figma для вёрстки (logoToTitleGap и др.)

Скрипт `figma_fetch_layout.py` вызывает Figma REST API, получает `absoluteBoundingBox` для узлов экранов и считает отступ от логотипа до заголовка (logoToTitleGap).

## Вариант 1: вызов API и просмотр координат

Запуск скрипта выводит сырые данные по узлам (координаты, размеры):

```bash
cd /opt/grani
export FIGMA_ACCESS_TOKEN="ваш_токен"   # или скрипт возьмёт из docs/figma_auth_data.json
pip install requests
python3 scripts/figma_fetch_layout.py
```

В выводе будет JSON с `absoluteBoundingBox` (x, y, width, height) для фреймов и найденных элементов (логотип, textBlock/title_block).

## Вариант 2: отступы по экранам (logoToTitleGap)

В конце вывода скрипт печатает блок «Рекомендуемые отступы» в пикселях по каждому экрану. **Общего logoToTitleGap в теме нет** — отступ задаётся по макету на каждом экране отдельно:

- **StartScreen** (`start_screen.dart`): локальная константа `logoToTitleGap = 217.0` (по макету 516:295).
- **AuthEmailScreen** (`auth_email_screen.dart`): `logoToTitleGap = 290.0` (по макету 516:206).
- **AuthCodeScreen** (`auth_code_screen.dart`): локальная константа `logoToTitleGap = 290.0` (по макету 516:223).

При изменении макета запустите скрипт и обновите соответствующую константу в файле экрана.

## Верификация вёрстки (516:223, AuthCodeScreen)

После запуска скрипта с токеном сверьте с макетом и кодом:

| Параметр | Figma (скрипт / MCP) | Код |
|----------|----------------------|-----|
| logoToTitleGap | 290 px | `auth_code_screen.dart`: `logoToTitleGap = 290.0` |
| Горизонтальный отступ | titleBlock x=32 | `GraniTheme.authScreenHorizontalPadding` (32) |
| Ширина блока заголовка | 352 px | растягивается по ширине минус padding |
| Логотип | 37×48 px | `GraniTheme.logoWidth` / `logoHeight` |
| Текст ошибки | «Неверный код, попробуйте ещё раз» | `ErrorMessage` в PIN-карточке |

Макет также можно проверить через Figma MCP: `get_design_context` и `get_screenshot` для node 516:223.

## Токен

- Предпочтительно: задать переменную окружения `FIGMA_ACCESS_TOKEN`, чтобы не хранить токен в репозитории.
- Иначе скрипт читает `docs/figma_auth_data.json` и поле `figma_token`.

При ошибке **403 Forbidden** проверьте: токен не истёк (Figma → Settings → Personal access tokens) и у аккаунта есть доступ к файлу GRANI.

## Узлы

Скрипт запрашивает узлы:

- `516:295` — StartScreen
- `516:206` — AuthEmailScreen (ввод email)
- `516:223` — AuthCodeScreen (ввод PIN-кода)

Ищет по имени: логотип (`logoGrani`, `logo_grani_new 1`), блок заголовка (`textBlock`, `title_block`), считает gap = y_заголовка − (y_лого + height_лого).

## Экспорт логотипа из Figma

Актуальный логотип для экранов Start, AuthEmail, AuthCode экспортируется скриптом:

```bash
export FIGMA_ACCESS_TOKEN="ваш_токен"
python3 scripts/figma_export_logo.py
```

Скрипт сохраняет PNG в `mobile-app/assets/images/figma/logo_grani_new.png`. Все три экрана используют этот ассет; после обновления логотипа в Figma перезапустите скрипт.

## Экран «Мои устройства» (1143:193)

Скрипт `figma_fetch_devices_design.py` получает данные макета DevicesScreen и сохраняет в `docs/figma_devices_design.json`:

```bash
export FIGMA_ACCESS_TOKEN="ваш_токен"
python3 scripts/figma_fetch_devices_design.py
```

Данные: размеры карточек (371×50), cornerRadius 25, fill #F4F6F8, типографика, title_to_connected_gap и др.

## Добавление экранов

В `figma_fetch_layout.py` в список `NODE_IDS` добавьте нужный node-id из Figma (формат `"516:206"`). При необходимости расширьте `LOGO_NAMES` или `TITLE_BLOCK_NAMES` под имена слоёв в макете.
