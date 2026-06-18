# 🚨 ПЛАН НЕМЕДЛЕННЫХ ДЕЙСТВИЙ

**Дата:** 2026-01-21  
**Приоритет:** 🔴 КРИТИЧЕСКИЙ

---

## ⚠️ ВНИМАНИЕ: КРИТИЧЕСКИЕ ПРОБЛЕМЫ БЕЗОПАСНОСТИ

Обнаружены **критические уязвимости безопасности**, которые требуют немедленного исправления.

---

## 🔴 ШАГ 1: ЗАЩИТА СЕКРЕТОВ (НЕМЕДЛЕННО)

### 1.1. Проверить, что секреты не в Git

```bash
# Проверить, отслеживается ли файл с секретами
git ls-files | grep -E "\.env|env-production"

# Если файлы отслеживаются - НЕМЕДЛЕННО удалить из индекса
git rm --cached server-config/env-production.env
git rm --cached backend/.env
git rm --cached backend/.env.backup_
```

### 1.2. Добавить .gitignore

✅ **УЖЕ СОЗДАН:** `.gitignore` в корне проекта

Проверить, что все секретные файлы игнорируются:
```bash
git status --ignored | grep -E "\.env|env-production"
```

### 1.3. Очистить историю Git (если секреты уже закоммичены)

**⚠️ ВНИМАНИЕ:** Это изменит историю Git. Сделать на копии репозитория!

```bash
# Вариант 1: Использовать git filter-branch
git filter-branch --force --index-filter \
  "git rm --cached --ignore-unmatch server-config/env-production.env backend/.env" \
  --prune-empty --tag-name-filter cat -- --all

# Вариант 2: Использовать BFG Repo-Cleaner (рекомендуется)
# Скачать: https://rtyley.github.io/bfg-repo-cleaner/
bfg --delete-files env-production.env
bfg --delete-files .env
git reflog expire --expire=now --all
git gc --prune=now --aggressive
```

### 1.4. РОТАЦИЯ ВСЕХ СЕКРЕТОВ

**НЕМЕДЛЕННО** изменить все пароли и ключи:

1. **База данных:**
   - Сгенерировать новый пароль PostgreSQL
   - Обновить `DATABASE_URL` на всех серверах

2. **Redis:**
   - Сгенерировать новый пароль Redis
   - Обновить `REDIS_URL` на всех серверах

3. **SMTP:**
   - Изменить пароль SMTP (Yandex)
   - Обновить `SMTP_PASSWORD` на всех серверах

4. **SECRET_KEY:**
   ```python
   import secrets
   print(secrets.token_urlsafe(32))
   ```
   - Использовать сгенерированный ключ
   - Обновить на всех серверах
   - **ВАЖНО:** Все существующие JWT токены станут невалидными

5. **SSH ключи:**
   - Если ключи скомпрометированы - сгенерировать новые
   - Обновить на всех серверах

---

## 🔴 ШАГ 2: НАСТРОЙКА SECRETS MANAGEMENT

### 2.1. Использовать переменные окружения на сервере

**НЕ хранить секреты в файлах!**

На сервере создать файл `/etc/grani/secrets.env` (с правами 600):
```bash
sudo mkdir -p /etc/grani
sudo chmod 700 /etc/grani
sudo nano /etc/grani/secrets.env
# Добавить все секреты
sudo chmod 600 /etc/grani/secrets.env
```

В docker-compose или systemd service:
```yaml
env_file:
  - /etc/grani/secrets.env
```

### 2.2. Альтернатива: AWS Secrets Manager / HashiCorp Vault

Если используете облако:
- AWS: AWS Secrets Manager
- Yandex Cloud: Yandex Lockbox
- Self-hosted: HashiCorp Vault

---

## 🔴 ШАГ 3: ПРОВЕРКА БЕЗОПАСНОСТИ

### 3.1. Проверить доступность секретов

```bash
# Проверить, что секреты не доступны публично
curl -I https://github.com/YOUR_REPO/blob/main/server-config/env-production.env
# Должен вернуть 404

# Проверить историю Git
git log --all --full-history -- server-config/env-production.env
# Если есть коммиты - нужно очистить историю
```

### 3.2. Сканирование на утечки

```bash
# Использовать git-secrets
git secrets --scan

# Или truffleHog
trufflehog git file://. --json
```

### 3.3. Проверить права доступа к файлам

```bash
# На сервере проверить права доступа
ls -la server-config/env-production.env
# Должно быть: -rw------- (600) или -rw-r----- (640)
```

---

## 🟠 ШАГ 4: ОБНОВЛЕНИЕ КОНФИГУРАЦИИ

### 4.1. Обновить config.py

Убедиться, что `backend/core/config.py` не содержит хардкод секретов:
- ✅ Секреты только из переменных окружения
- ✅ Валидация SECRET_KEY в production
- ✅ Нет дефолтных значений для production секретов

### 4.2. Создать env.example

Создать `server-config/env.example` с placeholder значениями:
```bash
SMTP_PASSWORD=your_smtp_password_here
SECRET_KEY=your_secret_key_here
DATABASE_URL=postgresql://user:password@host:port/dbname
```

---

## 📋 ЧЕКЛИСТ ВЫПОЛНЕНИЯ

- [ ] ✅ Создан `.gitignore` с правильными исключениями
- [ ] Проверено, что секретные файлы не отслеживаются Git
- [ ] Очищена история Git от секретов (если нужно)
- [ ] Ротация всех паролей и ключей
- [ ] Сгенерирован новый SECRET_KEY
- [ ] Настроено хранение секретов (переменные окружения / secrets manager)
- [ ] Обновлены все серверы с новыми секретами
- [ ] Проверена доступность секретов (не публичны)
- [ ] Обновлен `env.example` с placeholder значениями
- [ ] Документирован процесс управления секретами

---

## ⚠️ ВАЖНЫЕ ЗАМЕЧАНИЯ

1. **Не коммитить секреты** - даже в приватные репозитории
2. **Ротация секретов** - регулярно менять пароли и ключи
3. **Мониторинг** - настроить алерты на утечки секретов
4. **Доступ** - минимизировать количество людей с доступом к секретам
5. **Резервные копии** - хранить секреты в безопасном месте (не в Git!)

---

## 📞 КОНТАКТЫ ДЛЯ ЭКСТРЕННЫХ СИТУАЦИЙ

Если обнаружена утечка секретов:
1. **НЕМЕДЛЕННО** ротировать все скомпрометированные секреты
2. Проверить логи на подозрительную активность
3. Проверить доступы к системам
4. Уведомить команду безопасности

---

**Статус:** 🔴 ТРЕБУЕТСЯ НЕМЕДЛЕННОЕ ВЫПОЛНЕНИЕ
