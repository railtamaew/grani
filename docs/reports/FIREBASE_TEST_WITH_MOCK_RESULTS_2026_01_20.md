# Результаты тестов Firebase Test Lab с mock-решением

**Дата:** 2026-01-20  
**Matrix ID:** matrix-1dys3u6mdkuka  
**Статус:** ⚠️ Тесты падают, но mock-решение работает

---

## ✅ Успехи

### 1. Mock-решение работает

**Логи подтверждают:**
```
01-20 01:11:52.503 D VpnServiceTest: DEBUG: Mock flag found in instrumentation args
01-20 01:11:52.503 D VpnServiceTest: DEBUG: Using mock VPN permission (Firebase Test Lab mode)
01-20 01:11:52.503 D VpnServiceTest: DEBUG: Mock VPN permission granted (always true)
01-20 01:11:52.503 D VpnServiceTest: DEBUG: VPN permission granted: true
```

✅ VPN разрешение выдается через mock  
✅ Тесты больше не пропускаются (`assumeTrue` проходит)  
✅ Конфигурации читаются правильно из instrumentation arguments

### 2. Конфигурации передаются корректно

**Логи подтверждают:**
```
01-20 01:11:52.502 D VpnServiceTest: DEBUG: Found config in instrumentation args: wireguard_config_b64
01-20 01:11:52.502 D VpnServiceTest: DEBUG: Config after read: [Interface]
01-20 01:11:52.502 D VpnServiceTest: PrivateKey = YOUR_PRIVATE_KEY_HERE
...
01-20 01:12:02.715 D VpnServiceTest: DEBUG: Found config in instrumentation args: singbox_config_b64
01-20 01:12:02.715 D VpnServiceTest: DEBUG: Config after read: {
01-20 01:12:02.715 D VpnServiceTest:   "log": {
01-20 01:12:02.715 D VpnServiceTest:     "level": "info"
```

✅ Конфигурации читаются из `InstrumentationRegistry.getArguments()`  
✅ Base64 декодирование работает  
✅ Оба протокола (WireGuard и sing-box) получают конфигурации

---

## ❌ Проблемы

### 1. VPN не запускается из-за невалидных ключей

**Ошибка для WireGuard:**
```
01-20 01:11:52.510 E GraniVpnService: startWireGuard: Ошибка запуска WireGuard: com.wireguard.crypto.KeyFormatException
01-20 01:11:52.510 E GraniVpnService: com.wireguard.config.BadConfigException: com.wireguard.crypto.KeyFormatException
01-20 01:11:52.510 E GraniVpnService: 	at com.wireguard.config.Peer$Builder.parsePublicKey(Peer.java:278)
```

**Причина:**
- Тестовая конфигурация содержит placeholder значения:
  - `PrivateKey = YOUR_PRIVATE_KEY_HERE`
  - `PublicKey = SERVER_PUBLIC_KEY_HERE`
- WireGuard библиотека не может распарсить эти значения как валидные ключи

**Результат:**
- VPN не запускается
- Тест падает с `AssertionError: WireGuard VPN did not start in time`

### 2. Sing-box конфигурация не создает реальное подключение

**Конфигурация:**
```json
{
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
```

**Проблема:**
- `direct` outbound не создает VPN подключение к серверу
- Это просто локальная конфигурация для тестирования парсинга
- Не подходит для тестирования реального VPN подключения

---

## 📊 Результаты тестов

**XML результаты:**
```xml
<testsuite tests='2' failures='2' skipped='0' errors='0' time='20.243'>
  <testcase name='start_wireguard_with_provided_config' time='10.218'>
    <failure>java.lang.AssertionError: WireGuard VPN did not start in time</failure>
  </testcase>
  <testcase name='start_singbox_with_provided_config' time='10.025'>
    <failure>java.lang.AssertionError: Sing-box VPN did not start in time</failure>
  </testcase>
</testsuite>
```

**Статус:** 2 теста провалились, 0 пропущено

---

## 🔍 Анализ

### Что работает:
1. ✅ Mock-решение для VPN разрешения
2. ✅ Передача конфигураций через environment variables
3. ✅ Чтение конфигураций в тестах
4. ✅ Парсинг конфигураций

### Что не работает:
1. ❌ Запуск VPN с placeholder конфигурациями
2. ❌ Реальное VPN подключение (нет валидных ключей/серверов)

---

## 💡 Решения

### Вариант 1: Использовать валидные тестовые конфигурации

**Для WireGuard:**
- Сгенерировать валидные тестовые ключи
- Использовать тестовый WireGuard сервер (если доступен)
- Или использовать mock для WireGuard библиотеки

**Для sing-box:**
- Использовать реальную конфигурацию с валидным сервером
- Или использовать тестовый sing-box сервер

### Вариант 2: Разделить тесты на этапы

1. **Тесты парсинга конфигураций** (unit tests)
   - Проверяют только парсинг, без запуска VPN
   - Используют любые конфигурации (включая placeholder)

2. **Тесты VPN подключения** (integration tests)
   - Проверяют реальное подключение
   - Требуют валидные конфигурации с реальными серверами
   - Запускаются только при наличии валидных конфигураций

### Вариант 3: Использовать mock для VPN библиотек

- Mock WireGuard библиотеку для тестирования логики без реального подключения
- Mock sing-box для тестирования логики без реального подключения
- Тестировать только логику приложения, а не реальное VPN подключение

---

## 📝 Рекомендации

### Краткосрочные:
1. ✅ Mock-решение для VPN разрешения работает - оставить как есть
2. 🔄 Создать валидные тестовые конфигурации для WireGuard
3. 🔄 Создать валидную тестовую конфигурацию для sing-box с реальным сервером

### Долгосрочные:
1. Разделить тесты на unit (парсинг) и integration (подключение)
2. Использовать тестовые серверы для integration тестов
3. Добавить возможность пропускать integration тесты, если нет валидных конфигураций

---

## 🎯 Выводы

**Mock-решение успешно:**
- ✅ VPN разрешение выдается через mock
- ✅ Тесты больше не пропускаются
- ✅ Конфигурации передаются и читаются правильно

**Следующий шаг:**
- 🔄 Использовать валидные тестовые конфигурации для реального тестирования VPN подключения
- 🔄 Или разделить тесты на этапы (парсинг vs подключение)

---

## 📁 Файлы

- **Логи:** `/opt/grani/logs/android/firebase_test_20260120_091539/`
- **XML результаты:** `test_result_1.xml`
- **Logcat:** `logcat`
- **Firebase Console:** https://console.firebase.google.com/project/grani-479612/testlab/histories/bh.26be956619bb9aa6/matrices/8393569283539286481
