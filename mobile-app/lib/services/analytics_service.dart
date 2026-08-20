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
          params: {'method': method, 'source_surface': 'desktop_auth'},
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
      await InstallAttributionService.instance.logLifecycleEvent(
        'trial_started',
      );
      _logger.info('analytics: trial_start', 'AnalyticsService');
    } catch (e) {
      _logger.warning('analytics logTrialStart error: $e', 'AnalyticsService');
    }
  }

  static const Set<String> _paywallEvents = {
    'paywall_view',
    'product_details_loaded',
    'plan_selected',
    'purchase_cta_click',
    'purchase_cta_tap',
    'billing_flow_started',
    'billing_flow_launch',
    'billing_flow_opened',
    'purchase_result',
    'billing_user_canceled',
    'billing_pending',
    'billing_error',
    'purchase_received',
    'purchase_verification_started',
    'purchase_verified',
    'entitlement_granted',
    'purchase_success_view',
    'restore_purchase_tap',
    'restore_purchase_result',
  };

  Future<void> logPaywallView({Map<String, Object>? parameters}) {
    if (_isWindows) {
      return _windows.logEvent(
        'paywall_view',
        params: {
          'source_surface': 'desktop_subscription',
          if (parameters != null) ...parameters,
        },
      );
    }
    return InstallAttributionService.instance.logLifecycleEvent(
      'paywall_view',
      extra: parameters,
      once: false,
    );
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

  Future<void> logPaywallEvent(
    String name, {
    required Map<String, Object> parameters,
  }) {
    assert(_paywallEvents.contains(name), 'Unsupported paywall event: $name');
    if (!_paywallEvents.contains(name)) return Future<void>.value();
    if (_isWindows) {
      return _windows.logEvent(name, params: parameters);
    }
    return InstallAttributionService.instance.logLifecycleEvent(
      name,
      extra: parameters,
      once: false,
    );
  }

  Future<void> _logMobileEvent(
    String name, {
    Map<String, Object>? parameters,
  }) async {
    try {
      if (!_isFirebaseSupported) return;
      await _analytics.logEvent(name: name, parameters: parameters);
      _logger.info('analytics: $name', 'AnalyticsService');
    } catch (e) {
      _logger.warning('analytics $name error: $e', 'AnalyticsService');
    }
  }

  Future<void> logConnectTap({
    required String sourceSurface,
    required String protocol,
    String? connectionSessionId,
  }) {
    return _logMobileEvent(
      'connect_tap',
      parameters: <String, Object>{
        'source_surface': sourceSurface,
        'protocol': protocol,
        if (connectionSessionId != null && connectionSessionId.isNotEmpty)
          'connection_session_id': connectionSessionId,
      },
    );
  }

  Future<void> logVpnPermissionShown({
    required String sourceSurface,
    String? connectionSessionId,
  }) {
    return _logMobileEvent(
      'vpn_permission_shown',
      parameters: <String, Object>{
        'source_surface': sourceSurface,
        if (connectionSessionId != null && connectionSessionId.isNotEmpty)
          'connection_session_id': connectionSessionId,
      },
    );
  }

  Future<void> logVpnPermissionResult({
    required bool granted,
    required String sourceSurface,
    required bool promptShown,
    String? connectionSessionId,
  }) {
    return _logMobileEvent(
      granted ? 'vpn_permission_granted' : 'vpn_permission_denied',
      parameters: <String, Object>{
        'source_surface': sourceSurface,
        'prompt_shown': promptShown ? 1 : 0,
        if (connectionSessionId != null && connectionSessionId.isNotEmpty)
          'connection_session_id': connectionSessionId,
      },
    );
  }

  Future<void> logNotificationPermissionStatusChecked({
    required String sourceSurface,
    required bool enabled,
    required bool runtimePermissionRequired,
    required bool runtimePermissionGranted,
    required bool promptAttempted,
    required int sdkInt,
  }) {
    return _logMobileEvent(
      'notification_permission_status_checked',
      parameters: <String, Object>{
        'source_surface': sourceSurface,
        'enabled': enabled ? 1 : 0,
        'runtime_permission_required': runtimePermissionRequired ? 1 : 0,
        'runtime_permission_granted': runtimePermissionGranted ? 1 : 0,
        'prompt_attempted': promptAttempted ? 1 : 0,
        'android_sdk_int': sdkInt,
      },
    );
  }

  Future<void> logNotificationPermissionAlreadyGranted({
    required String sourceSurface,
  }) {
    return _logMobileEvent(
      'notification_permission_already_granted',
      parameters: <String, Object>{'source_surface': sourceSurface},
    );
  }

  Future<void> logNotificationPermissionPrompted({
    required String sourceSurface,
  }) {
    return _logMobileEvent(
      'notification_permission_prompted',
      parameters: <String, Object>{'source_surface': sourceSurface},
    );
  }

  Future<void> logNotificationPermissionResult({
    required bool granted,
    required String sourceSurface,
  }) {
    return _logMobileEvent(
      granted
          ? 'notification_permission_granted'
          : 'notification_permission_denied',
      parameters: <String, Object>{'source_surface': sourceSurface},
    );
  }

  Future<void> logNotificationPermissionDeferred({
    required String sourceSurface,
  }) {
    return _logMobileEvent(
      'notification_permission_deferred',
      parameters: <String, Object>{'source_surface': sourceSurface},
    );
  }

  Future<void> logNotificationPermissionSettingsOffer({
    required String sourceSurface,
  }) {
    return _logMobileEvent(
      'notification_settings_offer',
      parameters: <String, Object>{'source_surface': sourceSurface},
    );
  }

  Future<void> logNotificationPermissionSettingsOpened({
    required String sourceSurface,
  }) {
    return _logMobileEvent(
      'notification_settings_opened',
      parameters: <String, Object>{'source_surface': sourceSurface},
    );
  }

  Future<void> logLifecycleMessageOpen({
    required String campaignId,
    required String sourceSurface,
  }) {
    return _logMobileEvent(
      'lifecycle_message_open',
      parameters: <String, Object>{
        'campaign_id': campaignId,
        'source_surface': sourceSurface,
      },
    );
  }

  Future<void> logVpnConnectStart({
    required int serverId,
    required String protocol,
    required String sourceSurface,
    String? connectionSessionId,
  }) {
    final parameters = <String, Object>{
      'server_id': serverId,
      'protocol': protocol,
      'source_surface': sourceSurface,
      if (connectionSessionId != null && connectionSessionId.isNotEmpty)
        'connection_session_id': connectionSessionId,
    };
    if (_isWindows) {
      return _windows.logEvent('vpn_connect_start', params: parameters);
    }
    return _logMobileEvent('vpn_connect_start', parameters: parameters);
  }

  Future<void> logVpnConnectResult({
    required String result,
    required String failureStage,
    required int elapsedMs,
    required String protocol,
    required String sourceSurface,
    required int serverId,
    String? connectionSessionId,
    String? errorFamily,
  }) {
    final parameters = <String, Object>{
      'result': result,
      'failure_stage': failureStage,
      'elapsed_ms': elapsedMs,
      'protocol': protocol,
      'source_surface': sourceSurface,
      'server_id': serverId,
      if (connectionSessionId != null && connectionSessionId.isNotEmpty)
        'connection_session_id': connectionSessionId,
      if (errorFamily != null && errorFamily.isNotEmpty)
        'error_family': errorFamily,
    };
    if (_isWindows) {
      return _windows.logEvent('vpn_connect_result', params: parameters);
    }
    return _logMobileEvent('vpn_connect_result', parameters: parameters);
  }

  /// Milestones inside one connection attempt. This separates local tunnel
  /// setup from the later proof that protected traffic actually passes.
  Future<void> logVpnConnectionPhase({
    required String phase,
    required int elapsedMs,
    required String protocol,
    required String sourceSurface,
    String? connectionSessionId,
  }) {
    return _logMobileEvent(
      'vpn_connection_phase',
      parameters: <String, Object>{
        'phase': phase,
        'elapsed_ms': elapsedMs,
        'protocol': protocol,
        'source_surface': sourceSurface,
        if (connectionSessionId != null && connectionSessionId.isNotEmpty)
          'connection_session_id': connectionSessionId,
      },
    );
  }

  /// Low-cardinality signal for configuration/control-plane preparation.
  /// Detailed errors remain in backend client logs.
  Future<void> logVpnProtocolPrewarm({
    required String protocol,
    required String result,
    required int elapsedMs,
    required String sourceSurface,
    String? failureFamily,
  }) {
    return _logMobileEvent(
      'vpn_protocol_prewarm',
      parameters: <String, Object>{
        'protocol': protocol,
        'result': result,
        'elapsed_ms': elapsedMs,
        'source_surface': sourceSurface,
        if (failureFamily != null && failureFamily.isNotEmpty)
          'failure_family': failureFamily,
      },
    );
  }

  /// Emitted only after a previously committed tunnel is confirmed down and
  /// no explicit disconnect/cancel operation owns the transition.
  Future<void> logVpnUnexpectedDisconnect({
    required String protocol,
    required String disconnectSource,
    required String lifecycleState,
    required String sessionAgeBucket,
    required bool hadVerifiedTraffic,
  }) {
    return _logMobileEvent(
      'vpn_unexpected_disconnect',
      parameters: <String, Object>{
        'protocol': protocol,
        'disconnect_source': disconnectSource,
        'lifecycle_state': lifecycleState,
        'session_age_bucket': sessionAgeBucket,
        'had_verified_traffic': hadVerifiedTraffic ? 1 : 0,
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
        'AnalyticsService',
      );
    } catch (e) {
      _logger.warning(
        'analytics logVpnDataVerified error: $e',
        'AnalyticsService',
      );
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
      _logger.warning('analytics appInstanceId error: $e', 'AnalyticsService');
    }

    try {
      final sessionId = await _analytics.getSessionId();
      if (sessionId != null && sessionId > 0) {
        identity['firebase_session_id'] = sessionId;
      }
    } catch (e) {
      _logger.warning('analytics getSessionId error: $e', 'AnalyticsService');
    }

    return identity;
  }
}
