import '../../config/app_config.dart';
import 'preferred_route_storage.dart';

/// Классификация запроса для единственной точки выбора origin ([EndpointRouter]).
enum RequestKind {
  auth,
  bootstrap,
  vpnControl,
  logging,
}

/// Волна bootstrap: [BootstrapWave.direct] оставлен для совместимости API; [AuthService] вызывает только hostname.
enum BootstrapWave {
  hostname,
  direct,
}

/// Решение маршрутизатора: не более двух баз и двух попыток на один логический HTTP-вызов.
class RouteDecision {
  final List<Uri> bases;
  final int maxAttempts;

  RouteDecision({
    required this.bases,
    required this.maxAttempts,
  })  : assert(bases.length <= 2),
        assert(maxAttempts <= 2),
        assert(maxAttempts >= 1),
        assert(bases.isNotEmpty),
        assert(
          bases.length == maxAttempts,
          'RouteDecision: bases и maxAttempts должны совпадать (иначе цикл ApiClient неконсистентен)',
        );
}

/// Единственная точка выбора API origin и числа попыток (см. network refactor plan).
class EndpointRouter {
  EndpointRouter._();

  /// Единая карта path → [RequestKind] (без размазывания по вызовам).
  /// Порядок веток важен: bootstrap и logs раньше общего `/vpn/`.
  static RequestKind resolveKind(String path) {
    final p = path.trim().toLowerCase();
    if (p.startsWith('/auth/')) return RequestKind.auth;
    if (p.startsWith('/vpn/bootstrap')) return RequestKind.bootstrap;
    if (p.startsWith('/vpn/logs')) return RequestKind.logging;
    return RequestKind.vpnControl;
  }

  /// См. [resolveKind] — алиас для обратной совместимости.
  static RequestKind inferRequestKind(String path) => resolveKind(path);

  /// Строит [RouteDecision] для одного вызова ApiClient. Для [RequestKind.bootstrap]
  /// обязателен [wave].
  static Future<RouteDecision> resolve({
    required String path,
    required RequestKind kind,
    BootstrapWave? wave,
  }) async {
    switch (kind) {
      case RequestKind.auth:
        assert(wave == null);
        final domain = Uri.parse(AppConfig.apiBaseUrl);
        final p = path.trim().toLowerCase();
        // Как vpnControl при деградации: refresh критичен после долгого оффлайна;
        // домен может не коннектиться, запасной путь — granilink HTTPS proxy :8444.
        if (p == '/auth/refresh-token') {
          return RouteDecision(
            bases: [domain, Uri.parse(AppConfig.apiVpnServerUrl8443)],
            maxAttempts: 2,
          );
        }
        return RouteDecision(
          bases: [domain],
          maxAttempts: 1,
        );
      case RequestKind.logging:
        assert(wave == null);
        return RouteDecision(
          bases: [Uri.parse(AppConfig.apiBaseUrl)],
          maxAttempts: 1,
        );
      case RequestKind.bootstrap:
        assert(
          wave != null,
          'bootstrap требует BootstrapWave (hostname | direct) — отдельный вызов из AuthService',
        );
        // Один origin: api.granilink.com (волны hostname/direct в AuthService оставлены для порядка попыток).
        return RouteDecision(
          bases: [Uri.parse(AppConfig.apiBaseUrl)],
          maxAttempts: 1,
        );
      case RequestKind.vpnControl:
        assert(wave == null);
        final domain = Uri.parse(AppConfig.apiBaseUrl);
        // Только при недавнем (< recentNetworkClassTtl) network-class сбое по доменной базе —
        // иначе один origin (детерминированно). См. PreferredRouteStorage.recentNetworkClassTtl.
        final recent = await PreferredRouteStorage.hasRecentNetworkClassFailure(
          AppConfig.apiBaseUrl,
        );
        if (recent) {
          return RouteDecision(
            bases: [domain, Uri.parse(AppConfig.apiVpnServerUrl8443)],
            maxAttempts: 2,
          );
        }
        return RouteDecision(
          bases: [domain],
          maxAttempts: 1,
        );
    }
  }
}
