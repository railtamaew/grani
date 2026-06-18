# Плитка быстрых настроек (Quick Settings Tile)

Два состояния: **отключено** (`ic_tile.png`), **включено** (`ic_tile_active.png`).

Фон плитки и подпись «GRANI» задаёт система; приложению нужны **только иконки** (круг с буквой G). Скрипт экспортирует из Figma кадр плитки и обрезает его до области иконки (Ellipse 1).

Ресурсы в `app/src/main/res/drawable/`:

```bash
cd mobile-app
FIGMA_TOKEN=ваш_токен python3 scripts/export_quick_tile_from_figma.py
```

Ссылки: [node-id=1050-373](https://www.figma.com/design/TZYqJZyQtl31Zao6JC8GSl/GRANI?node-id=1050-373), [node-id=1050-374](https://www.figma.com/design/TZYqJZyQtl31Zao6JC8GSl/GRANI?node-id=1050-374).
