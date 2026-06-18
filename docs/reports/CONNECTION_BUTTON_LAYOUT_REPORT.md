# Отчёт: расположение кнопки подключения и текста (Trial / активная подписка)

**Дата:** 10 февраля 2026  
**Обновлено:** VpnCard удалён, используется ConnectionBlock с отступами по макету 39/53 px. Сверка с Figma выполнена.  
**Макет Figma:** [GRANI — node 562:732](https://www.figma.com/design/TZYqJZyQtl31Zao6JC8GSl/GRANI?node-id=562-732&m=dev)  
**Данные кнопки:** `docs/figma_connection_button_design.json` (node 939:555, состояния OFF/ON/CONNECTING/DISCONNECTING)

---

## 1. Текущие настройки в коде (после правок)

### 1.0 Заголовок и описание (Trial / Home)

По макету Figma 562:732, 939:555 блок trial_info (заголовок + подзаголовок) начинается **46 px** ниже верха контент-фрейма (после хедера). В коде используется `GraniTheme.trialTitleBlockTopGap = 46`: отступ от низа хедера до блока заголовка/описания = (12+39+12+46)*scaleY во всех состояниях (initial, disconnected, connecting, connected, disconnecting) на Trial и на Home.

### 1.1 Позиция блока подключения на экране

| Параметр | Trial (`trial_unified_screen.dart`) | Home (`home_screen.dart`) |
|----------|-------------------------------------|----------------------------|
| Привязка | `Positioned( bottom: …, left: … )` | То же |
| `bottom` | `GraniTheme.vpnCardBottomMargin * scaleY + safeBottom` = **12 * scaleY + safeBottom** | То же |
| `left` | `(screenWidth - GraniTheme.backgroundBoxWidth * scaleX) / 2` (ширина **372**) | То же |

Используется виджет **ConnectionBlock** (`lib/widgets/connection_block.dart`), без фиксированной высоты.

### 1.2 Размеры блока (ConnectionBlock)

| Параметр | Значение | Файл |
|----------|----------|------|
| Ширина | **372** * scaleX (`GraniTheme.backgroundBoxWidth`) | `connection_block.dart` |
| Высота | По контенту (без SizedBox 526) | — |

### 1.3 Вертикальный порядок и отступы по макету Figma

| Элемент | Отступ снизу после элемента | Константа в теме |
|---------|-----------------------------|------------------|
| Таймер («осталось: 10:00») | **16** * scaleY | — |
| Скорость («Скорость: 0 Мбит/с») | **39** * scaleY | `connectionBlockGapSpeedToButton` |
| Кнопка подключения (ButtonConnection) | **53** * scaleY | `connectionBlockGapButtonToControls` |
| Ряд «сервер + протокол» | — | Высота 30 * scaleY |

### 1.4 Кнопка подключения (ButtonConnection)

| Параметр | Значение | Источник |
|----------|----------|----------|
| Размер (внешний) | **205** × 205 | `GraniTheme.connectionButtonSize` |
| Текст OFF / CONNECTING / DISCONNECTING | **28** / **24** px, Montserrat **600**, цвет **#182D3D** | `connectionButtonLabelOffColor`, Figma 939:555 |
| Текст ON | **24** px, цвет **#02222F** | `connectionButtonLabelConnectedColor` |
| Выравнивание | По центру внутри кнопки | `button_connection.dart` |

### 1.5 Текст таймера и скорости (тема)

| Параметр | Значение |
|----------|----------|
| «осталось» | **18** px, Montserrat **400** |
| «Скорость» | **16** px, Montser **400** |

---

## 2. Данные из макета Figma

Источник: **figma_connection_button_design.json** (фрейм OFF, экран 412×917; координаты в пространстве файла).

Пересчёт **относительно верхней границы контентной зоны** (frame OFF: y = 2407, height = 655):

| Элемент | y (от верха frame) | Высота | Нижняя граница |
|---------|--------------------|--------|----------------|
| trial_info (заголовок «Тестовый период» и подзаголовок) | 46 | 125 | 171 |
| trial_status («осталось» + «Скорость») | **203.07** | **56** | **259.07** |
| connection_button | **298** | **205** | **503** |
| bottom_controls (сервер + протокол) | **556** | 30 | 586 |

### 2.1 Отступы по макету (Figma)

| Между блоками | Расчёт | Значение по макету |
|---------------|--------|---------------------|
| trial_status (низ) → connection_button (верх) | 298 − 259.07 | **≈ 39 px** |
| connection_button (низ) → bottom_controls (верх) | 556 − 503 | **53 px** |

### 2.2 Кнопка подключения в Figma

| Параметр | Figma (939:555, OFF) |
|----------|----------------------|
| Размер | 205 × 205 |
| Центрирование | x = 113.5 при ширине 412 → по центру (103.5 от левого края фрейма) |
| Текст «подключить» | 28 px, weight 600, цвет #182D3D |

Размер и типографика в приложении совпадают с макетом.

---

## 3. Сверка с Figma (выполнена)

- **ConnectionBlock:** отступы 39 и 53 px вынесены в тему (`connectionBlockGapSpeedToButton`, `connectionBlockGapButtonToControls`), ширина блока 372 (`backgroundBoxWidth`). Trial и Home используют одинаковую ширину, отступ от низа (12) и зазоры 39/53.
- **Кнопка (939:555):** размер 205, шрифт 28/24, weight 600, цвет метки OFF/CONNECTING/DISCONNECTING — **#182D3D** (`connectionButtonLabelOffColor`), ON — **#02222F** (`connectionButtonLabelConnectedColor`), stroke 12/7, цвета кольца (#2A6882, #E8AC89) — в теме совпадают с `figma_connection_button_design.json`.
- **Блок контента (562:732):** заголовок/подзаголовок и ширина 372 учтены; отступы 39/53 используются в ConnectionBlock.

---

## 4. Внесённые изменения (итог)

| Изменение | Файл |
|-----------|------|
| VpnCard удалён | `lib/widgets/vpn_card.dart` (файл удалён) |
| Добавлен ConnectionBlock с отступами 39/53 | `lib/widgets/connection_block.dart` |
| Константы 39, 53 и цвет метки #182D3D в теме | `lib/theme.dart` |
| Замена VpnCard на ConnectionBlock | `trial_unified_screen.dart`, `home_screen.dart`, `connecting_screen.dart` |
| Цвет текста кнопки OFF по Figma #182D3D | `lib/widgets/button_connection.dart` |

---

## 5. Рекомендации по дальнейшей проверке

1. Визуально сверить экраны Trial (все состояния), Home и экран подключения с макетом 562:732: отступы и положение кнопки относительно текста и ряда сервер/протокол.
2. При необходимости уточнить в Figma gap между строками «осталось» и «Скорость» (сейчас 16 px между ними) для блока trial_status 56 px.
