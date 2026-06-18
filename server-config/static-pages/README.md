# Статические страницы (публичный сайт)

Содержимое этой папки нужно развернуть на сервере в `/var/www/granivpn/static-pages/`, чтобы nginx отдавал страницы по соответствующим URL.

## Размещённые страницы

| URL | Файл | Назначение |
|-----|------|------------|
| `/privacy` | `privacy.html` | Политика конфиденциальности |
| `/privacy.html` | `privacy.html` | То же (альтернативная ссылка) |

## Деплой на сервер

```bash
# На сервере (или через rsync/scp с локальной машины)
sudo mkdir -p /var/www/granivpn/static-pages
sudo cp -r /path/to/grani/server-config/static-pages/* /var/www/granivpn/static-pages/
sudo chown -R www-data:www-data /var/www/granivpn/static-pages
```

После обновления конфига nginx перезагрузить его: `sudo nginx -t && sudo systemctl reload nginx`.

## Ссылки для размещения

- **Политика конфиденциальности (основная):**  
  `https://granilink.com/privacy`  
  или на основном домене: `https://granilink.com/privacy` (если домен настроен в nginx)

- **Альтернативная:**  
  `https://granilink.com/privacy.html`

В приложении и на сайте используйте одну из этих ссылок для пункта «Подробнее о конфиденциальности» и для магазинов приложений (App Store / Google Play).
