import 'package:connectivity_plus/connectivity_plus.dart';

/// Таймауты HTTP с учётом сети: на мобильном интернете обычно короче connect/receive
/// для быстрого перебора баз; bootstrap чуть дольше (см. [bootstrap]), чтобы реже
/// обрывать медленный, но рабочий путь.
class NetworkTimeouts {
  NetworkTimeouts._();

  static Future<bool> _isMobileNetwork() async {
    final results = await Connectivity().checkConnectivity();
    return results.contains(ConnectivityResult.mobile);
  }

  /// POST /auth/refresh-token — чуть мягче connect, чем общий authCritical:
  /// после долгого сна часто первый TCP к домену медленный; второй hop (IP) в [EndpointRouter].
  static Future<({Duration connect, Duration send, Duration receive})>
      authRefreshToken() async {
    if (await _isMobileNetwork()) {
      return (
        connect: const Duration(seconds: 12),
        send: const Duration(seconds: 10),
        receive: const Duration(seconds: 28),
      );
    }
    return (
      connect: const Duration(seconds: 10),
      send: const Duration(seconds: 10),
      receive: const Duration(seconds: 22),
    );
  }

  static Future<({Duration connect, Duration send, Duration receive})>
      authCritical() async {
    if (await _isMobileNetwork()) {
      return (
        connect: const Duration(seconds: 8),
        send: const Duration(seconds: 8),
        receive: const Duration(seconds: 28),
      );
    }
    return (
      connect: const Duration(seconds: 8),
      send: const Duration(seconds: 10),
      receive: const Duration(seconds: 22),
    );
  }

  /// POST /auth/send-code — согласовано с [ControlPlaneClient] BaseOptions; без клиентского retry.
  static Future<({Duration connect, Duration send, Duration receive})>
      authSendCode() async {
    return (
      connect: const Duration(seconds: 5),
      send: const Duration(seconds: 10),
      receive: const Duration(seconds: 12),
    );
  }

  /// POST /auth/verify-code — один запрос, без повтора (одноразовый код).
  static Future<({Duration connect, Duration send, Duration receive})>
      authVerifyCode() async {
    return (
      connect: const Duration(seconds: 5),
      send: const Duration(seconds: 10),
      receive: const Duration(seconds: 12),
    );
  }

  /// Bootstrap / перебор баз (последовательный fallback, если нужен запас).
  static Future<({Duration connect, Duration send, Duration receive})>
      bootstrap() async {
    if (await _isMobileNetwork()) {
      return (
        connect: const Duration(seconds: 8),
        send: const Duration(seconds: 6),
        receive: const Duration(seconds: 10),
      );
    }
    return (
      connect: const Duration(seconds: 8),
      send: const Duration(seconds: 10),
      receive: const Duration(seconds: 12),
    );
  }

  /// Параллельный race bootstrap: быстрый отказ → следующая волна (hostname, затем IP).
  static Future<({Duration connect, Duration send, Duration receive})>
      bootstrapFast() async {
    if (await _isMobileNetwork()) {
      return (
        connect: const Duration(seconds: 3),
        send: const Duration(seconds: 3),
        receive: const Duration(seconds: 6),
      );
    }
    return (
      connect: const Duration(seconds: 3),
      send: const Duration(seconds: 4),
      receive: const Duration(seconds: 8),
    );
  }

  /// Типичные VPN API (register/connect/disconnect и т.д.).
  static Future<({Duration connect, Duration send, Duration receive})>
      vpnApi() async {
    if (await _isMobileNetwork()) {
      return (
        connect: const Duration(seconds: 8),
        send: const Duration(seconds: 8),
        receive: const Duration(seconds: 14),
      );
    }
    return (
      connect: const Duration(seconds: 8),
      send: const Duration(seconds: 10),
      receive: const Duration(seconds: 15),
    );
  }

  /// Read-heavy API для уже авторизованного пользователя (devices/servers/status).
  /// На мобильной сети делаем мягче, чтобы снизить ложные timeout при слабом LTE.
  static Future<({Duration connect, Duration send, Duration receive})>
      vpnApiReadHeavy() async {
    if (await _isMobileNetwork()) {
      return (
        connect: const Duration(seconds: 10),
        send: const Duration(seconds: 10),
        receive: const Duration(seconds: 22),
      );
    }
    return (
      connect: const Duration(seconds: 8),
      send: const Duration(seconds: 10),
      receive: const Duration(seconds: 18),
    );
  }

