import 'simple_vpn_api.dart';

// v3 scopes the authenticated protocol catalog to the current backend user.
// A shared device may be used by an ordinary account and then by an AWG
// canary; reusing one global cache would leak the previous account's rollout
// decision into the next session.
const String simpleVpnOptionsCacheKey = 'simple_vpn_options_v3';
const Duration simpleVpnOptionsCacheTtl = Duration(days: 7);

String simpleVpnOptionsCacheKeyForUser(String? rawUserId) {
  final normalized = (rawUserId ?? '').trim().replaceAll(
        RegExp(r'[^A-Za-z0-9_.-]'),
        '_',
      );
  return '${simpleVpnOptionsCacheKey}_user_${normalized.isEmpty ? 'anonymous' : normalized}';
}

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
