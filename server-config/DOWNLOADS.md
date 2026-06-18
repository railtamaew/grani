# Скачивание релизов приложения (APK)

На api.granilink.com настроена раздача APK по пути `/downloads/`.

## Ссылка

- **Release APK (64-bit):**  
  https://api.granilink.com/downloads/app-release.apk

## Деплой на сервер

Каталог на сервере: `/var/www/granivpn/downloads/`. Nginx отдаёт файлы из него по запросу к `https://api.granilink.com/downloads/<имя_файла>`.

```bash
# Создать каталог (один раз)
sudo mkdir -p /var/www/granivpn/downloads

# Скопировать APK после сборки (с машины, где собирали Flutter)
scp mobile-app/build/app/outputs/flutter-apk/app-release.apk user@server:/tmp/
# На сервере:
sudo cp /tmp/app-release.apk /var/www/granivpn/downloads/app-release.apk

# Права
sudo chown -R www-data:www-data /var/www/granivpn/downloads
```

После изменения конфига nginx: `sudo nginx -t && sudo systemctl reload nginx`.

## Конфиг nginx

Блок `location /downloads/` добавлен в `server-config/nginx/granivpn-servers.conf` для сервера `api.granilink.com`. При деплое убедитесь, что этот конфиг подключён на хосте.
