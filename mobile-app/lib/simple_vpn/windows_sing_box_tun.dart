import 'windows_split_tunnel_settings.dart';

Map<String, dynamic> buildWindowsSingBoxTun({
  required Map<String, dynamic> proxyOutbound,
  required String nodeIpv4,
  required String interfaceName,
  required String address,
  WindowsSplitTunnelSettingsData splitTunnel =
      const WindowsSplitTunnelSettingsData(),
}) {
  final processes = splitTunnel.processNames;
  final directDomains = splitTunnel.directDomains
      .map((domain) => domain.startsWith('*.') ? domain.substring(2) : domain)
      .where((domain) => domain.isNotEmpty)
      .toList();
  final defaultDns = splitTunnel.isIncludeMode ? 'local-dns' : 'remote-dns';
  final selectedDns = splitTunnel.isIncludeMode ? 'remote-dns' : 'local-dns';
  final selectedOutbound = splitTunnel.isIncludeMode ? 'proxy' : 'direct';
  final finalOutbound = splitTunnel.isIncludeMode ? 'direct' : 'proxy';

  return <String, dynamic>{
    'log': <String, dynamic>{
      'level': 'info',
      'timestamp': true,
    },
    'dns': <String, dynamic>{
      'servers': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'https',
          'tag': 'remote-dns',
          'server': '1.1.1.1',
          'server_port': 443,
          'path': '/dns-query',
          'tls': <String, dynamic>{
            'enabled': true,
            'server_name': 'cloudflare-dns.com',
          },
          'detour': 'proxy',
        },
        <String, dynamic>{
          'type': 'local',
          'tag': 'local-dns',
        },
      ],
      if (processes.isNotEmpty)
        'rules': <Map<String, dynamic>>[
          <String, dynamic>{
            'process_name': processes,
            'action': 'route',
            'server': selectedDns,
          },
        ],
      'final': defaultDns,
      'strategy': 'ipv4_only',
      'reverse_mapping': true,
    },
    'inbounds': <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'tun',
        'tag': 'tun-in',
        'interface_name': interfaceName,
        'address': <String>[address],
        'mtu': 1280,
        'auto_route': true,
        'strict_route': true,
        'route_exclude_address': <String>['$nodeIpv4/32'],
        'stack': 'system',
      },
    ],
    'outbounds': <Map<String, dynamic>>[
      <String, dynamic>{...proxyOutbound, 'tag': 'proxy'},
      <String, dynamic>{'type': 'direct', 'tag': 'direct'},
    ],
    'route': <String, dynamic>{
      'auto_detect_interface': true,
      'default_domain_resolver': 'local-dns',
      'rules': <Map<String, dynamic>>[
        <String, dynamic>{'action': 'sniff'},
        <String, dynamic>{
          'protocol': 'dns',
          'action': 'hijack-dns',
        },
        <String, dynamic>{
          'ip_is_private': true,
          'action': 'route',
          'outbound': 'direct',
        },
        if (directDomains.isNotEmpty)
          <String, dynamic>{
            'domain_suffix': directDomains,
            'action': 'route',
            'outbound': 'direct',
          },
        if (processes.isNotEmpty)
          <String, dynamic>{
            'process_name': processes,
            'action': 'route',
            'outbound': selectedOutbound,
          },
      ],
      'final': finalOutbound,
    },
  };
}
