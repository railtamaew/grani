# Создание тестовых конфигураций с реальным сервером

**Дата:** 2026-01-20  
**Статус:** ✅ Выполнено

---

## Что было сделано

### 1. Обновлен скрипт генерации конфигураций

**Файл:** `/opt/grani/mobile-app/android/scripts/generate_valid_test_configs.sh`

**Изменения:**
- ✅ Использует реальный WireGuard сервер (`45.12.132.94:51820`)
- ✅ Использует реальный публичный ключ сервера (`1f9Euwg9rNI7A2BnsTzjyKdxyo2j7kRbYpyrIKpT6Fc=`)
- ✅ Использует реальный приватный ключ клиента из `/opt/grani/wg0.conf`
- ✅ Создает sing-box конфигурации с реальным XRay сервером (`45.12.132.94:4443`)
- ✅ Добавлена поддержка REALITY протокола

### 2. Созданы конфигурации с реальным сервером

**WireGuard:**
- ✅ `wireguard_valid.conf` - с реальным сервером и ключами
- ✅ `wireguard_server_info.txt` - информация о сервере

**Sing-box:**
- ✅ `singbox_valid.json` - минимальная конфигурация (для тестирования интерфейса)
- ✅ `singbox_reality_valid.json` - с REALITY протоколом и реальным сервером
- ✅ `singbox_vless_valid.json` - с VLESS протоколом и реальным сервером

---

## Реальные данные сервера

### WireGuard сервер

**IP:** `45.12.132.94`  
**Порт:** `51820`  
**Публичный ключ сервера:** `1f9Euwg9rNI7A2BnsTzjyKdxyo2j7kRbYpyrIKpT6Fc=`

**Клиент:**
- Приватный ключ: `kAXi4TLijK02yUHEUKVKoChRDicxUFBQnydMQY0NI0k=`
- Публичный ключ: `TVg3PioAwVBCbPxC9I0vRGI8YokqnMx7NlBDoPZrgCo=`
- IP адрес: `10.0.0.2/32`

**Важно:** Пир клиента должен быть добавлен на сервере через API или вручную.

### XRay сервер

**IP:** `45.12.132.94`  
**Порт:** `4443` (VLESS)  
**Протоколы:** VLESS, VLESS+REALITY

**REALITY параметры:**
- Public Key: `Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY`
- Short ID: `822c3e48`
- SNI: `www.google.com`

**UUID для тестирования:** `691022bf-14cf-4ec3-8649-c49988f8578f`

**Важно:** UUID должен быть добавлен на сервере через API перед использованием.

---

## Использование в тестах

### Firebase Test Lab

**WireGuard:**
```bash
cd /opt/grani/mobile-app/android

./scripts/run_firebase_tests.sh \
  --wireguard-config test_configs/wireguard_valid.conf \
  --device-model Pixel2.arm \
  --device-version 30
```

**Sing-box (REALITY):**
```bash
./scripts/run_firebase_tests.sh \
  --singbox-config test_configs/singbox_reality_valid.json \
  --device-model Pixel2.arm \
  --device-version 30
```

**Sing-box (VLESS):**
```bash
./scripts/run_firebase_tests.sh \
  --singbox-config test_configs/singbox_vless_valid.json \
  --device-model Pixel2.arm \
  --device-version 30
```

**Оба протокола:**
```bash
./scripts/run_firebase_tests.sh \
  --singbox-config test_configs/singbox_reality_valid.json \
  --wireguard-config test_configs/wireguard_valid.conf \
  --device-model Pixel2.arm \
  --device-version 30
```

---

## Ожидаемые результаты

### WireGuard тесты

**С реальным сервером:**
- ✅ Парсинг конфигурации пройдет успешно
- ✅ Ключи будут валидными
- ✅ VPN интерфейс будет создан
- ✅ Подключение к серверу установится (если пир добавлен)
- ✅ Трафик будет проходить через VPN

**Что проверить:**
- Парсинг конфигурации
- Валидация ключей
- Создание VPN интерфейса
- Подключение к серверу
- Передача трафика

### Sing-box тесты

**С реальным сервером:**
- ✅ Парсинг JSON пройдет успешно
- ✅ Валидация конфигурации пройдет
- ✅ TUN интерфейс будет создан
- ✅ Подключение к серверу установится (если UUID добавлен)
- ✅ Трафик будет проходить через VPN

**Что проверить:**
- Парсинг конфигурации
- Валидация JSON
- Создание TUN интерфейса
- Подключение к серверу
- Передача трафика через REALITY/VLESS

---

## Важные замечания

### 1. WireGuard

**Требования:**
- Пир клиента должен быть добавлен на сервере
- Публичный ключ клиента: `TVg3PioAwVBCbPxC9I0vRGI8YokqnMx7NlBDoPZrgCo=`
- IP клиента: `10.0.0.2/32`

**Проверка:**
```bash
ssh root@45.12.132.94 "wg show"
```

Должен быть виден пир с публичным ключом `TVg3PioAwVBCbPxC9I0vRGI8YokqnMx7NlBDoPZrgCo=`.

### 2. Sing-box (XRay)

**Требования:**
- UUID должен быть добавлен на сервере через API
- Для REALITY: параметры должны совпадать с сервером
- Для VLESS: UUID должен быть в списке клиентов

**Проверка:**
- UUID `691022bf-14cf-4ec3-8649-c49988f8578f` должен быть добавлен на сервере
- REALITY параметры должны совпадать с сервером

---

## Следующие шаги

### 1. Запустить тесты с реальным сервером

```bash
cd /opt/grani/mobile-app/android

./scripts/run_firebase_tests.sh \
  --singbox-config test_configs/singbox_reality_valid.json \
  --wireguard-config test_configs/wireguard_valid.conf
```

**Ожидаемый результат:**
- Тесты не должны падать с KeyFormatException
- VPN интерфейсы должны создаваться
- Подключение к серверу должно устанавливаться
- Трафик должен проходить через VPN

### 2. Если подключение не устанавливается

**WireGuard:**
- Проверить, что пир клиента добавлен на сервере
- Проверить доступность сервера: `ping 45.12.132.94`
- Проверить порт: `nc -zv 45.12.132.94 51820`

**Sing-box:**
- Проверить, что UUID добавлен на сервере
- Проверить доступность сервера: `ping 45.12.132.94`
- Проверить порт: `nc -zv 45.12.132.94 4443`

---

## Файлы

**Скрипт:**
- `/opt/grani/mobile-app/android/scripts/generate_valid_test_configs.sh`

**Конфигурации:**
- `/opt/grani/mobile-app/android/test_configs/wireguard_valid.conf`
- `/opt/grani/mobile-app/android/test_configs/wireguard_server_info.txt`
- `/opt/grani/mobile-app/android/test_configs/singbox_valid.json`
- `/opt/grani/mobile-app/android/test_configs/singbox_reality_valid.json`
- `/opt/grani/mobile-app/android/test_configs/singbox_vless_valid.json`
- `/opt/grani/mobile-app/android/test_configs/README_VALID_CONFIGS.md`

---

## Заключение

✅ Тестовые конфигурации созданы с реальным сервером  
✅ WireGuard использует реальный сервер и ключи  
✅ Sing-box использует реальный XRay сервер  
✅ Готовы к использованию в тестах

⚠️  **Требования:**
- WireGuard: пир клиента должен быть добавлен на сервере
- Sing-box: UUID должен быть добавлен на сервере через API

💡 **Рекомендация:**
- Использовать для тестирования реального VPN подключения
- Проверить доступность сервера перед запуском тестов
- Убедиться, что клиент добавлен на сервере
