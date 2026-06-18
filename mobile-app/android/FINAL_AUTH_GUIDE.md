# ✅ Финальная инструкция по авторизации

## ❌ Проблема

Ссылка из `gcloud auth login --no-browser` **не работает** при открытии в браузере напрямую, потому что это не просто URL, а команда для выполнения на машине с браузером.

## ✅ Решение: Два варианта

### Вариант 1: Установить gcloud на MacBook (рекомендуется)

**Это самый простой способ!**

#### Шаг 1: Установите gcloud на MacBook

На MacBook в терминале выполните:

```bash
# Если есть Homebrew:
brew install --cask google-cloud-sdk

# Если нет Homebrew, установите сначала:
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Затем:
brew install --cask google-cloud-sdk
```

#### Шаг 2: На сервере получите команду

```bash
# На сервере
gcloud auth login --no-browser
```

Команда покажет что-то вроде:
```
gcloud auth login --remote-bootstrap="https://accounts.google.com/o/oauth2/auth?..."
```

#### Шаг 3: На MacBook выполните команду

Скопируйте **всю команду целиком** (включая кавычки) и выполните на MacBook:

```bash
# На MacBook - вставьте скопированную команду
gcloud auth login --remote-bootstrap="https://accounts.google.com/o/oauth2/auth?..."
```

#### Шаг 4: Команда откроет браузер

- Авторизуйтесь через `rail.tamaew@gmail.com`
- После авторизации команда выведет результат
- **Скопируйте весь вывод команды**

#### Шаг 5: Вставьте результат на сервере

Вернитесь на сервер и вставьте скопированный результат в терминал.

---

### Вариант 2: Попробовать с текущим сервисным аккаунтом

Если установка gcloud на MacBook неудобна, можно попробовать использовать сервисный аккаунт с дополнительными правами.

**Попросите администратора проекта** (пользователя с правами Owner/Editor) добавить роль:

```bash
gcloud projects add-iam-policy-binding grani-479612 \
    --member="serviceAccount:firebase-adminsdk-fbsvc@grani-479612.iam.gserviceaccount.com" \
    --role="roles/storage.objectAdmin"
```

Затем попробуйте запустить тесты с текущим сервисным аккаунтом.

---

## 🎯 Рекомендация

**Лучше использовать Вариант 1** - установить gcloud на MacBook. Это займет 2-3 минуты, но решит проблему раз и навсегда.

Установка через Homebrew очень простая:
```bash
brew install --cask google-cloud-sdk
```

После установки процесс авторизации будет простым и понятным.

---

## ✅ После успешной авторизации

Проверьте:
```bash
gcloud auth list
```

Запустите тесты:
```bash
cd /opt/grani/mobile-app/android
./scripts/run_firebase_tests.sh \
    --singbox-config test_configs/singbox_minimal.json \
    --device-model Pixel2.arm \
    --device-version 30
```
