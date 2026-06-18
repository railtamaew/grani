import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/protocols/xray/models/xray_config.dart';
import 'dart:convert';

/// Интеграционные тесты для проверки реальных конфигураций из логов
/// 
/// XRay протоколы теперь используют нативный libXray вместо sing-box,
/// поэтому тесты проверяют формат toXrayNativeJsonConfig().
void main() {
  group('XrayConfig Integration Tests', () {
    test('should parse REALITY config from server response correctly', () {
      // Arrange - реальная конфигурация из логов сервера
      final serverResponse = {
        'v': '2',
        'ps': 'GRANI-REALITY',
        'add': '45.12.132.94',
        'port': 443,
        'id': '3bd92782-961c-44d6-b5ae-620fd321d51f',
        'aid': 0,
        'scy': 'none',
        'net': 'tcp',
        'type': 'none',
        'host': '',
        'path': '',
        'tls': 'reality',
        'sni': 'www.google.com',
        'pbk': 'Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY',
        'sid': '822c3e48',
      };

      // Act
      final config = XrayConfig.fromJson(serverResponse);
      final nativeJson = config.toXrayNativeJsonConfig();
      final parsed = jsonDecode(nativeJson) as Map<String, dynamic>;

      // Assert - проверяем, что конфигурация валидна для нативного XRay (libXray)
      expect(config.protocol, 'vless', reason: 'Должен быть VLESS');
      expect(config.realityPublicKey, 'Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY');
      expect(config.realityShortId, '822c3e48');
      expect(config.address, '45.12.132.94');
      expect(config.port, 443);
      expect(config.security, 'reality');
      expect(config.network, 'tcp');

      // Проверяем нативный XRay конфигурацию
      expect(parsed.containsKey('inbounds'), true, reason: 'Должно быть поле inbounds');
      expect(parsed.containsKey('outbounds'), true, reason: 'Должно быть поле outbounds');
      expect(parsed.containsKey('routing'), true, reason: 'Должно быть поле routing');
      expect(parsed.containsKey('log'), true, reason: 'Должно быть поле log');

      // Проверяем SOCKS inbound (нативный XRay формат)
      final inbounds = parsed['inbounds'] as List;
      expect(inbounds.isNotEmpty, true);
      final socksInbound = inbounds[0] as Map<String, dynamic>;
      expect(socksInbound['protocol'], 'socks', reason: 'Inbound должен использовать SOCKS');
      expect(socksInbound.containsKey('tag'), true);
      expect(socksInbound['tag'], 'socks-in');

      // Проверяем outbound (нативный XRay формат)
      final outbounds = parsed['outbounds'] as List;
      final proxyOutbound = outbounds[0] as Map<String, dynamic>;
      expect(proxyOutbound['protocol'], 'vless', reason: 'Protocol должен быть vless');
      // ✅ Нативный XRay формат: используется streamSettings, а не tls напрямую
      expect(proxyOutbound.containsKey('streamSettings'), true,
          reason: 'Поле streamSettings должно быть в нативном формате XRay');
      expect(proxyOutbound.containsKey('settings'), true,
          reason: 'Поле settings должно быть в нативном формате XRay');
      
      final streamSettings = proxyOutbound['streamSettings'] as Map<String, dynamic>;
      expect(streamSettings['security'], 'reality', reason: 'Security должен быть reality');
      expect(streamSettings.containsKey('realitySettings'), true,
          reason: 'Должно быть поле realitySettings в streamSettings');
      
      final realitySettings = streamSettings['realitySettings'] as Map<String, dynamic>;
      expect(realitySettings.containsKey('publicKey'), true,
          reason: 'Должно быть поле publicKey в realitySettings');
      expect(realitySettings['publicKey'],
          equals('Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY'));
      expect(realitySettings.containsKey('shortId'), true, reason: 'Должно быть поле shortId');
      expect(realitySettings.containsKey('serverName'), true, reason: 'Должно быть поле serverName');
      expect(realitySettings['serverName'], equals('www.google.com'));
    });

    test('should generate valid native XRay JSON for libXray', () {
      // Arrange
      final config = XrayConfig(
        uuid: '691022bf-14cf-4ec3-8649-c49988f8578f',
        address: '45.12.132.94',
        port: 443,
        protocol: 'vless',
        security: 'reality',
        network: 'tcp',
        sni: 'www.google.com',
        realityPublicKey: 'Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY',
        realityShortId: '822c3e48',
      );

      // Act
      final jsonString = config.toXrayNativeJsonConfig();
      final json = jsonDecode(jsonString) as Map<String, dynamic>;

      // Assert - проверяем, что JSON валиден для нативного XRay (libXray)
      expect(json.containsKey('inbounds'), true, reason: 'Должно быть поле inbounds');
      expect(json.containsKey('outbounds'), true, reason: 'Должно быть поле outbounds');
      expect(json.containsKey('routing'), true, reason: 'Должно быть поле routing');
      
      final inbounds = json['inbounds'] as List;
      expect(inbounds.isNotEmpty, true);

      // Проверяем SOCKS inbound (нативный XRay формат)
      final socksInbound = inbounds[0] as Map<String, dynamic>;
      expect(socksInbound['protocol'], 'socks',
          reason: 'Inbound должен использовать SOCKS для VPN');
      expect(socksInbound.containsKey('tag'), true);
      expect(socksInbound['tag'], 'socks-in');

      // Проверяем outbound (нативный XRay формат)
      final outbounds = json['outbounds'] as List;
      expect(outbounds.isNotEmpty, true);
      final proxyOutbound = outbounds[0] as Map<String, dynamic>;
      expect(proxyOutbound['protocol'], 'vless', reason: 'Protocol должен быть vless');
      expect(proxyOutbound.containsKey('settings'), true, reason: 'Должно быть поле settings');
      expect(proxyOutbound.containsKey('streamSettings'), true, reason: 'Должно быть поле streamSettings');

      // Проверяем, что JSON можно сериализовать обратно
      final reSerialized = jsonEncode(json);
      expect(reSerialized.isNotEmpty, true);
      
      // Проверяем, что JSON можно закодировать в base64 (как требуется для libXray)
      final base64Encoded = base64Encode(utf8.encode(reSerialized));
      expect(base64Encoded.isNotEmpty, true, reason: 'Base64 кодирование должно работать');
    });

    test('should correctly identify protocol for various configurations', () {
      // Тест 1: VLESS с REALITY
      final realityConfig = {
        'id': 'test-uuid',
        'add': 'test.example.com',
        'port': 443,
        'v': '2',
        'tls': 'reality',
        'pbk': 'test-key',
        'scy': 'none',
        'net': 'tcp',
      };
      expect(XrayConfig.fromJson(realityConfig).protocol, 'vless');

      // Тест 2: VLESS без TLS
      final vlessNoTls = {
        'id': 'test-uuid',
        'add': 'test.example.com',
        'port': 443,
        'v': '2',
        'tls': 'none',
        'scy': 'none',
        'net': 'tcp',
      };
      expect(XrayConfig.fromJson(vlessNoTls).protocol, 'vless');

      // Тест 3: VMESS с alterId
      final vmessConfig = {
        'id': 'test-uuid',
        'add': 'test.example.com',
        'port': 443,
        'v': '2',
        'aid': 1,
        'tls': 'tls',
        'scy': 'auto',
        'net': 'ws',
      };
      expect(XrayConfig.fromJson(vmessConfig).protocol, 'vmess');

      // Тест 4: VLESS с TLS но aid=0
      final vlessTls = {
        'id': 'test-uuid',
        'add': 'test.example.com',
        'port': 443,
        'v': '2',
        'aid': 0,
        'tls': 'tls',
        'scy': 'none',
        'net': 'tcp',
      };
      expect(XrayConfig.fromJson(vlessTls).protocol, 'vless');
    });
  });
}
