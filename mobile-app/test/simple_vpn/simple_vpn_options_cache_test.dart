import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_api.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_options_cache.dart';

void main() {
  final server = SimpleVpnServer(
    id: 12,
    name: 'Stockholm',
    country: 'Sweden',
    city: 'Stockholm',
    ipAddress: '203.0.113.12',
    wireguardPort: 443,
    currentUsers: 0,
    maxUsers: 100,
  );

  test('catalog cache is isolated by authenticated backend user', () {
    expect(
      simpleVpnOptionsCacheKeyForUser('1'),
      isNot(simpleVpnOptionsCacheKeyForUser('36')),
    );
    expect(
      simpleVpnOptionsCacheKeyForUser(' 36 '),
      '${simpleVpnOptionsCacheKey}_user_36',
    );
    expect(
      simpleVpnOptionsCacheKeyForUser(null),
      '${simpleVpnOptionsCacheKey}_user_anonymous',
    );
  });

  test('snapshot cache never invents rollout-gated AWG', () {
    final payload =
        buildSimpleVpnOptionsCachePayload(servers: <SimpleVpnServer>[
      server,
    ]);
    final protocols = payload['protocols']! as List<dynamic>;

    expect(
      protocols.map((item) => (item as Map<String, dynamic>)['id']),
      <String>['vless_ws', 'hysteria2'],
    );
  });

  test('authenticated catalog can explicitly cache AWG for a canary', () {
    final payload = buildSimpleVpnOptionsCachePayload(
      servers: <SimpleVpnServer>[server],
      protocols: <SimpleVpnProtocol>[
        ...defaultSimpleVpnProtocols(),
        SimpleVpnProtocol(
          id: 'graniwg',
          engine: 'amneziawg',
          status: 'active',
          role: 'primary',
        ),
      ],
    );
    final protocols = payload['protocols']! as List<dynamic>;

    expect(
      protocols.map((item) => (item as Map<String, dynamic>)['id']),
      <String>['vless_ws', 'hysteria2', 'graniwg'],
    );
  });
}
