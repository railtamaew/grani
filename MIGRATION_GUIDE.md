# 🚀 Руководство по миграции на безопасное управление секретами

**Цель:** Мигрировать на безопасное управление секретами **без остановки сервиса**.

---

## 📋 План миграции

### Этап 1: Подготовка (5 минут)

1. ✅ Проверить, что `.gitignore` настроен
2. ✅ Создать безопасное хранилище секретов
3. ✅ Сгенерировать новый SECRET_KEY (если нужно)

### Этап 2: Миграция секретов (10 минут)

1. ✅ Скопировать секреты в безопасное место
2. ✅ Обновить конфигурацию приложения
3. ✅ Проверить работу

### Этап 3: Ротация SECRET_KEY (опционально, 15 минут)

1. ✅ Настроить graceful migration
2. ✅ Перезапустить приложение
3. ✅ Мониторинг

---

## 🔧 Пошаговая инструкция

### Шаг 1: Проверка текущего состояния

```bash
# Проверить, что секреты не в Git
cd /opt/grani
git ls-files | grep -E "\.env|env-production" || echo "✅ Secrets not in Git"

# Проверить существующие секреты
ls -la server-config/env-production.env 2>/dev/null || echo "File not found"
ls -la backend/.env 2>/dev/null || echo "File not found"
```

### Шаг 2: Создание безопасного хранилища

```bash
# Создать директорию
sudo mkdir -p /etc/grani
sudo chmod 700 /etc/grani

# Создать файл секретов (если еще не создан)
sudo ./backend/scripts/safe_secrets_migration.sh
```

### Шаг 3: Миграция секретов

**Вариант A: Если секреты в файлах проекта**

```bash
# 1. Скопировать секреты из старого места
sudo cp server-config/env-production.env /etc/grani/secrets.env
sudo chmod 600 /etc/grani/secrets.env

# 2. Проверить содержимое (убедиться, что все секреты на месте)
sudo cat /etc/grani/secrets.env | grep -v "^#" | grep "="

# 3. Удалить старые файлы (после проверки!)
# ВАЖНО: Сначала убедитесь, что новое хранилище работает!
# sudo rm server-config/env-production.env
# sudo rm backend/.env
```

**Вариант B: Если секреты в переменных окружения**

```bash
# 1. Экспортировать текущие переменные в файл
sudo env | grep -E "DATABASE_URL|SECRET_KEY|SMTP|REDIS" > /etc/grani/secrets.env
sudo chmod 600 /etc/grani/secrets.env

# 2. Отредактировать файл, оставив только нужные переменные
sudo nano /etc/grani/secrets.env
```

### Шаг 4: Обновление конфигурации приложения

#### Для Docker Compose:

```yaml
# docker-compose.yml
services:
  backend:
    env_file:
      - /etc/grani/secrets.env
    environment:
      - ENV=production
```

#### Для Systemd:

```ini
# /etc/systemd/system/grani-backend.service
[Service]
EnvironmentFile=/etc/grani/secrets.env
Environment=ENV=production
```

Затем:
```bash
sudo systemctl daemon-reload
```

#### Для прямого запуска:

Обновить скрипт запуска:
```bash
#!/bin/bash
# Загрузить секреты
export $(cat /etc/grani/secrets.env | grep -v "^#" | xargs)
export ENV=production

# Запустить приложение
cd /opt/grani/backend
python3 -m uvicorn main:app --host 0.0.0.0 --port 8000
```

### Шаг 5: Тестирование (БЕЗ перезапуска)

```bash
# Проверить, что приложение может загрузить секреты
python3 -c "
import sys
sys.path.insert(0, '/opt/grani/backend')
from core.config import settings
print('✅ Config loaded successfully')
print(f'Database: {settings.database_url[:30]}...')
print(f'Secret key length: {len(settings.secret_key)}')
"
```

### Шаг 6: Graceful перезапуск

```bash
# Для systemd
sudo systemctl reload grani-backend  # Если поддерживает reload
# или
sudo systemctl restart grani-backend

# Для Docker
docker-compose restart backend

# Проверить статус
sudo systemctl status grani-backend
# или
docker-compose ps
```

### Шаг 7: Проверка работы

```bash
# 1. Проверить логи
sudo journalctl -u grani-backend -f
# или
docker-compose logs -f backend

# 2. Проверить health endpoint
curl http://localhost:8000/health

# 3. Проверить аутентификацию
curl -X POST http://localhost:8000/api/auth/send-code \
  -H "Content-Type: application/json" \
  -d '{"email": "test@example.com"}'
```

---

## 🔑 Ротация SECRET_KEY (опционально)

### Если нужно сменить SECRET_KEY без logout:

```bash
# 1. Сгенерировать новый ключ
python3 backend/scripts/rotate_secrets.py --generate-new-secret-key

# 2. Сохранить текущий ключ
CURRENT_KEY=$(sudo grep "^SECRET_KEY=" /etc/grani/secrets.env | cut -d'=' -f2-)

# 3. Обновить файл секретов
sudo nano /etc/grani/secrets.env
# Добавить:
# SECRET_KEY_OLD=${CURRENT_KEY}
# SECRET_KEY=${NEW_KEY}

# 4. Перезапустить приложение
sudo systemctl restart grani-backend

# 5. Мониторинг (проверить, что старые токены работают)
# Через 1 час (когда все access tokens истекут):
# Удалить SECRET_KEY_OLD из конфигурации
```

---

## ✅ Чеклист миграции

- [ ] ✅ `.gitignore` настроен
- [ ] ✅ Создана директория `/etc/grani` с правами 700
- [ ] ✅ Создан файл `/etc/grani/secrets.env` с правами 600
- [ ] ✅ Все секреты скопированы в новое хранилище
- [ ] ✅ Конфигурация приложения обновлена
- [ ] ✅ Приложение протестировано (загрузка конфигурации)
- [ ] ✅ Приложение перезапущено
- [ ] ✅ Проверена работа сервиса
- [ ] ✅ Старые файлы секретов удалены (после проверки)
- [ ] ✅ Документация обновлена

---

## 🚨 Откат (если что-то пошло не так)

```bash
# 1. Восстановить старую конфигурацию
sudo cp /etc/grani/backups/secrets.env.* /etc/grani/secrets.env

# 2. Откатить изменения в конфигурации приложения
# (вернуть старые env_file или environment)

# 3. Перезапустить приложение
sudo systemctl restart grani-backend

# 4. Проверить работу
curl http://localhost:8000/health
```

---

## 📞 Поддержка

При возникновении проблем:

1. Проверить логи: `sudo journalctl -u grani-backend -n 100`
2. Проверить права доступа: `ls -la /etc/grani/`
3. Проверить загрузку конфигурации: `python3 -c "from backend.core.config import settings; print(settings)"`
4. См. документацию: `docs/SECRETS_MANAGEMENT.md`

---

**Важно:** Все изменения можно откатить. Сделайте резервные копии перед миграцией!
