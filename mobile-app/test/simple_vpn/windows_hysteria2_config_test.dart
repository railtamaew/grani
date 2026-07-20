import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_api.dart';
import 'package:mobile_app/simple_vpn/windows_hysteria2_config.dart';

void main() {
  test('builds official Hysteria2 TUN config with node route exclusion', () {
    final yaml = buildWindowsHysteria2Config(
      _config(
        raw: '''
{"outbounds":[{"type":"hysteria2","server":"hy2-pl.granilink.com","server_port":443,"password":"secret:with-specials","tls":{"server_name":"hy2-pl.granilink.com"},"obfs":{"type":"salamander","password":"obfs-secret"}}]}
''',
      ),
    );

    expect(yaml, contains('server: "hy2-pl.granilink.com:443"'));
    expect(yaml, contains('auth: "secret:with-specials"'));
    expect(yaml, contains('type: "salamander"'));
    expect(yaml, contains('password: "obfs-secret"'));
    expect(yaml, contains('ipv4: [0.0.0.0/0]'));
    expect(yaml, contains('ipv4Exclude: [81.27.101.191/32]'));
    expect(yaml, contains('ipv6: ["2000::/3"]'));
  });

  test('rejects config without a numeric node IPv4 route exclusion', () {
    expect(
      () => buildWindowsHysteria2Config(
        _config(
          nodeIp: 'hy2-pl.granilink.com',
          raw:
              '{"outbounds":[{"type":"hysteria2","server":"hy2-pl.granilink.com","password":"secret"}]}',
        ),
      ),
      throwsA(isA<WindowsHysteria2ConfigException>()),
    );
  });

  test('does not leak malformed backend config through exception text', () {
    const secret = 'do-not-print-this-password';
    try {
      buildWindowsHysteria2Config(
        _config(raw: '{"password":"$secret"'),
      );
      fail('Expected malformed JSON to be rejected');
    } on WindowsHysteria2ConfigException catch (error) {
      expect(error.toString(), isNot(contains(secret)));
    }
  });
}

SimpleVpnConfig _config({
  required String raw,
  String nodeIp = '81.27.101.191',
}) {
  return SimpleVpnConfig(
    protocol: 'hysteria2',
    configType: 'sing-box',
    engine: 'hysteria2',
    serverName: 'Warsaw',
    server: SimpleVpnServer(
      id: 10,
      name: 'Warsaw',
      country: 'Poland',
      city: 'Warsaw',
      countryCode: 'PL',
      cityCode: 'warsaw',
      ipAddress: nodeIp,
      wireguardPort: 39060,
      currentUsers: 0,
      maxUsers: 100,
    ),
    configRevision: 'test-hy2',
    config: raw,
    jsonConfig: const <String, dynamic>{},
  );
}