  /// Верхняя граница ожидания /vpn/status (wall-clock).
  static Future<Duration> vpnStatusWallTimeout() async {
    if (await _isMobileNetwork()) {
      return const Duration(seconds: 14);
    }
    return const Duration(seconds: 20);
  }

  /// Google callback, verify purchase — длиннее receive.
  static Future<({Duration connect, Duration send, Duration receive})>
      authHeavy() async {
    if (await _isMobileNetwork()) {
      return (
        connect: const Duration(seconds: 6),
        send: const Duration(seconds: 10),
        // Google callback на LTE иногда >18s до первого байта (см. receiveTimeout в логах).
        receive: const Duration(seconds: 32),
      );
    }
    return (
      connect: const Duration(seconds: 8),
      send: const Duration(seconds: 15),
      receive: const Duration(seconds: 25),
    );
  }

  /// POST /payments/google-play/verify — на сервере вызывается Publisher API; на LTE даём запас receive.
  static Future<({Duration connect, Duration send, Duration receive})>
      paymentsGooglePlayVerify() async {
    if (await _isMobileNetwork()) {
      return (
        connect: const Duration(seconds: 10),
        send: const Duration(seconds: 12),
        receive: const Duration(seconds: 35),
      );
    }
    return (
      connect: const Duration(seconds: 8),
      send: const Duration(seconds: 15),
      receive: const Duration(seconds: 30),
    );
  }

  /// Xray create-client: короткий connect, умеренный receive (SSH на сервере).
  /// При синхронном apply (Celery недоступен) может занимать дольше, но для UX
  /// ограничиваем потолок и быстро переходим к контролируемому retry/fail-fast.
  /// На мобильной сети connect=10 — операторы часто медленно устанавливают соединение.
  static Future<({Duration connect, Duration send, Duration receive})>
      xrayCreateClientFirst() async {
    if (await _isMobileNetwork()) {
      return (
        connect: const Duration(seconds: 12),
        send: const Duration(seconds: 12),
        receive: const Duration(seconds: 35),
      );
    }
    return (
      connect: const Duration(seconds: 10),
      send: const Duration(seconds: 20),
      receive: const Duration(seconds: 35),
    );
  }

  /// POST /vpn/session/prepare — бюджет согласован с create_xray_client на ноде (часто 5–7+ с)
  /// и [XrayConnectionHandler] wall-clock отменой (~22 с), плюс пауза перед второй попыткой.
  static Future<({Duration connect, Duration send, Duration receive})>
      xraySessionPrepareFirst() async {
    return (
      connect: const Duration(seconds: 8),
      send: const Duration(seconds: 15),
      receive: const Duration(seconds: 22),
    );
  }

  static Future<({Duration connect, Duration send, Duration receive})>
      xraySessionPrepareRetry() async {
    return (
      connect: const Duration(seconds: 8),
      send: const Duration(seconds: 15),
      receive: const Duration(seconds: 22),
    );
  }

  static Future<({Duration connect, Duration send, Duration receive})>
      xrayCreateClientRetry() async {
    if (await _isMobileNetwork()) {
      return (
        connect: const Duration(seconds: 12),
        send: const Duration(seconds: 12),
        receive: const Duration(seconds: 30),
      );
    }
    return (
      connect: const Duration(seconds: 10),
      send: const Duration(seconds: 20),
      receive: const Duration(seconds: 30),
    );
  }

  /// Wall-clock для операций на экране «лимит устройств» (список / удаление).
  /// Оборачивает [VpnService.fetchDevicesWithAuth] / [VpnService.deleteDeviceWithAuth]
  /// — это отдельный от Dio лимит; короткие 4 с давали ложные таймауты на LTE.
  /// Согласовано по порядку величины с [vpnApiReadHeavy].
  static Future<Duration> deviceLimitWallOperationTimeout() async {
    if (await _isMobileNetwork()) {
      return const Duration(seconds: 35);
    }
    return const Duration(seconds: 28);
  }
}
