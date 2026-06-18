# 🔐 Управление секретами

**Важно:** Этот документ описывает безопасное управление секретами в production окружении.

---

## 📋 Содержание

1. [Текущее состояние](#текущее-состояние)
2. [Безопасное хранение секретов](#безопасное-хранение-секретов)
3. [Ротация секретов](#ротация-секретов)
4. [Graceful Migration JWT](#graceful-migration-jwt)
5. [Чеклист безопасности](#чеклист-безопасности)

---

## 🚨 Текущее состояние

### Проблемы (исправлены):

1. ✅ **Секреты в репозитории** - добавлен `.gitignore`
2. ✅ **Слабый SECRET_KEY** - добавлена валидация и генерация
3. ✅ **Отсутствие ротации** - добавлена поддержка graceful migration

### Улучшения:

- ✅ Поддержка безопасных путей для секретов (`/etc/grani/secrets.env`)
- ✅ Поддержка ротации SECRET_KEY без logout пользователей
- ✅ Скрипты для безопасной миграции
- ✅ Валидация секретов при запуске

---

## 🔒 Безопасное хранение секретов

### Приоритет загрузки:

1. **Переменные окружения** (высший приоритет)
2. **Безопасные файлы:**
   - `/etc/grani/secrets.env` (production)
   - `/run/secrets/grani.env` (Docker secrets)
3. **`.env` файлы** (только для development)

### Настройка безопасного хранилища:

```bash
# 1. Создать директорию для секретов
sudo mkdir -p /etc/grani
sudo chmod 700 /etc/grani

# 2. Создать файл с секретами
sudo nano /etc/grani/secrets.env

# 3. Установить безопасные права
sudo chmod 600 /etc/grani/secrets.env

# 4. Заполнить секреты (см. env.example)
```

### Формат файла:

```bash
# Database
DATABASE_URL=postgresql://user:password@host:5432/granivpn
POSTGRES_PASSWORD=secure_password

# Redis
REDIS_URL=redis://:password@localhost:6379/0
REDIS_PASSWORD=secure_password

# JWT
SECRET_KEY=your_cryptographically_secure_key_min_32_chars
SECRET_KEY_OLD=  # Для ротации (опционально)

# Email
SMTP_PASSWORD=your_smtp_password
```

---

## 🔄 Ротация секретов

### Генерация нового SECRET_KEY:

```bash
# Вариант 1: Использовать скрипт
python3 backend/scripts/rotate_secrets.py --generate-new-secret-key

# Вариант 2: Вручную
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

### Безопасная миграция (без остановки сервиса):

```bash
# 1. Запустить скрипт миграции
sudo ./backend/scripts/safe_secrets_migration.sh

# 2. Отредактировать файл секретов
sudo nano /etc/grani/secrets.env

# 3. Обновить конфигурацию приложения для использования нового файла
# (см. раздел "Обновление конфигурации")

# 4. Graceful restart приложения
sudo systemctl restart grani-backend  # или ваш способ перезапуска
```

---

## 🔑 Graceful Migration JWT

### Проблема:

При смене `SECRET_KEY` все существующие JWT токены становятся невалидными, что приводит к logout всех пользователей.

### Решение:

Поддержка **двух ключей одновременно** - новый для создания токенов, старый для проверки существующих.

### Процесс ротации:

#### Шаг 1: Подготовка

```bash
# 1. Сгенерировать новый ключ
python3 backend/scripts/rotate_secrets.py --generate-new-secret-key

# 2. Сохранить текущий SECRET_KEY (он станет SECRET_KEY_OLD)
CURRENT_KEY=$(grep SECRET_KEY /etc/grani/secrets.env | cut -d'=' -f2)
```

#### Шаг 2: Обновление конфигурации

```bash
# В /etc/grani/secrets.env:
SECRET_KEY_OLD=${CURRENT_KEY}  # Старый ключ для проверки существующих токенов
SECRET_KEY=${NEW_KEY}           # Новый ключ для создания новых токенов
```

#### Шаг 3: Перезапуск

```bash
# Graceful restart (без остановки сервиса)
sudo systemctl reload grani-backend
# или
sudo systemctl restart grani-backend
```

#### Шаг 4: Мониторинг

- ✅ Проверить логи на ошибки аутентификации
- ✅ Убедиться, что новые токены создаются с новым ключом
- ✅ Убедиться, что старые токены продолжают работать

#### Шаг 5: Очистка (после истечения всех старых токенов)

```bash
# После того, как все старые токены истекли (обычно через 1 час для access, 90 дней для refresh):
# Удалить SECRET_KEY_OLD из конфигурации
SECRET_KEY_OLD=
```

**Время миграции:**
- Access tokens: 1 час (быстрая миграция)
- Refresh tokens: 90 дней (долгая миграция, но редко используются)

---

## 📝 Обновление конфигурации приложения

### Docker Compose:

```yaml
services:
  backend:
    env_file:
      - /etc/grani/secrets.env
    # или
    environment:
      - ENV=production
    # Переменные из env_file имеют приоритет
```

### Systemd:

```ini
[Service]
EnvironmentFile=/etc/grani/secrets.env
Environment=ENV=production
```

### Прямой запуск:

```bash
# Загрузить переменные из файла
export $(cat /etc/grani/secrets.env | xargs)
# Запустить приложение
python3 backend/main.py
```

---

## ✅ Чеклист безопасности

### Перед развертыванием:

- [ ] ✅ Все секреты удалены из Git репозитория
- [ ] ✅ `.gitignore` настроен правильно
- [ ] ✅ Секреты хранятся в `/etc/grani/secrets.env` (или другом безопасном месте)
- [ ] ✅ Права доступа к файлу секретов: `600` (только владелец)
- [ ] ✅ Директория с секретами: `700` (только владелец)
- [ ] ✅ `SECRET_KEY` сгенерирован криптографически стойким способом (минимум 32 символа)
- [ ] ✅ Все пароли сложные и уникальные
- [ ] ✅ Нет placeholder значений (`CHANGE_ME`, `change-this`) в production

### Регулярное обслуживание:

- [ ] Ротация `SECRET_KEY` каждые 6-12 месяцев
- [ ] Ротация паролей БД каждые 3-6 месяцев
- [ ] Ротация SMTP паролей каждые 3-6 месяцев
- [ ] Проверка логов на утечки секретов
- [ ] Аудит доступа к файлам секретов

### Мониторинг:

- [ ] Настроены алерты на подозрительную активность
- [ ] Мониторинг неудачных попыток аутентификации
- [ ] Логирование (без секретов) всех операций с секретами

---

## 🛠️ Утилиты

### Проверка секретов:

```bash
# Проверить файл на проблемы
python3 backend/scripts/rotate_secrets.py --check-secrets /etc/grani/secrets.env
```

### Создание шаблона:

```bash
# Создать шаблон файла секретов
python3 backend/scripts/rotate_secrets.py --create-template /etc/grani/secrets.env
```

### Генерация ключа:

```bash
# Сгенерировать новый SECRET_KEY
python3 backend/scripts/rotate_secrets.py --generate-new-secret-key
```

---

## 📚 Дополнительные ресурсы

- [OWASP Secrets Management](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html)
- [12 Factor App: Config](https://12factor.net/config)
- [Python secrets module](https://docs.python.org/3/library/secrets.html)

---

## ⚠️ Важные замечания

1. **Никогда не коммитьте секреты в Git** - даже в приватные репозитории
2. **Используйте разные секреты** для development, staging, production
3. **Ротируйте секреты регулярно** - особенно после утечек или подозрительной активности
4. **Минимизируйте доступ** - только необходимые люди должны иметь доступ к секретам
5. **Логируйте операции** - но без самих секретов
6. **Используйте secrets manager** в облаке (AWS Secrets Manager, HashiCorp Vault) если возможно

---

**Последнее обновление:** 2026-01-21
