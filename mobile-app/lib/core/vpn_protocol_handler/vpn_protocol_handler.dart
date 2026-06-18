import '../../models/server.dart';
import '../../models/vpn_protocol.dart';

/// Параметры для подключения через протокол (получение и применение конфигурации).
class ProtocolConnectParams {
  const ProtocolConnectParams({
    required this.token,
    required this.server,
    required this.protocol,
    this.deviceId,
  });

  final String token;
  final Server server;
  final VpnProtocol protocol;
  final String? deviceId;
}

/// Контракт обработчика VPN-протокола: получение конфигурации, применение, проверка валидности.
/// Реализация только для Xray (VLESS/VMESS/Reality).
abstract class VpnProtocolHandler {
  /// Получить конфигурацию с сервера и применить её. Возвращает true при успехе.
  Future<bool> connect(ProtocolConnectParams params);

  /// Применить уже полученную конфигурацию (например из кэша или повторное подключение).
  Future<bool> applyConfig(String config, VpnProtocol protocol);

  /// Проверка, что строка конфигурации подходит для данного протокола и может быть использована.
  bool isConfigValid(String config, VpnProtocol protocol);
}
