# Инструкция по развертыванию админ-панели на https://granilink.com/admin

## Текущая ситуация

Конфигурация nginx обновлена в файле `/opt/grani/server-config/nginx/nginx.conf`:
- Добавлен location `/admin` для проксирования на Netlify (spectacular-begonia-477baa.netlify.app)

## Шаги для применения изменений

### 1. Найти активную конфигурацию nginx

```bash
# Проверить, где находится nginx
which nginx
ps aux | grep nginx
docker ps | grep nginx

# Проверить конфигурационные файлы
find /etc/nginx -name "*.conf" -type f 2>/dev/null
find /etc/nginx -name "*granivpn*" 2>/dev/null
```

### 2. Применить изменения в nginx

Если nginx в системе:
```bash
# Скопировать конфигурацию
sudo cp /opt/grani/server-config/nginx/nginx.conf /etc/nginx/nginx.conf

# Проверить конфигурацию
sudo nginx -t

# Перезагрузить nginx
sudo systemctl reload nginx
# или
sudo service nginx reload
```

Если nginx в Docker:
```bash
# Обновить конфигурацию в контейнере
docker cp /opt/grani/server-config/nginx/nginx.conf <nginx_container>:/etc/nginx/nginx.conf

# Перезагрузить контейнер
docker exec <nginx_container> nginx -s reload
```

### 3. Проверить доступность

```bash
# Проверить через curl
curl -I https://granilink.com/admin

# Должен вернуть HTTP 200 или 301/302 редирект
```

### 4. Важные моменты

1. **Конфигурация /admin:**
   ```nginx
   location /admin {
       proxy_pass https://spectacular-begonia-477baa.netlify.app;
       proxy_set_header Host spectacular-begonia-477baa.netlify.app;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       proxy_set_header X-Forwarded-Proto $scheme;
       proxy_ssl_verify off;
   }
   ```

2. **Важно:** Админ-панель должна быть задеплоена на Netlify с правильным base path.

3. **CORS:** Убедиться, что backend API разрешает запросы с `https://granilink.com`

4. **API URL:** В админ-панели должен быть настроен правильный API URL (https://granilink.com/api)

## Альтернативный вариант: прямой деплой на сервер

Если Netlify недоступен, можно развернуть админ-панель напрямую на сервере:

```bash
cd /opt/grani/admin-panel
npm run build
sudo cp -r build/* /var/www/granivpn/admin/

# В nginx:
location /admin {
    alias /var/www/granivpn/admin;
    try_files $uri $uri/ /admin/index.html;
}
```

## Проверка после развертывания

1. ✅ https://granilink.com/admin открывается
2. ✅ Страница логина отображается
3. ✅ API запросы идут на https://granilink.com/api/admin/auth/login
4. ✅ Можно войти с учетными данными Owner

## Учетные данные

- Email: rail.tamaew@gmail.com
- Пароль: ChangeThisPassword123! (⚠️ изменить после первого входа)



