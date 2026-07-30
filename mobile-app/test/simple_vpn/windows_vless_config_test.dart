import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_api.dart';
import 'package:mobile_app/simple_vpn/windows_split_tunnel_settings.dart';
import 'package:mobile_app/simple_vpn/windows_vless_config.dart';

void main() {
  test('builds Windows sing-box VLESS WS TUN config', () {
    final decoded = jsonDecode(buildWindowsVlessConfig(_config())) as Map;
    final inbound = (decoded['inbounds'] as List).single as Map;
    final proxy = (decoded['outbounds'] as List).first as Map;
    final transport = proxy['transport'] as Map;
    final dns = decoded['dns'] as Map;
    final dnsServer = (dns['servers'] as List).first as Map;
    final route = decoded['route'] as Map;
    final routeRules = route['rules'] as List;

    expect(inbound['type'], 'tun');
    expect(inbound['interface_name'], 'grani-vless');
    expect(inbound['auto_route'], isTrue);
    expect(inbound['strict_route'], isTrue);
    expect(inbound['route_exclude_address'], <String>['203.0.113.10/32']);
    expect(proxy['type'], 'vless');
    expect(proxy['server'], '203.0.113.10');
    expect(proxy['server_port'], 8080);
    expect(proxy['uuid'], '31343a66-e3b5-41e3-99df-cd901f8e052b');
    expect(proxy.containsKey('network'), isFalse);
    expect(transport['type'], 'ws');
    expect(transport['path'], '/grani-ws');
    expect((transport['headers'] as Map)['Host'], '203.0.113.10');
    expect(dns['final'], 'remote-dns');
    expect(dns['strategy'], 'ipv4_only');
    expect(dns['reverse_mapping'], isTrue);
    expect(dnsServer['type'], 'https');
    expect(dnsServer['server'], '1.1.1.1');
    expect(dnsServer['detour'], 'proxy');
    expect(route['auto_detect_interface'], isTrue);
    expect(route['default_domain_resolver'], 'local-dns');
    expect(route['final'], 'proxy');
    expect(
      routeRules.whereType<Map>().any(
            (rule) =>
                rule['protocol'] == 'dns' && rule['action'] == 'hijack-dns',
          ),
      isTrue,
    );
    expect(
      routeRules.whereType<Map>().any(
            (rule) =>
                rule['ip_is_private'] == true &&
                rule['action'] == 'route' &&
                rule['outbound'] == 'direct',
          ),
      isTrue,
    );
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

  test('routes selected Windows processes and domains outside VLESS', () {
    final decoded = jsonDecode(
      buildWindowsVlessConfig(
        _config(),
        splitTunnel: const WindowsSplitTunnelSettingsData(
          processNames: <String>['chrome.exe'],
          directDomains: <String>['bank.example'],
        ),
      ),
    ) as Map;
    final route = decoded['route'] as Map;
    final rules = (route['rules'] as List).whereType<Map>().toList();
    final dns = decoded['dns'] as Map;

    expect(route['final'], 'proxy');
    expect(
      rules.any(
        (rule) =>
            (rule['process_name'] as List?)?.contains('chrome.exe') == true &&
            rule['action'] == 'route' &&
            rule['outbound'] == 'direct',
      ),
      isTrue,
    );
    expect(
      rules.any(
        (rule) =>
            (rule['domain_suffix'] as List?)?.contains('bank.example') ==
                true &&
            rule['action'] == 'route' &&
            rule['outbound'] == 'direct',
      ),
      isTrue,
    );
    expect((dns['rules'] as List).single['server'], 'local-dns');
  });

  test('routes only selected Windows processes through VLESS', () {
    final decoded = jsonDecode(
      buildWindowsVlessConfig(
        _config(),
        splitTunnel: const WindowsSplitTunnelSettingsData(
          mode: windowsSplitTunnelModeInclude,
          processNames: <String>['firefox.exe'],
        ),
      ),
    ) as Map;
    final route = decoded['route'] as Map;
    final rules = (route['rules'] as List).whereType<Map>().toList();
    final dns = decoded['dns'] as Map;

    expect(route['final'], 'direct');
    expect(
      rules.any(
        (rule) =>
            (rule['process_name'] as List?)?.contains('firefox.exe') == true &&
            rule['action'] == 'route' &&
            rule['outbound'] == 'proxy',
      ),
      isTrue,
    );
    expect(dns['final'], 'local-dns');
    expect((dns['rules'] as List).single['server'], 'remote-dns');
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
