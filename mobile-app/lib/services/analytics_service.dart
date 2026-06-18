import 'package:firebase_analytics/firebase_analytics.dart';
import '../core/logger/logger.dart';

class AnalyticsService {
  static final AnalyticsService _instance = AnalyticsService._internal();
  factory AnalyticsService() => _instance;
  AnalyticsService._internal();

  FirebaseAnalytics? _analyticsInstance;
  FirebaseAnalytics get _analytics => _analyticsInstance ??= FirebaseAnalytics.instance;
  final _logger = Logger();

  /// Успешная авторизация (Google / Email)
  Future<void> logLogin(String method) async {
    try {
      await _analytics.logLogin(loginMethod: method);
      _logger.info('analytics: login ($method)', 'AnalyticsService');
    } catch (e) {
      _logger.warning('analytics logLogin error: $e', 'AnalyticsService');
    }
  }

  /// Успешная оплата подписки
  Future<void> logPurchase({
    required String planName,
    required double amount,
    String currency = 'RUB',
    String? transactionId,
  }) async {
    try {
      await _analytics.logPurchase(
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
        'analytics: purchase $planName $amount $currency',
        'AnalyticsService',
      );
    } catch (e) {
      _logger.warning('analytics logPurchase error: $e', 'AnalyticsService');
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
      await _analytics.logSignUp(signUpMethod: method);
      _logger.info('analytics: sign_up ($method)', 'AnalyticsService');
    } catch (e) {
      _logger.warning('analytics logSignUp error: $e', 'AnalyticsService');
    }
  }

  /// Начало триала
  Future<void> logTrialStart() async {
    try {
      await _analytics.logEvent(name: 'trial_start');
      _logger.info('analytics: trial_start', 'AnalyticsService');
    } catch (e) {
      _logger.warning('analytics logTrialStart error: $e', 'AnalyticsService');
    }
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
      await _analytics.logEvent(
        name: 'vpn_data_verified',
        parameters: <String, Object>{
          'server_id': serverId,
          'protocol': protocol,
          'from_cache': fromCache ? 1 : 0,
          if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
          if (handshakeAgeSec != null) 'handshake_age_sec': handshakeAgeSec,
          if (rxBytes != null) 'rx_bytes': rxBytes,
          if (txBytes != null) 'tx_bytes': txBytes,
        },
      );
      _logger.info('analytics: vpn_data_verified server=$serverId protocol=$protocol', 'AnalyticsService');
    } catch (e) {
      _logger.warning('analytics logVpnDataVerified error: $e', 'AnalyticsService');
    }
  }

  /// Идентификация пользователя
  Future<void> setUserId(String? userId) async {
    try {
      await _analytics.setUserId(id: userId);
    } catch (e) {
      _logger.warning('analytics setUserId error: $e', 'AnalyticsService');
    }
  }
}
