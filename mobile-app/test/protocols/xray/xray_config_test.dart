import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/protocols/xray/models/xray_config.dart';
import 'dart:convert';

void main() {
  group('XrayConfig', () {
    group('toSingBoxJsonConfig', () {
      test('should not include inet4_route field in TUN inbound', () {
        // Arrange
        final config = XrayConfig(
          uuid: 'test-uuid',
          address: 'test.example.com',
          port: 443,
          protocol: 'vless',
          security: 'tls',
          network: 'tcp',
        );

        // Act
        final jsonString = config.toSingBoxJsonConfig();
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final inbounds = json['inbounds'] as List;
        final tunInbound = inbounds[0] as Map<String, dynamic>;

        // Assert
        expect(tunInbound.containsKey('inet4_route'), false,
            reason: 'inet4_route не должно присутствовать в конфигурации');
        expect(tunInbound.containsKey('auto_route'), true,
            reason: 'auto_route должно присутствовать в конфигурации');
        expect(tunInbound['auto_route'], true,
            reason: 'auto_route должно быть true');
      });

      test('should include required TUN inbound fields', () {
        // Arrange
        final config = XrayConfig(
          uuid: 'test-uuid',
          address: 'test.example.com',
          port: 443,
          protocol: 'vless',
          security: 'tls',
          network: 'tcp',
        );

        // Act
        final jsonString = config.toSingBoxJsonConfig();
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final inbounds = json['inbounds'] as List;
        final tunInbound = inbounds[0] as Map<String, dynamic>;

        // Assert
        expect(tunInbound['type'], 'tun');
        expect(tunInbound['tag'], 'tun-in');
        expect(tunInbound['mtu'], 1420);
        expect(tunInbound.containsKey('inet4_address'), true);
        // dns_address не поддерживается в TUN inbound для sing-box
        expect(tunInbound.containsKey('dns_address'), false);
        expect(tunInbound.containsKey('auto_route'), true);
        expect(tunInbound.containsKey('strict_route'), true);
      });
    });

    group('fromJson - protocol detection', () {
      test('should detect VLESS when tls is none', () {
        // Arrange
        final json = {
          'id': 'test-uuid',
          'add': 'test.example.com',
          'port': 443,
          'v': '2',
          'tls': 'none',
          'scy': 'none',
          'net': 'tcp',
        };

        // Act
        final config = XrayConfig.fromJson(json);

        // Assert
        expect(config.protocol, 'vless',
            reason: 'VLESS должен определяться когда tls=none');
      });

      test('should detect VLESS when REALITY (pbk present)', () {
        // Arrange
        final json = {
          'id': 'test-uuid',
          'add': 'test.example.com',
          'port': 443,
          'v': '2',
          'tls': 'reality',
          'scy': 'none',
          'net': 'tcp',
          'pbk': 'test-public-key',
          'sid': 'test-short-id',
        };

        // Act
        final config = XrayConfig.fromJson(json);

        // Assert
        expect(config.protocol, 'vless',
            reason: 'VLESS должен определяться когда есть pbk (REALITY)');
      });

      test('should detect VLESS when tls is reality', () {
        // Arrange
        final json = {
          'id': 'test-uuid',
          'add': 'test.example.com',
          'port': 443,
          'v': '2',
          'tls': 'reality',
          'scy': 'none',
          'net': 'tcp',
        };

        // Act
        final config = XrayConfig.fromJson(json);

        // Assert
        expect(config.protocol, 'vless',
            reason: 'VLESS должен определяться когда tls=reality');
      });

      test('should detect VMESS when v=2, tls!=none, and aid!=0', () {
        // Arrange
        final json = {
          'id': 'test-uuid',
          'add': 'test.example.com',
          'port': 443,
          'v': '2',
          'aid': 1, // alterId != 0
          'tls': 'tls',
          'scy': 'auto',
          'net': 'ws',
        };

        // Act
        final config = XrayConfig.fromJson(json);

        // Assert
        expect(config.protocol, 'vmess',
            reason: 'VMESS должен определяться когда v=2, tls!=none, и aid!=0');
      });

      test('should detect VLESS when v=2, tls=tls, but aid=0', () {
        // Arrange
        final json = {
          'id': 'test-uuid',
          'add': 'test.example.com',
          'port': 443,
          'v': '2',
          'aid': 0, // alterId = 0
          'tls': 'tls',
          'scy': 'none',
          'net': 'tcp',
        };

        // Act
        final config = XrayConfig.fromJson(json);

        // Assert
        expect(config.protocol, 'vless',
            reason: 'VLESS должен определяться когда aid=0 (даже если v=2)');
      });

      test('should detect VLESS when v=2, tls=tls, but aid is missing', () {
        // Arrange
        final json = {
          'id': 'test-uuid',
          'add': 'test.example.com',
          'port': 443,
          'v': '2',
          // aid отсутствует
          'tls': 'tls',
          'scy': 'none',
          'net': 'tcp',
        };

        // Act
        final config = XrayConfig.fromJson(json);

        // Assert
        expect(config.protocol, 'vless',
            reason: 'VLESS должен определяться по умолчанию когда aid отсутствует');
      });

      test('should detect VLESS when v is missing', () {
        // Arrange
        final json = {
          'id': 'test-uuid',
          'add': 'test.example.com',
          'port': 443,
          // v отсутствует
          'tls': 'tls',
          'scy': 'none',
          'net': 'tcp',
        };

        // Act
        final config = XrayConfig.fromJson(json);

        // Assert
        expect(config.protocol, 'vless',
            reason: 'VLESS должен определяться по умолчанию когда v отсутствует');
      });

      test('should detect VLESS for REALITY config from server', () {
        // Arrange - реальный пример из логов
        final json = {
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
        final config = XrayConfig.fromJson(json);

        // Assert
        expect(config.protocol, 'vless',
            reason: 'REALITY конфигурация должна определяться как VLESS');
        expect(config.realityPublicKey, 'Pyqln2OpBGGAJVXweJusMJAqzuqqH675fqF8Bdl3kGY');
        expect(config.realityShortId, '822c3e48');
      });
    });

    group('toSingBoxJsonConfig - protocol specific', () {
      test('should generate correct VLESS outbound', () {
        // Arrange
        final config = XrayConfig(
          uuid: 'test-uuid',
          address: 'test.example.com',
          port: 443,
          protocol: 'vless',
          security: 'tls',
          network: 'tcp',
        );

        // Act
        final jsonString = config.toSingBoxJsonConfig();
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final outbounds = json['outbounds'] as List;
        final proxyOutbound = outbounds[0] as Map<String, dynamic>;

        // Assert
        expect(proxyOutbound['type'], 'vless');
        // ✅ Новый формат sing-box: НЕТ settings.vnext, используются server/server_port
        expect(proxyOutbound.containsKey('settings'), false,
            reason: 'Поле settings не должно быть (старый формат Xray)');
        expect(proxyOutbound.containsKey('server'), true,
            reason: 'Поле server должно быть в новом формате sing-box');
        expect(proxyOutbound.containsKey('server_port'), true,
            reason: 'Поле server_port должно быть в новом формате sing-box');
        expect(proxyOutbound.containsKey('uuid'), true,
            reason: 'Поле uuid должно быть в новом формате sing-box');
      });

      test('should generate correct VMESS outbound', () {
        // Arrange
        final config = XrayConfig(
          uuid: 'test-uuid',
          address: 'test.example.com',
          port: 443,
          protocol: 'vmess',
          security: 'tls',
          network: 'ws',
        );

        // Act
        final jsonString = config.toSingBoxJsonConfig();
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final outbounds = json['outbounds'] as List;
        final proxyOutbound = outbounds[0] as Map<String, dynamic>;

        // Assert
        expect(proxyOutbound['type'], 'vmess');
        // ✅ Новый формат sing-box: НЕТ settings.vnext
        expect(proxyOutbound.containsKey('settings'), false,
            reason: 'Поле settings не должно быть (старый формат Xray)');
        expect(proxyOutbound.containsKey('server'), true);
        expect(proxyOutbound.containsKey('server_port'), true);
        expect(proxyOutbound.containsKey('uuid'), true);
      });
    });

    group('VMESS config conversion', () {
      test('should generate vmess JSON with security none', () {
        final config = XrayConfig(
          uuid: 'test-uuid',
          address: 'test.example.com',
          port: 443,
          protocol: 'vmess',
          security: 'none',
          network: 'tcp',
        );

        final json = config.toJson();

        expect(json['v'], '2');
        expect(json['aid'], '0');
        expect(json['tls'], 'none');
        expect(json['scy'], 'none');
        expect(json['net'], 'tcp');
      });

      test('should generate vmess URL with security none', () {
        final config = XrayConfig(
          uuid: 'test-uuid',
          address: 'test.example.com',
          port: 443,
          protocol: 'vmess',
          security: 'none',
          network: 'tcp',
        );

        final url = config.toConfigString();

        expect(url.startsWith('vmess://'), true);
        expect(url.contains('security=none'), true);
      });
    });

    group('toSingBoxJsonConfig - route section', () {
      test('should NOT include route section (libbox does not support it)', () {
        // Arrange
        final config = XrayConfig(
          uuid: 'test-uuid',
          address: 'test.example.com',
          port: 443,
          protocol: 'vless',
          security: 'tls',
          network: 'tcp',
        );

        // Act
        final jsonString = config.toSingBoxJsonConfig();
        final json = jsonDecode(jsonString) as Map<String, dynamic>;

        // Assert
        expect(json.containsKey('route'), false,
            reason: 'route не должно быть в sing-box конфигурации (libbox не поддерживает)');
      });
    });

    group('toXrayNativeJsonConfig', () {
      test('should generate XRay native format (not sing-box)', () {
        // Arrange
        final config = XrayConfig(
          uuid: 'test-uuid-1234',
          address: 'test.example.com',
          port: 443,
          protocol: 'vless',
          security: 'tls',
          network: 'tcp',
        );

        // Act
        final jsonString = config.toXrayNativeJsonConfig();
        final json = jsonDecode(jsonString) as Map<String, dynamic>;

        // Assert - проверяем структуру нативного XRay формата
        expect(json.containsKey('log'), true);
        expect(json.containsKey('inbounds'), true);
        expect(json.containsKey('outbounds'), true);
        expect(json.containsKey('routing'), true);
        
        // Проверяем, что это НЕ sing-box формат
        expect(json.containsKey('dns'), true,
            reason: 'dns должен быть в нативном формате XRay (избегаем таймаутов резолва внутри VPN)');
        final dns = json['dns'] as Map<String, dynamic>;
        expect(dns.containsKey('servers'), true);
        expect(dns['servers'], containsAll(['1.1.1.1', '9.9.9.9']));
        
        // Проверяем структуру inbounds (SOCKS, не tun)
        final inbounds = json['inbounds'] as List;
        expect(inbounds.length, greaterThan(0));
        final inbound = inbounds[0] as Map<String, dynamic>;
        expect(inbound['protocol'], 'socks',
            reason: 'Нативный XRay использует SOCKS, не tun');
        
        // Проверяем структуру outbounds (settings.vnext, не server/server_port)
        final outbounds = json['outbounds'] as List;
        expect(outbounds.length, greaterThan(0));
        final outbound = outbounds[0] as Map<String, dynamic>;
        expect(outbound.containsKey('protocol'), true,
            reason: 'Нативный XRay использует protocol, не type');
        expect(outbound.containsKey('settings'), true,
            reason: 'Нативный XRay использует settings.vnext');
        expect(outbound['settings'] is Map, true);
        final settings = outbound['settings'] as Map<String, dynamic>;
        expect(settings.containsKey('vnext'), true,
            reason: 'Нативный XRay использует settings.vnext');
      });

      test('should generate VLESS with vnext structure', () {
        // Arrange
        final config = XrayConfig(
          uuid: 'test-uuid-1234',
          address: 'server.example.com',
          port: 443,
          protocol: 'vless',
          security: 'tls',
          network: 'tcp',
          sni: 'example.com',
        );

        // Act
        final jsonString = config.toXrayNativeJsonConfig();
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final outbounds = json['outbounds'] as List;
        final proxyOutbound = outbounds[0] as Map<String, dynamic>;

        // Assert
        expect(proxyOutbound['protocol'], 'vless');
        expect(proxyOutbound.containsKey('settings'), true);
        final settings = proxyOutbound['settings'] as Map<String, dynamic>;
        expect(settings.containsKey('vnext'), true);
        
        final vnext = settings['vnext'] as List;
        expect(vnext.length, 1);
        final server = vnext[0] as Map<String, dynamic>;
        expect(server['address'], 'server.example.com');
        expect(server['port'], 443);
        expect(server.containsKey('users'), true);
        
        final users = server['users'] as List;
        expect(users.length, 1);
        final user = users[0] as Map<String, dynamic>;
        expect(user['id'], 'test-uuid-1234');
      });

      test('should generate VMESS with vnext structure', () {
        // Arrange
        final config = XrayConfig(
          uuid: 'test-uuid-5678',
          address: 'server.example.com',
          port: 443,
          protocol: 'vmess',
          security: 'tls',
          network: 'ws',
        );

        // Act
        final jsonString = config.toXrayNativeJsonConfig();
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final outbounds = json['outbounds'] as List;
        final proxyOutbound = outbounds[0] as Map<String, dynamic>;

        // Assert
        expect(proxyOutbound['protocol'], 'vmess');
        expect(proxyOutbound.containsKey('settings'), true);
        final settings = proxyOutbound['settings'] as Map<String, dynamic>;
        expect(settings.containsKey('vnext'), true);
        
        final vnext = settings['vnext'] as List;
        expect(vnext.length, 1);
        final server = vnext[0] as Map<String, dynamic>;
        expect(server['address'], 'server.example.com');
        expect(server['port'], 443);
        
        final users = server['users'] as List;
        expect(users.length, 1);
        final user = users[0] as Map<String, dynamic>;
        expect(user['id'], 'test-uuid-5678');
        expect(user['alterId'], 0);
      });

      test('should generate REALITY configuration', () {
        // Arrange
        final config = XrayConfig(
          uuid: 'test-uuid-reality',
          address: 'server.example.com',
          port: 443,
          protocol: 'vless',
          security: 'reality',
          network: 'tcp',
          sni: 'www.google.com',
          realityPublicKey: 'test-public-key-123',
          realityShortId: 'test-short-id',
        );

        // Act
        final jsonString = config.toXrayNativeJsonConfig();
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final outbounds = json['outbounds'] as List;
        final proxyOutbound = outbounds[0] as Map<String, dynamic>;

        // Assert
        expect(proxyOutbound.containsKey('streamSettings'), true);
        final streamSettings = proxyOutbound['streamSettings'] as Map<String, dynamic>;
        expect(streamSettings['security'], 'reality');
        expect(streamSettings.containsKey('realitySettings'), true);
        
        final realitySettings = streamSettings['realitySettings'] as Map<String, dynamic>;
        expect(realitySettings['publicKey'], 'test-public-key-123');
        expect(realitySettings['shortId'], 'test-short-id');
        expect(realitySettings['serverName'], 'www.google.com');
      });

      test('should include routing section', () {
        // Arrange
        final config = XrayConfig(
          uuid: 'test-uuid',
          address: 'test.example.com',
          port: 443,
          protocol: 'vless',
          security: 'tls',
          network: 'tcp',
        );

        // Act
        final jsonString = config.toXrayNativeJsonConfig();
        final json = jsonDecode(jsonString) as Map<String, dynamic>;

        // Assert
        expect(json.containsKey('routing'), true,
            reason: 'Нативный XRay должен иметь routing секцию');
        final routing = json['routing'] as Map<String, dynamic>;
        expect(routing.containsKey('rules'), true);
        final rules = routing['rules'] as List;
        expect(rules.length, greaterThan(0));
      });

      test('should route api.granilink.com through proxy (bypass mobile network blocks)', () {
        // Arrange: API идёт через proxy — обход блокировок в мобильных сетях
        final config = XrayConfig(
          uuid: 'test-uuid',
          address: 'test.example.com',
          port: 443,
          protocol: 'vless',
          security: 'tls',
          network: 'tcp',
        );

        // Act
        final jsonString = config.toXrayNativeJsonConfig();
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final rules = json['routing']['rules'] as List;

        // Assert: нет правила api.granilink.com -> direct (API трафик идёт через proxy/туннель)
        final apiDirectRule = rules.cast<Map<String, dynamic>>().where((r) {
          if (r['domain'] != null) {
            final domains = r['domain'] as List;
            return domains.any((d) =>
                d.toString().contains('api.granilink.com') ||
                d.toString().contains('granilink.com'));
          }
          if (r['ip'] != null) {
            return (r['ip'] as List).contains('159.223.199.122');
          }
          return false;
        });
        expect(apiDirectRule, isEmpty, reason: 'API должен идти через proxy, не direct');
      });

      test('should include server address direct rule to prevent routing loop', () {
        // Arrange: сервер по IP (45.12.132.94) — трафик к нему не должен идти через proxy
        final config = XrayConfig(
          uuid: 'test-uuid',
          address: '45.12.132.94',
          port: 4443,
          protocol: 'vless',
          security: 'reality',
          network: 'tcp',
          realityPublicKey: 'pk',
          realityShortId: 'sid',
        );

        // Act
        final jsonString = config.toXrayNativeJsonConfig();
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final rules = json['routing']['rules'] as List;

        // Assert: первое правило — direct для IP сервера
        final serverRule = rules[0] as Map<String, dynamic>;
        expect(serverRule['outboundTag'], 'direct');
        expect(serverRule['ip'], contains('45.12.132.94'));
      });

      test('should include DNS servers direct rule so resolution works', () {
        // Arrange
        final config = XrayConfig(
          uuid: 'test-uuid',
          address: '10.0.0.1',
          port: 443,
          protocol: 'vless',
          security: 'tls',
          network: 'tcp',
        );

        // Act
        final jsonString = config.toXrayNativeJsonConfig();
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final rules = json['routing']['rules'] as List;

        // Assert: есть правило с IP DNS-серверов -> direct (1.1.1.1, 8.8.8.8 и т.д.)
        final dnsRule = rules.cast<Map<String, dynamic>>().firstWhere(
          (r) =>
              r['ip'] != null &&
              (r['ip'] as List).contains('1.1.1.1') &&
              (r['ip'] as List).contains('8.8.8.8'),
          orElse: () => <String, dynamic>{},
        );
        expect(dnsRule.isNotEmpty, true);
        expect(dnsRule['outboundTag'], 'direct');
        expect(dnsRule['ip'], containsAll(['1.1.1.1', '9.9.9.9', '8.8.8.8']));
      });
    });
  });
}
