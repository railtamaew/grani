# Исправление загрузки серверов в мобильном приложении

## Проблема
Мобильное приложение показывало "Серверы не загружены" из-за слишком строгой фильтрации серверов.

## Причина
В методе `refreshServers()` все серверы без `wireguard_public_key` отфильтровывались, даже если они поддерживали другие протоколы (XRay, OpenVPN Cloak), для которых `wireguard_public_key` не обязателен.

## Исправление

### Изменения в `mobile-app/lib/services/vpn_service.dart`:

**Было:**
```dart
// Фильтруем серверы без wireguard_public_key (они не могут быть использованы)
if (server.wireguardPublicKey == null || server.wireguardPublicKey!.isEmpty) {
  return false;
}
```

**Стало:**
```dart
// Проверяем поддерживаемые протоколы
final protocols = server.supportedProtocols ?? ['wireguard'];

// Если сервер поддерживает только WireGuard или GRANIWG, требуется wireguard_public_key
final onlyWireguardProtocols = protocols.every((p) => 
  p == 'wireguard' || p == 'graniwg'
);

if (onlyWireguardProtocols) {
  // Для WireGuard/GRANIWG требуется wireguard_public_key
  if (server.wireguardPublicKey == null || server.wireguardPublicKey!.isEmpty) {
    return false;
  }
} else {
  // Для XRay и OpenVPN Cloak wireguard_public_key не обязателен
  // Проверяем, что есть хотя бы один поддерживаемый протокол
  final hasValidProtocol = protocols.any((p) => 
    ['wireguard', 'graniwg', 'xray_vless', 'xray_vmess', 'xray_reality', 'openvpn_cloak'].contains(p)
  );
  
  if (!hasValidProtocol) {
    return false;
  }
}
```

## Результат

Теперь мобильное приложение:
1. ✅ Показывает серверы с WireGuard/GRANIWG (требуется wireguard_public_key)
2. ✅ Показывает серверы с XRay протоколами (wireguard_public_key не обязателен)
3. ✅ Показывает серверы с OpenVPN Cloak (wireguard_public_key не обязателен)
4. ✅ Правильно фильтрует только неактивные серверы и серверы без поддерживаемых протоколов

## Текущий статус серверов

После проверки:
- **Всего серверов:** 1
- **Активных:** 1
- **Готовых для теста:** 1 (HU-BUD-01)

## Что нужно сделать

1. ✅ Исправлена фильтрация серверов в мобильном приложении
2. ✅ Добавлены поля для новых протоколов в БД
3. ⏳ Настроить протоколы на серверах (опционально):
   ```bash
   cd /opt/grani/backend
   python3 scripts/setup_server_protocols.py list
   python3 scripts/setup_server_protocols.py reality 1 --server-name "google.com"
   ```

## Проверка

После обновления мобильного приложения серверы должны загружаться корректно:
- Серверы с WireGuard и wireguard_public_key будут показаны
- Серверы с XRay протоколами будут показаны (даже без wireguard_public_key)
- Серверы с OpenVPN Cloak будут показаны (даже без wireguard_public_key)


