import 'simple_vpn_api.dart';

const String simpleVpnOptionsCacheKey = 'simple_vpn_options_v1';
const Duration simpleVpnOptionsCacheTtl = Duration(days: 7);

List<SimpleVpnProtocol> defaultSimpleVpnProtocols() => <SimpleVpnProtocol>[
      SimpleVpnProtocol(
        id: 'vless_ws',
        engine: 'xray',
        status: 'active',
        role: 'primary',
      ),
      SimpleVpnProtocol(
        id: 'hysteria2',
        engine: 'hysteria2',
        status: 'active',
        role: 'fallback',
      ),
      SimpleVpnProtocol(
        id: 'graniwg',
        engine: 'amneziawg',
        status: 'active',
        role: 'fallback',
      ),
    ];

List<SimpleVpnServer> simpleVpnServersFromSnapshot(Object? rawServers) {
  if (rawServers is! List) return const <SimpleVpnServer>[];
  final servers = <SimpleVpnServer>[];
  for (final item in rawServers) {
    if (item is! Map) continue;
    try {
      final server = SimpleVpnServer.fromJson(Map<String, dynamic>.from(item));
      if (server.id > 0) {
        servers.add(server);
      }
    } catch (_) {
      // Snapshot entries are best-effort cache hydration. Bad rows must not
      // block post-auth preparation.
    }
  }
  return List<SimpleVpnServer>.unmodifiable(servers);
}

Map<String, dynamic> buildSimpleVpnOptionsCachePayload({
  required List<SimpleVpnServer> servers,
  List<SimpleVpnProtocol>? protocols,
  DateTime? cachedAt,
}) {
  return <String, dynamic>{
    'servers': servers.map((server) => server.toJson()).toList(),
    'protocols': (protocols ?? defaultSimpleVpnProtocols())
        .map((protocol) => protocol.toJson())
        .toList(),
    'cached_at': (cachedAt ?? DateTime.now()).toIso8601String(),
  };
}
