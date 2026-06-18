# 🔐 Пошаговая инструкция по авторизации

## Текущая ситуация

Вы выполнили на сервере:
```bash
gcloud auth login --no-browser
```

И получили команду для выполнения на машине с браузером.

## ✅ Что делать дальше

### Вариант 1: Простой способ (без gcloud на MacBook)

1. **На сервере** команда показала URL - скопируйте его (начинается с `https://accounts.google.com/o/oauth2/auth?...`)

2. **На вашем MacBook** откройте этот URL в браузере (Chrome, Safari, Firefox - любой)

3. **В браузере:**
   - Авторизуйтесь через Google аккаунт `rail.tamaew@gmail.com`
   - После авторизации вас перенаправит на страницу с кодом
   - **Скопируйте код** из URL (параметр `code=...`) или с страницы

4. **Вернитесь на сервер** и вставьте код в формате:
   ```
   state=Mr9X63QciabXESSGvEFlORCnETaMB7&code=СКОПИРОВАННЫЙ_КОД
   ```
   
   Где `Mr9X63QciabXESSGvEFlORCnETaMB7` - это значение `state` из оригинальной команды.

### Вариант 2: С gcloud на MacBook (если установлен)

1. **На MacBook** откройте терминал

2. **Выполните команду**, которую показал сервер:
   ```bash
   gcloud auth login --remote-bootstrap="https://accounts.google.com/o/oauth2/auth?..."
   ```
   (полная строка с параметрами)

3. **Команда откроет браузер** - авторизуйтесь

4. **После авторизации** команда выведет результат - скопируйте его

5. **На сервере** вставьте скопированный результат

## 🔍 Как найти код в URL

После авторизации в браузере URL будет примерно таким:
```
https://localhost:8085/?state=Mr9X63QciabXESSGvEFlORCnETaMB7&code=4/0AeanS1234567890abcdef...
```

Скопируйте:
- `state=Mr9X63QciabXESSGvEFlORCnETaMB7`
- `code=4/0AeanS1234567890abcdef...`

И вставьте на сервере в формате:
```
state=Mr9X63QciabXESSGvEFlORCnETaMB7&code=4/0AeanS1234567890abcdef...
```

## ✅ После успешной авторизации

Проверьте:
```bash
gcloud auth list
```

Должно показать:
```
ACCOUNT                    ACTIVE
rail.tamaew@gmail.com      *
```

## 🚀 Затем запустите тесты

```bash
cd /opt/grani/mobile-app/android
./scripts/run_firebase_tests.sh \
    --singbox-config test_configs/singbox_minimal.json \
    --device-model Pixel2.arm \
    --device-version 30
```

---

**Важно:** Процесс требует ручного копирования кода из браузера, так как это механизм безопасности Google.
