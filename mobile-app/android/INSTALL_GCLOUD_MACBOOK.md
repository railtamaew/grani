# 📦 Установка gcloud на MacBook

## Шаг 1: Проверка Homebrew

```bash
# Проверьте, установлен ли Homebrew
brew --version
```

Если Homebrew не установлен, установите его:
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

## Шаг 2: Установка Google Cloud SDK

```bash
brew install --cask google-cloud-sdk
```

## Шаг 3: Инициализация gcloud

После установки выполните:
```bash
gcloud init
```

Или сразу попробуйте:
```bash
gcloud --version
```

## Шаг 4: После установки

Теперь вы сможете выполнить команду авторизации:
```bash
gcloud auth login --remote-bootstrap="https://accounts.google.com/o/oauth2/auth?..."
```

(Скопируйте команду с сервера после выполнения `gcloud auth login --no-browser`)

