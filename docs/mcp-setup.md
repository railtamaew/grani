# Настройка MCP сервера

## Конфигурация

MCP (Model Context Protocol) сервер настроен в файле: `/root/.cursor/mcp.json`

### Текущая конфигурация:

```json
{
  "mcpServers": {
    "local-mcp": {
      "url": "http://127.0.0.1:3845/mcp",
      "transport": "http"
    }
  }
}
```

## Проверка доступности

### Проверка порта:
```bash
# Проверка доступности порта
curl -v http://127.0.0.1:3845/mcp

# Или через netstat/ss
netstat -tlnp | grep 3845
ss -tlnp | grep 3845
```

### Проверка подключения:
```bash
# Тест HTTP запроса
curl -X GET http://127.0.0.1:3845/mcp -H "Content-Type: application/json"
```

## Запуск MCP сервера

Если сервер не запущен, убедитесь что:
1. MCP сервер запущен на порту 3845
2. Сервер доступен по адресу `http://127.0.0.1:3845/mcp`
3. Нет блокировки файрвола для порта 3845

## Перезагрузка конфигурации

После изменения конфигурации MCP:
1. Перезапустите Cursor
2. Или перезагрузите MCP подключение через настройки Cursor

## Дополнительные настройки

Для добавления других MCP серверов, добавьте их в секцию `mcpServers`:

```json
{
  "mcpServers": {
    "local-mcp": {
      "url": "http://127.0.0.1:3845/mcp",
      "transport": "http"
    },
    "figma": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-figma"
      ],
      "env": {
        "FIGMA_PERSONAL_ACCESS_TOKEN": "FIGMA_PERSONAL_ACCESS_TOKEN"
      }
    }
  }
}
```

## Настройка MCP Figma

### Токен настроен:
- **Token:** `FIGMA_PERSONAL_ACCESS_TOKEN`
- **File Key:** `TZYqJZyQtl31Zao6JC8GSl`

### Доступные страницы:
1. **Auth Flow:** `515:201` ✅
2. **VPN Flow:** `562:732` ✅
3. **Документация:** `574:811` ✅

### Конфигурация для Cursor:

Файл конфигурации находится в:
- Linux: `~/.config/Cursor/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json`
- Windows: `%APPDATA%\Cursor\User\globalStorage\saoudrizwan.claude-dev\settings\cline_mcp_settings.json`
- Mac: `~/Library/Application Support/Cursor/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json`

Добавьте конфигурацию Figma (см. выше) и перезапустите Cursor.



