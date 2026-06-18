import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/vpn_service.dart';
import 'package:mobile_app/protocols/xray/models/xray_config.dart';
import 'dart:convert';

/// Интеграционные тесты для нативного XRay (libXray)
/// 
/// XRay протоколы теперь используют нативный libXray вместо sing-box,
/// поэтому тесты проверяют формат toXrayNativeJsonConfig().
void main() {
  group('VPN Connection Flow Tests - Native XRay (libXray)', () {
    test('XrayConfig toXrayNativeJsonConfig generates valid native XRay JSON', () {
      // Создаем тестовую конфигурацию Xray
      final xrayConfig = XrayConfig(
        protocol: 'vless',
        address: '45.12.132.94',
        port: 443,
        uuid: 'de368a01-aa2d-4a6d-865f-2b658486a4e5',
        security: 'reality',
        network: 'tcp',
        sni: 'www.google.com',
        realityPublicKey: 'Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY',
        realityShortId: '822c3e48',
      );

      // Преобразуем в нативный XRay JSON (для libXray)
      final nativeJson = xrayConfig.toXrayNativeJsonConfig();
      
      // Проверяем, что это валидный JSON
      expect(() => jsonDecode(nativeJson), returnsNormally);
      
      final parsed = jsonDecode(nativeJson) as Map<String, dynamic>;
      
      // Проверяем обязательные поля нативного XRay формата
      expect(parsed.containsKey('log'), isTrue, reason: 'Должно быть поле log');
      expect(parsed.containsKey('inbounds'), isTrue, reason: 'Должно быть поле inbounds');
      expect(parsed.containsKey('outbounds'), isTrue, reason: 'Должно быть поле outbounds');
      expect(parsed.containsKey('routing'), isTrue, reason: 'Должно быть поле routing');
      
      // Проверяем структуру outbounds
      final outbounds = parsed['outbounds'] as List;
      expect(outbounds.isNotEmpty, isTrue, reason: 'Outbounds не должен быть пустым');
      
      final firstOutbound = outbounds[0] as Map<String, dynamic>;
      
      // В нативном XRay используется "protocol", а не "type"
      expect(firstOutbound.containsKey('protocol'), isTrue, reason: 'Outbound должен содержать поле protocol');
      expect(firstOutbound['protocol'], equals('vless'), reason: 'Protocol должен быть vless');
      
      // В нативном XRay используется settings.vnext
      expect(firstOutbound.containsKey('settings'), isTrue, reason: 'Должно быть поле settings');
      final outboundSettings = firstOutbound['settings'] as Map<String, dynamic>;
      expect(outboundSettings.containsKey('vnext'), isTrue, reason: 'Settings должен содержать vnext');
      
      // Проверяем streamSettings для REALITY (нативный XRay формат)
      expect(firstOutbound.containsKey('streamSettings'), isTrue, reason: 'Должно быть поле streamSettings');
      final streamSettings = firstOutbound['streamSettings'] as Map<String, dynamic>;
      expect(streamSettings['security'], equals('reality'), reason: 'Security должен быть reality');
      
      // Проверяем realitySettings в streamSettings
      expect(streamSettings.containsKey('realitySettings'), isTrue, reason: 'Должно быть поле realitySettings');
      final realitySettings = streamSettings['realitySettings'] as Map<String, dynamic>;
      expect(realitySettings.containsKey('publicKey'), isTrue,
          reason: 'Должно быть поле publicKey');
      expect(realitySettings['publicKey'],
          equals('Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY'));
      expect(realitySettings['serverName'], equals('www.google.com'));
      expect(realitySettings['shortId'], equals('822c3e48'));
    });

    test('Native XRay JSON should have correct structure for libXray', () {
      // Создаем тестовую конфигурацию Xray
      final xrayConfig = XrayConfig(
        protocol: 'vless',
        address: '45.12.132.94',
        port: 443,
        uuid: 'de368a01-aa2d-4a6d-865f-2b658486a4e5',
        security: 'reality',
        network: 'tcp',
        sni: 'www.google.com',
        realityPublicKey: 'Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY',
        realityShortId: '822c3e48',
      );

      final nativeJson = xrayConfig.toXrayNativeJsonConfig();
      final parsed = jsonDecode(nativeJson) as Map<String, dynamic>;
      
      // Проверяем, что конфигурация имеет все необходимые поля для нативного XRay
      expect(parsed.containsKey('log'), isTrue);
      expect(parsed.containsKey('inbounds'), isTrue);
      expect(parsed.containsKey('outbounds'), isTrue);
      expect(parsed.containsKey('routing'), isTrue);
      
      // Проверяем структуру outbound (нативный XRay формат)
      final outbounds = parsed['outbounds'] as List;
      expect(outbounds.isNotEmpty, isTrue);
      
      final firstOutbound = outbounds[0] as Map<String, dynamic>;
      expect(firstOutbound.containsKey('protocol'), isTrue, reason: 'Должно быть поле protocol (не type)');
      expect(firstOutbound.containsKey('settings'), isTrue, reason: 'Должно быть поле settings');
      expect(firstOutbound.containsKey('streamSettings'), isTrue, reason: 'Должно быть поле streamSettings');
    });

    test('Native XRay JSON should be valid and ready for base64 encoding', () {
      final xrayConfig = XrayConfig(
        protocol: 'vless',
        address: '45.12.132.94',
        port: 443,
        uuid: 'de368a01-aa2d-4a6d-865f-2b658486a4e5',
        security: 'reality',
        network: 'tcp',
        sni: 'www.google.com',
        realityPublicKey: 'Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY',
        realityShortId: '822c3e48',
      );

      final nativeJson = xrayConfig.toXrayNativeJsonConfig();
      final trimmed = nativeJson.trim();
      
      // Проверяем, что начинается с {
      expect(trimmed.startsWith('{'), isTrue, reason: 'JSON должен начинаться с {');
      
      // Проверяем, что это валидный JSON
      expect(() => jsonDecode(trimmed), returnsNormally, reason: 'Должен быть валидным JSON');
      
      // Проверяем, что JSON можно закодировать в base64 (как требуется для libXray)
      final bytes = utf8.encode(trimmed);
      final base64Encoded = base64Encode(bytes);
      expect(base64Encoded, isNotEmpty, reason: 'Base64 кодирование должно работать');
      
      // Проверяем, что можно декодировать обратно
      final decodedBytes = base64Decode(base64Encoded);
      final decoded = utf8.decode(decodedBytes);
      expect(decoded, equals(trimmed), reason: 'Base64 декодирование должно работать');
    });

    test('Native XRay JSON should have SOCKS inbound for VPN', () {
      final xrayConfig = XrayConfig(
        protocol: 'vless',
        address: '45.12.132.94',
        port: 443,
        uuid: 'de368a01-aa2d-4a6d-865f-2b658486a4e5',
        security: 'reality',
        network: 'tcp',
        sni: 'www.google.com',
        realityPublicKey: 'Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY',
        realityShortId: '822c3e48',
      );

      final nativeJson = xrayConfig.toXrayNativeJsonConfig();
      final parsed = jsonDecode(nativeJson) as Map<String, dynamic>;
      
      // Проверяем, что есть inbounds с SOCKS
      final inbounds = parsed['inbounds'] as List;
      expect(inbounds.isNotEmpty, isTrue);
      
      final firstInbound = inbounds[0] as Map<String, dynamic>;
      expect(firstInbound['protocol'], equals('socks'), reason: 'Inbound должен использовать SOCKS');
      expect(firstInbound.containsKey('tag'), isTrue, reason: 'Должен быть tag');
      expect(firstInbound['tag'], equals('socks-in'), reason: 'Tag должен быть socks-in');
    });

    test('Native XRay JSON should have routing rules', () {
      final xrayConfig = XrayConfig(
        protocol: 'vless',
        address: '45.12.132.94',
        port: 443,
        uuid: 'de368a01-aa2d-4a6d-865f-2b658486a4e5',
        security: 'reality',
        network: 'tcp',
        sni: 'www.google.com',
        realityPublicKey: 'Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY',
        realityShortId: '822c3e48',
      );

      final nativeJson = xrayConfig.toXrayNativeJsonConfig();
      final parsed = jsonDecode(nativeJson) as Map<String, dynamic>;
      
      // Проверяем, что есть routing с правилами
      expect(parsed.containsKey('routing'), isTrue, reason: 'Должно быть поле routing');
      final routing = parsed['routing'] as Map<String, dynamic>;
      expect(routing.containsKey('rules'), isTrue, reason: 'Routing должен содержать rules');
      
      final rules = routing['rules'] as List;
      expect(rules.isNotEmpty, isTrue, reason: 'Rules не должен быть пустым');
    });
  });
}
