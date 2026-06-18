# 🚀 Быстрый старт: Firebase Test Lab

## Шаг 1: Авторизация пользовательским аккаунтом

```bash
gcloud auth login
```

Откроет браузер для авторизации.

## Шаг 2: Проверка настройки

```bash
cd /opt/grani/mobile-app/android
./scripts/check_firebase_setup.sh
```

## Шаг 3: Запуск тестов

```bash
./scripts/run_firebase_tests.sh \
    --singbox-config test_configs/singbox_minimal.json \
    --device-model Pixel2.arm \
    --device-version 30
```

## Просмотр результатов

После завершения тестов:
https://console.firebase.google.com/project/grani-479612/testlab/histories

## Полная инструкция

См. `/opt/grani/logs/android/firebase_test_lab_user_account_guide.md`
