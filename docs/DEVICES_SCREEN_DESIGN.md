# Экран «Мои устройства» — данные вёрстки и макета

Макет Figma: [GRANI, node 1143-193](https://www.figma.com/design/TZYqJZyQtl31Zao6JC8GSl/GRANI?node-id=1143-193)

---

## 1. Ассеты

### Кастомные ассеты из Figma (для этого экрана)

**Нет.** Экран «Мои устройства» не использует отдельные PNG/SVG, экспортированные из Figma.

| Ресурс | Источник |
|--------|----------|
| Иконки платформ (Android, iOS, Windows) | Material Icons (`Icons.android`, `Icons.apple`, `Icons.desktop_windows`, `Icons.devices_other`) |
| Иконка «Назад» | `Icons.arrow_back` |
| Иконка «Устройства» (пустое состояние) | `Icons.devices_other` |
| Шрифты | `Montserrat` (assets/fonts/) |

### Общие ассеты проекта (используемые на экране)

- `fonts/Montserrat-Regular.ttf`
- `fonts/Montserrat-Medium.ttf`
- `fonts/Montserrat-SemiBold.ttf`
- `fonts/Montserrat-Bold.ttf`
- `fonts/Montserrat-Light.ttf`

---

## 2. Размеры и отступы

### Фон экрана

| Параметр | Значение | Комментарий |
|----------|----------|-------------|
| Градиент | white → #F7F9FA | `GraniTheme.devicesScreenBackgroundGradient` |

### AppBar

| Параметр | Значение | Комментарий |
|----------|----------|-------------|
| Заголовок «Мои устройства» | `fontSize: 24`, `fontWeight: 600` | GraniTheme.bodyMedium |
| Elevation | `0` | Без тени |
| Фон | `Colors.transparent` | Градиент в родителе |

### Блок лимита

| Параметр | Значение | Комментарий |
|----------|----------|-------------|
| Padding | `16, 8, 16, 0` (LTRB) | EdgeInsets.fromLTRB |
| Основной текст | `fontSize: 14`, `fontWeight: 300` | «Подключено» и «устройств» |
| Счётчик X/Y | `fontSize: 20`, `fontWeight: 500`, цвет по состоянию | см. цвета ниже |
| Подсказка | `fontSize: 14`, `fontWeight: 300`, secondaryText | «Если вы сменили телефон…» |
| Ошибка лимита | `fontSize: 14` | «Лимит превышен…» |
| Gap между строками | `8` | SizedBox(height: 8) |

### Карточка устройства (DeviceCard)

| Параметр | Значение | Комментарий |
|----------|----------|-------------|
| Margin снизу | `12` | EdgeInsets.only(bottom: 12) |
| Border radius | `25` | GraniTheme.profileCardRadius |
| Тень | `buttonShadowStandard` | Единые подложки проекта |
| Padding внутри | `16` | EdgeInsets.all |
| Контейнер иконки | `44 × 44` | Круг с radius 25 |
| Иконка платформы | `22` | size |
| Отступ иконка ↔ текст | `12` | SizedBox(width: 12) |
| Название | `fontSize: 14`, `fontWeight: 700`, primaryText | bold |
| Подпись | `fontSize: 10`, Light | «Активно сейчас» (зелёный) для текущего |
| Кнопка «Это устройство» | padding `10, 8`, radius `5`, border #DCE1E6 | outline |
| Кнопка «Удалить» | padding `10, 8`, radius `5` | outline |

### Список карточек

| Параметр | Значение | Комментарий |
|----------|----------|-------------|
| Padding | `16, 16, 16, 24` | SliverPadding |
| Анимация удаления | `duration: 280 ms` | fade + size collapse |

---

## 3. Радиусы скругления

| Элемент | Значение | GraniTheme |
|---------|----------|------------|
| Карточка устройства | 25 | `profileCardRadius` |
| Контейнер иконки платформы | 25 | |
| Кнопка «Это устройство» | 5 | border outline |
| Кнопка «Удалить» / «Подтвердить» | 5 | |

---

## 4. Цвета

Источник: `lib/theme.dart` (GraniTheme).

### Основные

| Переменная | Hex | Использование |
|------------|-----|---------------|
| `primaryBackground` | #F7F4F8 | Фон Scaffold |
| `cardBackground` | #F4F6F8 | Фон карточки устройства |
| `primaryText` | #192F3F | Заголовок, название устройства |
| `secondaryText` | #A4ACB5 | Подпись, подсказка |

### Лимит устройств

| Состояние | Переменная | Hex |
|-----------|------------|-----|
| X < limit | `successGreen` | #2EC07E |
| X == limit | `devicesCountOrange` | #EF7F34 |
| X > limit | `deviceLimitIndicatorRed` | #FF1904 |

### Кнопка удаления

| Переменная | Hex | Использование |
|------------|-----|---------------|
| `deviceLimitErrorText` | #DC2626 | Текст кнопки «Удалить» |
| `deviceLimitErrorBg` | #FEE2E2 | Подсветка в режиме подтверждения |
| `deviceLimitDeleteBorder` | #FCA5A5 | Рамка кнопки |

### Кнопка «Это устройство»

| Переменная | Hex |
|------------|-----|
| `deviceLimitThisDeviceBorder` | #DCE1E6 (border) |
| `deviceLimitBadgeCurrent` | #40484F (текст) |

### «Активно сейчас» (текущее устройство)

| Переменная | Hex |
|------------|-----|
| `devicesActiveNowGreen` | #48B14C |

### Тень карточки

| Параметр | Значение |
|----------|----------|
| Источник | `GraniTheme.buttonShadowStandard` |

---

## 5. Figma node-id экрана

- **Файл**: TZYqJZyQtl31Zao6JC8GSl (GRANI)
- **Узел экрана**: 1143-193

---

## 6. Использованные токены/константы темы

```dart
GraniTheme.devicesScreenBackgroundGradient
GraniTheme.cardBackground
GraniTheme.primaryText
GraniTheme.secondaryText
GraniTheme.successGreen
GraniTheme.devicesCountOrange
GraniTheme.devicesActiveNowGreen
GraniTheme.deviceLimitErrorText
GraniTheme.deviceLimitErrorBg
GraniTheme.deviceLimitDeleteBorder
GraniTheme.deviceLimitIndicatorRed
GraniTheme.deviceLimitBadgeCurrent
GraniTheme.deviceLimitThisDeviceBorder
GraniTheme.buttonShadowStandard
GraniTheme.profileCardRadius
GraniTheme.bodyMedium
GraniTheme.bodySmall
```

## 7. Сортировка устройств

- Текущее устройство — первым в списке
- Остальные — по убыванию `last_seen` (самые недавние сверху)

---

## 8. Анимация удаления

- **Тип**: `FadeTransition` + `SizeTransition`
- **Длительность**: 280 ms
- **Механика**: при успешном удалении карточка исчезает (fade out) и сжимается по высоте (size collapse), затем счётчик лимита обновляется.
