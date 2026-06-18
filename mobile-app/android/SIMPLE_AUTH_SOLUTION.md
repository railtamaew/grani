# 🔧 Простое решение проблемы авторизации

## ❌ Проблема: Ссылка не работает

Команда `gcloud auth login --no-browser` показывает команду для выполнения на машине с браузером, а не просто URL.

## ✅ Решение: Установить gcloud на MacBook

### Шаг 1: Установите gcloud на MacBook

```bash
# На MacBook в терминале
brew install --cask google-cloud-sdk
```

Если нет Homebrew:
```bash
# Установите Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Затем установите gcloud
brew install --cask google-cloud-sdk
```

### Шаг 2: На сервере получите команду

```bash
# На сервере
gcloud auth login --no-browser
```

Команда покажет:
```
gcloud auth login --remote-bootstrap="https://accounts.google.com/o/oauth2/auth?..."
```

### Шаг 3: На MacBook выполните команду

```bash
# На MacBook (скопируйте всю команду целиком)
gcloud auth login --remote-bootstrap="https://accounts.google.com/o/oauth2/auth?..."
```

### Шаг 4: Скопируйте результат

После авторизации команда выведет результат - скопируйте его полностью.

### Шаг 5: Вставьте на сервере

Вставьте скопированный результат в терминал на сервере.

## 🔄 Альтернатива: Использовать сервисный аккаунт

Если установка gcloud на MacBook неудобна, можно попробовать использовать сервисный аккаунт с дополнительными правами.

Попросите администратора проекта добавить роль:
```bash
gcloud projects add-iam-policy-binding grani-479612 \
    --member="serviceAccount:firebase-adminsdk-fbsvc@grani-479612.iam.gserviceaccount.com" \
    --role="roles/storage.objectAdmin"
```

Затем попробуйте запустить тесты с текущим сервисным аккаунтом.

