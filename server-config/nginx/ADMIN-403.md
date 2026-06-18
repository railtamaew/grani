# 403 Forbidden на admin.granilink.com

## Причина

Nginx отдаёт 403, когда:
1. **Нет сборки** — каталог `/opt/grani/admin-panel/build` отсутствует или в нём нет `index.html`
2. **Права доступа** — пользователь nginx (`www-data`) не может читать каталог или файлы

## Что сделать на сервере

### 1. Проверить наличие сборки

```bash
ls -la /opt/grani/admin-panel/build/index.html
```

Если файла нет — собрать админку и выложить `build/` на сервер:

```bash
cd /opt/grani/admin-panel
npm ci
npm run build
```

Либо собрать локально и скопировать каталог `admin-panel/build` на сервер в `/opt/grani/admin-panel/build`.

### 2. Исправить права и перезагрузить nginx

Из репозитория на сервере:

```bash
cd /opt/grani/server-config
sudo bash fix-admin-403.sh
```

Или вручную:

```bash
sudo chown -R www-data:www-data /opt/grani/admin-panel/build
sudo chmod -R 755 /opt/grani/admin-panel/build
sudo find /opt/grani/admin-panel/build -type f -exec chmod 644 {} \;
sudo chmod 755 /opt /opt/grani /opt/grani/admin-panel
sudo nginx -t && sudo systemctl reload nginx
```

### 3. Проверить конфиг nginx

Должен быть подключён server-блок для `admin.granilink.com` (из `production.conf` или `granivpn-servers.conf`) с:

- `root /opt/grani/admin-panel/build;`
- `index index.html;`
- `location / { try_files $uri $uri/ /index.html; }`

После правок — `sudo nginx -t && sudo systemctl reload nginx`.
