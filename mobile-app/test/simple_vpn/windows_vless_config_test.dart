import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_api.dart';
import 'package:mobile_app/simple_vpn/windows_vless_config.dart';

void main() {
  test('builds Windows sing-box VLESS WS TUN config', () {
    final decoded = jsonDecode(buildWindowsVlessConfig(_config())) as Map;
    final inbound = (decoded['inbounds'] as List).single as Map;
    final proxy = (decoded['outbounds'] as List).first as Map;
    final transport = proxy['transport'] as Map;

    expect(inbound['type'], 'tun');
    expect(inbound['interface_name'], 'grani-vless');
    expect(inbound['auto_route'], isTrue);
    expect(inbound['strict_route'], isTrue);
    expect(inbound['route_exclude_address'], <String>['203.0.113.10/32']);
    expect(proxy['type'], 'vless');
    expect(proxy['server'], '203.0.113.10');
    expect(proxy['server_port'], 8080);
    expect(proxy['uuid'], '31343a66-e3b5-41e3-99df-cd901f8e052b');
    expect(transport['type'], 'ws');
    expect(transport['path'], '/grani-ws');
    expect((transport['headers'] as Map)['Host'], '203.0.113.10');
    expect((decoded['route'] as Map)['auto_detect_interface'], isTrue);
    expect((decoded['route'] as Map)['final'], 'proxy');
  });

  test('adds strict TLS without exposing source config in errors', () {
    final config = _config(jsonOverrides: <String, dynamic>{
      'tls': 'tls',
      'sni': 'edge.example.com',
      'host': 'edge.example.com',
    });
    final decoded = jsonDecode(buildWindowsVlessConfig(config)) as Map;
    final proxy = (decoded['outbounds'] as List).first as Map;

    expect(proxy['tls'], <String, dynamic>{
      'enabled': true,
      'server_name': 'edge.example.com',
      'insecure': false,
    });
  });

  test('rejects unsupported transport before native runtime starts', () {
    final config = _config(jsonOverrides: <String, dynamic>{'net': 'grpc'});

    expect(
      () => buildWindowsVlessConfig(config),
      throwsA(
        isA<WindowsVlessConfigException>().having(
          (error) => error.message,
          'message',
          contains('Unsupported Windows VLESS transport'),
        ),
      ),
    );
  });
}

SimpleVpnConfig _config({Map<String, dynamic> jsonOverrides = const {}}) {
  final jsonConfig = <String, dynamic>{
    'protocol': 'vless',
    'add': '203.0.113.10',
    'port': '8080',
    'id': '31343a66-e3b5-41e3-99df-cd901f8e052b',
    'net': 'ws',
    'host': '203.0.113.10',
    'path': '/grani-ws',
    'tls': 'none',
    ...jsonOverrides,
  };
  return SimpleVpnConfig(
    protocol: 'vless_ws',
    configType: 'xray',
    engine: 'xray',
    serverName: 'Test node',
    server: SimpleVpnServer(
      id: 10,
      name: 'Test node',
      country: 'Test',
      city: 'Test',
      ipAddress: '203.0.113.10',
      wireguardPort: 51820,
      currentUsers: 0,
      maxUsers: 100,
    ),
    configRevision: 'test-vless',
    config: 'vless://redacted',
    jsonConfig: jsonConfig,
  );
}
