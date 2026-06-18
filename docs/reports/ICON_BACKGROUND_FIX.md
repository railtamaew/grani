# Исправление фоновых иконок

## Выполненные изменения

Обновлены виджеты для отображения фоновых изображений иконок:

1. **ProtocolSelectorButton** (`mobile-app/lib/widgets/protocol_selector_button.dart`)
   - Добавлена поддержка фонового изображения для иконки протокола
   - Добавлены тени для соответствия дизайну
   - Фоновое изображение: `assets/images/figma/protocol_icon_background.png`

2. **ServerSelectorButton** (`mobile-app/lib/widgets/server_selector_button.dart`)
   - Добавлена поддержка фонового изображения для иконки флага
   - Фоновое изображение: `assets/images/figma/flag_icon_background.png`

## Изображения

✅ **Изображения загружены:**

1. **Protocol icon background**
   - Файл: `mobile-app/assets/images/figma/protocol_icon_background.png`
   - URL из Figma: `https://www.figma.com/api/mcp/asset/868d3580-cff8-4077-8e9d-f20f0bfc9084`
   - Размер: 3.6KB (SVG формат)

2. **Flag icon background**
   - Файл: `mobile-app/assets/images/figma/flag_icon_background.png`
   - Использует тот же фон, что и протокол (одинаковый стиль в дизайне)
   - Размер: 3.6KB (SVG формат)

**Примечание:** Изображения в формате SVG, что обеспечивает хорошее качество на всех разрешениях.

## Fallback

Если изображения отсутствуют, виджеты будут использовать цветной фон (`GraniTheme.cardBackground`) с тенями, что соответствует базовому дизайну.

## Применено на всех экранах

Изменения автоматически применяются на всех экранах, где используются эти виджеты:
- `TrialStartScreen`
- `VpnDisconnectedTrialScreen`
- `VpnConnectedTrialScreen`
- Любые другие экраны, использующие `VpnCard` (который содержит эти виджеты)

