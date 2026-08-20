import 'dart:convert';

import 'simple_vpn_api.dart';
import 'windows_sing_box_tun.dart';
import 'windows_split_tunnel_settings.dart';

class WindowsVlessConfigException implements Exception {
  const WindowsVlessConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

String buildWindowsVlessConfig(
  SimpleVpnConfig config, {
  WindowsSplitTunnelSettingsData splitTunnel =
      const WindowsSplitTunnelSettingsData(),
}) {
  final source = config.jsonConfig;
  final protocol = _requiredString(source, 'protocol').toLowerCase();
  if (protocol != 'vless') {
    throw const WindowsVlessConfigException(
      'Windows VLESS runtime received a non-VLESS profile',
    );
  }

  final network = _requiredString(source, 'net').toLowerCase();
  if (network != 'ws') {
    throw WindowsVlessConfigException(
      'Unsupported Windows VLESS transport: $network',
    );
  }

  final server = _requiredString(source, 'add');
  final uuid = _requiredString(source, 'id');
  final port = _requiredPort(source['port']);
  final path = _normalizedPath(source['path']?.toString());
  final host = source['host']?.toString().trim() ?? '';
  final security = source['tls']?.toString().trim().toLowerCase() ?? 'none';
  if (security != 'none' && security != 'tls') {
    throw WindowsVlessConfigException(
      'Unsupported Windows VLESS security: $security',
    );
  }

  final nodeIpv4 = config.server?.ipAddress.trim() ?? '';
  if (!_isIpv4(nodeIpv4)) {
    throw const WindowsVlessConfigException(
      'Windows VLESS TUN requires the node IPv4 address',
    );
  }

  final outbound = <String, dynamic>{
    'type': 'vless',
    'tag': 'proxy',
    'server': server,
    'server_port': port,
    'uuid': uuid,
    'transport': <String, dynamic>{
      'type': 'ws',
      'path': path,
      if (host.isNotEmpty) 'headers': <String, dynamic>{'Host': host},
    },
  };
  if (security == 'tls') {
    final sni = source['sni']?.toString().trim() ?? '';
    outbound['tls'] = <String, dynamic>{
      'enabled': true,
      'server_name': sni.isNotEmpty ? sni : (host.isNotEmpty ? host : server),
      'insecure': false,
    };
  }

  return jsonEncode(
    buildWindowsSingBoxTun(
      proxyOutbound: outbound,
      nodeIpv4: nodeIpv4,
      interfaceName: 'grani-vless',
      address: '172.20.0.1/30',
      splitTunnel: splitTunnel,
    ),
  );
}

String _requiredString(Map<String, dynamic> source, String key) {
  final value = source[key]?.toString().trim() ?? '';
  if (value.isEmpty) {
    throw WindowsVlessConfigException('VLESS $key is missing');
  }
  return value;
}

int _requiredPort(Object? raw) {
  final port = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
  if (port == null || port < 1 || port > 65535) {
    throw const WindowsVlessConfigException('VLESS port is invalid');
  }
  return port;
}

String _normalizedPath(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return '/';
  return value.startsWith('/') ? value : '/$value';
}

bool _isIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  return parts.every((part) {
    final number = int.tryParse(part);
    return number != null && number >= 0 && number <= 255;
  });
}
