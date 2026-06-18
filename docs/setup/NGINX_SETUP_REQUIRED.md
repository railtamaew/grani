# ⚠️ ТРЕБУЕТСЯ НАСТРОЙКА NGINX НА СЕРВЕРЕ

## Проблема

Конфигурация nginx обновлена локально, но **требуется применить изменения на продакшен-сервере**.

## Что нужно сделать

### Вариант 1: Использовать готовый скрипт (рекомендуется)

На сервере выполните:

```bash
cd /opt/grani
sudo bash server-config/apply-admin-nginx.sh
```

### Вариант 2: Ручная настройка

1. **Подключитесь к серверу по SSH**

2. **Найдите конфигурацию nginx для granilink.com:**
   ```bash
   sudo find /etc/nginx -name "*.conf" -exec grep -l "granilink.com" {} \;
   ```

3. **Добавьте location /admin в server блок для granilink.com:**

   Найдите блок:
   ```nginx
   server {
       listen 443 ssl http2;
       server_name granilink.com www.granilink.com;
       ...
   }
   ```

   Добавьте перед `location /`:
   ```nginx
   location /admin {
       proxy_pass https://spectacular-begonia-477baa.netlify.app;
       proxy_set_header Host spectacular-begonia-477baa.netlify.app;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       proxy_set_header X-Forwarded-Proto $scheme;
       proxy_ssl_verify off;
       proxy_redirect off;
       proxy_connect_timeout 60s;
       proxy_send_timeout 60s;
       proxy_read_timeout 60s;
   }
   ```

4. **Проверьте конфигурацию:**
   ```bash
   sudo nginx -t
   ```

5. **Перезагрузите nginx:**
   ```bash
   sudo systemctl reload nginx
   # или
   sudo service nginx reload
   ```

### Вариант 3: Использовать готовый файл конфигурации

Готовая конфигурация находится в: `/opt/grani/server-config/nginx/nginx.conf`

Скопируйте её:
```bash
sudo cp /opt/grani/server-config/nginx/nginx.conf /etc/nginx/nginx.conf
sudo nginx -t
sudo systemctl reload nginx
```

## Проверка после настройки

1. **Проверьте доступность:**
   ```bash
   curl -I https://granilink.com/admin
   ```

2. **Откройте в браузере:**
   - URL: https://granilink.com/admin
   - Должна открыться страница логина админ-панели

## Важные моменты

- ⚠️ **Важно:** location `/admin` должен быть **перед** location `/` (иначе `/` перехватит все запросы)
- ⚠️ **CORS:** Убедитесь, что backend API разрешает запросы с `https://granilink.com`
- ⚠️ **API URL:** Админ-панель должна использовать API URL: `https://granilink.com/api`

## Текущий статус

- ✅ Конфигурация nginx готова (файл: `/opt/grani/server-config/nginx/nginx.conf`)
- ✅ Скрипт для применения готов (`server-config/apply-admin-nginx.sh`)
- ⏳ **Требуется:** Выполнить настройку на продакшен-сервере

## После применения

После того как nginx настроен, админ-панель будет доступна по адресу:
- **https://granilink.com/admin**

Учетные данные для входа:
- Email: rail.tamaew@gmail.com
- Пароль: ChangeThisPassword123!



