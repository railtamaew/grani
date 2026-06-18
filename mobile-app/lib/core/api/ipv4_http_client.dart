import 'dart:io';

class _DnsCacheEntry {
  _DnsCacheEntry(this.address, this.savedAt);
  final InternetAddress address;
  final DateTime savedAt;
}

final Map<String, _DnsCacheEntry> _controlPlaneDnsCache = <String, _DnsCacheEntry>{};
const Duration _controlPlaneDnsCacheTtl = Duration(minutes: 3);

InternetAddress? _getCachedAddress(String host) {
  final key = host.trim().toLowerCase();
  final entry = _controlPlaneDnsCache[key];
  if (entry == null) return null;
  final age = DateTime.now().difference(entry.savedAt);
  if (age > _controlPlaneDnsCacheTtl) {
    _controlPlaneDnsCache.remove(key);
    return null;
  }
  return entry.address;
}

void _saveCachedAddress(String host, InternetAddress address) {
  final key = host.trim().toLowerCase();
  _controlPlaneDnsCache[key] = _DnsCacheEntry(address, DateTime.now());
}

/// Резолвинг с приоритетом IPv4, но без «тупика», когда A-only lookup пустой
/// (часто при активном VPN / Private DNS: первый запрос только IPv4 даёт [] или таймаут,
/// тогда как [InternetAddressType.any] сразу после — нормальный ответ).
Future<InternetAddress> _resolveForControlPlane(String host, int port) async {
  const lookupTimeout = Duration(seconds: 3);

  Future<List<InternetAddress>> safeLookup(InternetAddressType type) async {
    try {
      return await InternetAddress.lookup(host, type: type).timeout(lookupTimeout);
    } on SocketException {
      return const [];
    } catch (_) {
      return const [];
    }
  }

  final v4only = await safeLookup(InternetAddressType.IPv4);
  if (v4only.isNotEmpty) {
    final picked = v4only.first;
    _saveCachedAddress(host, picked);
    return picked;
  }

  List<InternetAddress> any;
  try {
    any = await InternetAddress.lookup(
      host,
      type: InternetAddressType.any,
    ).timeout(lookupTimeout);
  } on SocketException {
    final cached = _getCachedAddress(host);
    if (cached != null) return cached;
    rethrow;
  } catch (_) {
    final cached = _getCachedAddress(host);
    if (cached != null) return cached;
    rethrow;
  }

  if (any.isEmpty) {
    final cached = _getCachedAddress(host);
    if (cached != null) return cached;
    throw SocketException('Failed host lookup: $host', port: port);
  }
  any.sort((a, b) {
    if (a.type == b.type) return 0;
    if (a.type == InternetAddressType.IPv4) return -1;
    if (b.type == InternetAddressType.IPv4) return 1;
    return 0;
  });
  final picked = any.first;
  _saveCachedAddress(host, picked);
  return picked;
}

/// Фабрика HttpClient с принудительным IPv4 и ручным TLS для HTTPS.
///
/// Обходит проблему Flutter/Dart на Android: при наличии IPv6 система может
/// пытаться подключиться по IPv6 первым → таймаут ~10 с. connectionFactory
/// резолвит только A-записи и поднимает TLS вручную (HttpClient при своём
/// connectionFactory не оборачивает сокет в TLS).
///
/// [sniHostWhenConnectingByIp] — hostname для SNI при подключении по IP (один хост).
/// [sniHostForIp] — функция (ip) -> hostname для SNI; приоритет над sniHostWhenConnectingByIp при наличии.
HttpClient createIpv4PreferredHttpClient({
  bool Function(X509Certificate cert, String host, int port)? badCertificateCallback,
  String? sniHostWhenConnectingByIp,
  String? Function(String ip)? sniHostForIp,
}) {
  final client = HttpClient();
  // Control-plane requests must ignore OS/global HTTP proxy settings.
  // Otherwise some devices (or hostile Wi-Fi) route API calls via proxy and
  // introduce extra DNS/TLS failures unrelated to the VPN tunnel itself.
  client.findProxy = (_) => 'DIRECT';
  client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
    // Even if adapter passes proxy parameters, keep direct connect path.
    final port = uri.port;
    dynamic connectHost = uri.host;
    if (connectHost is String) {
      connectHost = await _resolveForControlPlane(connectHost, port);
    }
    final tcpTask = await Socket.startConnect(connectHost, port);
    final isHttps = uri.scheme == 'https';
    if (!isHttps) {
      return tcpTask;
    }
    final sniHost = _isLikelyIp(uri.host)
        ? (sniHostForIp?.call(uri.host) ?? sniHostWhenConnectingByIp ?? uri.host)
        : uri.host;
    final secureFuture = tcpTask.socket.then((socket) {
      return SecureSocket.secure(
        socket,
        host: sniHost,
        onBadCertificate: badCertificateCallback == null
            ? null
            : (cert) => badCertificateCallback(cert, uri.host, port),
      );
    });
    return ConnectionTask.fromSocket(secureFuture, tcpTask.cancel);
  };
  return client;
}

bool _isLikelyIp(String host) => InternetAddress.tryParse(host) != null;
