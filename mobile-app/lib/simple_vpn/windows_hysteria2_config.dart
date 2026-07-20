import 'dart:convert';

import 'simple_vpn_api.dart';

class WindowsHysteria2ConfigException implements Exception {
  const WindowsHysteria2ConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

String buildWindowsHysteria2Config(SimpleVpnConfig config) {
  final decoded = _decodeConfig(config.config);
  final rawOutbounds = decoded['outbounds'];
  if (rawOutbounds is! List) {
    throw const WindowsHysteria2ConfigException(
      'Hysteria2 config does not contain outbounds',
    );
  }

  Map<String, dynamic>? outbound;
  for (final candidate in rawOutbounds.whereType<Map>()) {
    final map = Map<String, dynamic>.from(candidate);
    if (map['type']?.toString() == 'hysteria2') {
      outbound = map;
      break;
    }
  }
  if (outbound == null) {
    throw const WindowsHysteria2ConfigException(
      'Hysteria2 outbound is missing',
    );
  }

  final server = _requiredString(outbound, 'server');
  final password = _requiredString(outbound, 'password');
  final port = (outbound['server_port'] as num?)?.toInt() ?? 443;
  if (port < 1 || port > 65535) {
    throw const WindowsHysteria2ConfigException(
      'Hysteria2 server port is invalid',
    );
  }

  final rawTls = outbound['tls'];
  final tls = rawTls is Map
      ? Map<String, dynamic>.from(rawTls)
      : <String, dynamic>{};
  final sni = tls['server_name']?.toString().trim();
  final nodeIpv4 = config.server?.ipAddress.trim() ?? '';
  if (!_isIpv4(nodeIpv4)) {
    throw const WindowsHysteria2ConfigException(
      'Hysteria2 Windows TUN requires the node IPv4 address',
    );
  }

  final buffer = StringBuffer()
    ..writeln('server: ${_yamlScalar('$server:$port')}')
    ..writeln('auth: ${_yamlScalar(password)}')
    ..writeln('tls:')
    ..writeln('  sni: ${_yamlScalar(sni?.isNotEmpty == true ? sni! : server)}')
    ..writeln('  insecure: false');

  final rawObfs = outbound['obfs'];
  if (rawObfs is Map) {
    final obfs = Map<String, dynamic>.from(rawObfs);
    final type = obfs['type']?.toString().trim() ?? '';
    final obfsPassword = obfs['password']?.toString() ?? '';
    if (type.isNotEmpty && obfsPassword.isNotEmpty) {
      if (type != 'salamander' && type != 'gecko') {
        throw WindowsHysteria2ConfigException(
          'Unsupported Hysteria2 obfuscation: $type',
        );
      }
      buffer
        ..writeln('obfs:')
        ..writeln('  type: ${_yamlScalar(type)}')
        ..writeln('  $type:')
        ..writeln('    password: ${_yamlScalar(obfsPassword)}');
    }
  }

  buffer
    ..writeln('tun:')
    ..writeln('  name: ${_yamlScalar('grani-hy2')}')
    ..writeln('  mtu: 1280')
    ..writeln('  timeout: 5m')
    ..writeln('  address:')
    ..writeln('    ipv4: 100.100.100.101/30')
    ..writeln('    ipv6: ${_yamlScalar('2001::ffff:ffff:ffff:fff1/126')}')
    ..writeln('  route:')
    ..writeln('    ipv4: [0.0.0.0/0]')
    ..writeln('    ipv6: [${_yamlScalar('2000::/3')}]')
    ..writeln('    ipv4Exclude: [$nodeIpv4/32]');
  return buffer.toString();
}

Map<String, dynamic> _decodeConfig(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {
    // The public exception below deliberately does not include config secrets.
  }
  throw const WindowsHysteria2ConfigException(
    'Hysteria2 config is not valid JSON',
  );
}

String _requiredString(Map<String, dynamic> source, String key) {
  final value = source[key]?.toString().trim() ?? '';
  if (value.isEmpty) {
    throw WindowsHysteria2ConfigException('Hysteria2 $key is missing');
  }
  return value;
}

String _yamlScalar(String value) => jsonEncode(value);

bool _isIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  return parts.every((part) {
    final number = int.tryParse(part);
    return number != null && number >= 0 && number <= 255;
  });
}
