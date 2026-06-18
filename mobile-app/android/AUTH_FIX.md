# 🔧 Исправление ошибки авторизации

## ❌ Проблема

Вы получили ошибку:
```
Required parameter is missing: response_type
Error 400: invalid_request
```

**Причина:** URL из команды `gcloud auth login --no-browser` нельзя просто открыть в браузере. Нужно выполнить специальную команду `gcloud auth login --remote-bootstrap=...` на машине с браузером.

## ✅ Решение

### Вариант 1: Правильный способ с gcloud на MacBook

1. **Установите gcloud на MacBook** (если еще не установлен):
   ```bash
   brew install --cask google-cloud-sdk
   ```

2. **На сервере** выполните снова:
   ```bash
   gcloud auth login --no-browser
   ```

3. **Скопируйте полную команду**, которую покажет сервер:
   ```
   gcloud auth login --remote-bootstrap="https://accounts.google.com/o/oauth2/auth?..."
   ```
   (вся строка целиком, включая кавычки)

4. **На MacBook** в терминале выполните эту команду (скопированную полностью):
   ```bash
   gcloud auth login --remote-bootstrap="https://accounts.google.com/o/oauth2/auth?..."
   ```

5. **Команда откроет браузер** - авторизуйтесь через `rail.tamaew@gmail.com`

6. **После авторизации** команда выведет результат - скопируйте его

7. **На сервере** вставьте скопированный результат в терминал

### Вариант 2: Использование существующего сервисного аккаунта

Если авторизация пользовательским аккаунтом вызывает сложности, можно попробовать использовать сервисный аккаунт с дополнительными правами:

1. Попросите администратора проекта добавить роль:
   ```bash
   gcloud projects add-iam-policy-binding grani-479612 \
       --member="serviceAccount:firebase-adminsdk-fbsvc@grani-479612.iam.gserviceaccount.com" \
       --role="roles/storage.objectAdmin"
   ```

2. Затем попробуйте запустить тесты с текущим сервисным аккаунтом

### Вариант 3: Использование Application Default Credentials

Попробуйте:
```bash
gcloud auth application-default login --no-browser
```

Это также требует выполнения команды на машине с браузером, но может работать иначе.

## 🔍 Важно понимать

**Не открывайте URL напрямую в браузере!**

Команда `gcloud auth login --no-browser` показывает команду для выполнения на **машине с браузером** (ваш MacBook), а не просто URL для открытия.

## 📝 Правильная последовательность

1. **Сервер:** `gcloud auth login --no-browser` → показывает команду
2. **MacBook:** Выполнить команду `gcloud auth login --remote-bootstrap=...` → открывает браузер
3. **Браузер:** Авторизация → показывает код
4. **MacBook:** Скопировать результат команды
5. **Сервер:** Вставить результат → готово!
