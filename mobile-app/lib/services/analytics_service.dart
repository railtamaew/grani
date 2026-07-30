import 'dart:io';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

import '../core/logger/logger.dart';
import 'install_attribution_service.dart';
import 'windows_analytics_transport.dart';

class AnalyticsService {
  static final AnalyticsService _instance = AnalyticsService._internal();
  factory AnalyticsService() => _instance;
  AnalyticsService._internal();

  FirebaseAnalytics? _analyticsInstance;
  FirebaseAnalytics get _analytics =>
      _analyticsInstance ??= FirebaseAnalytics.instance;
  final _logger = Logger();
  final _windows = WindowsAnalyticsTransport.instance;

  bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  bool get _isFirebaseSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> initialize({String? userId}) async {
    if (_isWindows) {
      await _windows.initialize(userId: userId);
    }
  }

  /// Успешная авторизация (Google / Email)
  Future<void> logLogin(String method) async {
    try {
      if (_isWindows) {
        await _windows.logEvent(
          'login',
          params: {
            'method': method,
            'source_surface': 'desktop_auth',
          },
        );
        return;
      }
      if (!_isFirebaseSupported) return;
      await _analytics.logLogin(loginMethod: method);
      _logger.info('analytics: login ($method)', 'AnalyticsService');
    } catch (e) {
      _logger.warning('analytics logLogin error: $e', 'AnalyticsService');
    }
  }

  /// Возврат средств / отмена подписки
  Future<void> logRefund({
    required String planName,
    required double amount,
    String currency = 'RUB',
    String? transactionId,
  }) async {
    try {
      if (!_isFirebaseSupported) return;
      await _analytics.logRefund(
        currency: currency,
        value: amount,
        transactionId: transactionId,
        items: [
          AnalyticsEventItem(
            itemName: planName,
            itemCategory: 'subscription',
            price: amount,
            currency: currency,
            quantity: 1,
          ),
        ],
      );
      _logger.info(
        'analytics: refund $planName $amount $currency',
        'AnalyticsService',
      );
    } catch (e) {
      _logger.warning('analytics logRefund error: $e', 'AnalyticsService');
    }
  }

  /// Регистрация нового пользователя
  Future<void> logSignUp(String method) async {
    try {
      if (!_isFirebaseSupported) return;
      await _analytics.logSignUp(signUpMethod: method);
      _logger.info('analytics: sign_up ($method)', 'AnalyticsService');
    } catch (e) {
      _logger.warning('analytics logSignUp error: $e', 'AnalyticsService');
    }
  }

  /// Начало триала
  Future<void> logTrialStart() async {
    try {
      if (!_isFirebaseSupported) return;
      await _analytics.logEvent(name: 'trial_start');
      await InstallAttributionService.instance
          .logLifecycleEvent('trial_started');
      _logger.info('analytics: trial_start', 'AnalyticsService');
    } catch (e) {
      _logger.warning('analytics logTrialStart error: $e', 'AnalyticsService');
    }
  }

  Future<void> logPaywallView() {
    if (_isWindows) {
      return _windows.logEvent(
        'paywall_view',
        params: {'source_surface': 'desktop_subscription'},
      );
    }
    return InstallAttributionService.instance.logLifecycleEvent('paywall_view');
  }

  Future<void> logPurchaseCompleted(String productId) {
    if (_isWindows) return Future<void>.value();
    return InstallAttributionService.instance.logLifecycleEvent(
      'purchase_completed',
      extra: {'product_id': productId},
      once: false,
    );
  }

  Future<void> logFirstConnectionSuccess(String protocol) {
    if (_isWindows) return Future<void>.value();
    return InstallAttributionService.instance.logLifecycleEvent(
      'first_connection_success',
      extra: {'protocol': protocol},
    );
  }

  Future<void> logVpnConnectStart({
    required int serverId,
    required String protocol,
    required String sourceSurface,
  }) {
    if (!_isWindows) return Future<void>.value();
    return _windows.logEvent(
      'vpn_connect_start',
      params: {
        'server_id': serverId,
        'protocol': protocol,
        'source_surface': sourceSurface,
      },
    );
  }

  /// Реальный GRANIwg dataplane подтвержден backend-проверкой на VPN-ноде.
  Future<void> logVpnDataVerified({
    required int serverId,
    required String protocol,
    String? sessionId,
    int? handshakeAgeSec,
    int? rxBytes,
    int? txBytes,
    bool fromCache = false,
  }) async {
    try {
      if (_isWindows) {
        await _windows.logEvent(
          'vpn_data_verified',
          params: <String, Object?>{
            'server_id': serverId,
            'protocol': protocol,
            'from_cache': fromCache,
            'verification_source': 'client_tun',
          },
        );
        return;
      }
      if (!_isFirebaseSupported) return;
      await _analytics.logEvent(
        name: 'vpn_data_verified',
        parameters: <String, Object>{
          'server_id': serverId,
          'protocol': protocol,
          'from_cache': fromCache ? 1 : 0,
          if (sessionId != null && sessionId.isNotEmpty)
            'session_id': sessionId,
          if (handshakeAgeSec != null) 'handshake_age_sec': handshakeAgeSec,
          if (rxBytes != null) 'rx_bytes': rxBytes,
          if (txBytes != null) 'tx_bytes': txBytes,
        },
      );
      _logger.info(
          'analytics: vpn_data_verified server=$serverId protocol=$protocol',
          'AnalyticsService');
    } catch (e) {
      _logger.warning(
          'analytics logVpnDataVerified error: $e', 'AnalyticsService');
    }
  }

  /// Идентификация пользователя
  Future<void> setUserId(String? userId) async {
    try {
      if (_isWindows) {
        await _windows.setUserId(userId);
        return;
      }
      if (!_isFirebaseSupported) return;
      await _analytics.setUserId(id: userId);
    } catch (e) {
      _logger.warning('analytics setUserId error: $e', 'AnalyticsService');
    }
  }

  /// Identity used to attach backend Measurement Protocol events to the same
  /// Firebase app instance and analytics session as client-side events.
  Future<Map<String, dynamic>> getBackendMeasurementIdentity() async {
    final identity = <String, dynamic>{};
    if (!_isFirebaseSupported) return identity;

    try {
      final appInstanceId = await _analytics.appInstanceId;
      if (appInstanceId != null && appInstanceId.isNotEmpty) {
        identity['firebase_app_instance_id'] = appInstanceId;
      }
    } catch (e) {
      _logger.warning(
        'analytics appInstanceId error: $e',
        'AnalyticsService',
      );
    }

    try {
      final sessionId = await _analytics.getSessionId();
      if (sessionId != null && sessionId > 0) {
        identity['firebase_session_id'] = sessionId;
      }
    } catch (e) {
      _logger.warning(
        'analytics getSessionId error: $e',
        'AnalyticsService',
      );
    }

    return identity;
  }
}
