import 'dart:math';
import '../core/storage/shared_preferences_holder.dart';

import '../features/paywall/model/regional_checkout.dart';

typedef RegionalBillingRequest = Future<Map<String, dynamic>> Function(
    String path, Map<String, dynamic>? body);

class RegionalCheckoutUnavailable implements Exception {
  const RegionalCheckoutUnavailable();
}

/// New clients use a fresh server decision over the direct network. The legacy
/// constructor preserves the v60 contract for compatibility regression tests.
class RegionalCheckoutService {
  RegionalCheckoutService(
      {required this.readCountry,
      required this.request,
      Future<void> Function(String)? saveIntent,
      Future<String?> Function()? loadIntent,
      Future<void> Function(String)? saveReturnOrder,
      Future<String?> Function()? loadReturnOrder})
      : _saveIntent = saveIntent ?? _persistIntent,
        _loadIntent = loadIntent ?? _readIntent,
        _saveReturnOrder = saveReturnOrder ?? _persistReturnOrder,
        _loadReturnOrder = loadReturnOrder ?? _readReturnOrder;
  RegionalCheckoutService.origin(
      {required this.request,
      Future<void> Function(String)? saveIntent,
      Future<String?> Function()? loadIntent,
      Future<void> Function(String)? saveReturnOrder,
      Future<String?> Function()? loadReturnOrder})
      : readCountry = _noPlayCountry,
        _saveIntent = saveIntent ?? _persistIntent,
        _loadIntent = loadIntent ?? _readIntent,
        _saveReturnOrder = saveReturnOrder ?? _persistReturnOrder,
        _loadReturnOrder = loadReturnOrder ?? _readReturnOrder {
    _usesOrigin = true;
  }
  bool _usesOrigin = false;
  bool _usesWebsite = false;

  /// Desktop checkout uses the same account and tariffs as the GRANI website.
  /// A desktop has no Google Play billing-country or native Android transport.
  RegionalCheckoutService.website(
      {required this.request,
      Future<void> Function(String)? saveIntent,
      Future<String?> Function()? loadIntent,
      Future<void> Function(String)? saveReturnOrder,
      Future<String?> Function()? loadReturnOrder})
      : readCountry = _noPlayCountry,
        _saveIntent = saveIntent ?? _persistIntent,
        _loadIntent = loadIntent ?? _readIntent,
        _saveReturnOrder = saveReturnOrder ?? _persistReturnOrder,
        _loadReturnOrder = loadReturnOrder ?? _readReturnOrder {
    _usesWebsite = true;
  }
  bool get requiresStoreCountry => !_usesOrigin && !_usesWebsite;
  DateTime? handoffExpiresAt;
  static Future<String?> _noPlayCountry() async => null;
  final Future<void> Function(String) _saveIntent;
  final Future<String?> Function() _loadIntent;
  static Future<void> _persistIntent(String id) async {
    await (await getSharedPreferences()).setString(_intentKey, id);
  }

  static Future<String?> _readIntent() async =>
      (await getSharedPreferences()).getString(_intentKey);
  final Future<String?> Function() readCountry;
  final RegionalBillingRequest request;

  static Uri websiteCheckoutUri(int days) {
    if (!const {30, 180, 365}.contains(days)) {
      throw ArgumentError.value(days, 'days', 'Unknown GRANI plan');
    }
    return Uri.https('granilink.com', '/ru/checkout', {'plan': '$days'});
  }

  static const _intentKey = 'grani_website_checkout_intent_v1';
  static const _returnOrderKey = 'grani_payment_return_order_v1';
  final Future<void> Function(String) _saveReturnOrder;
  final Future<String?> Function() _loadReturnOrder;
  static Future<void> _persistReturnOrder(String id) async =>
      (await getSharedPreferences()).setString(_returnOrderKey, id);
  static Future<String?> _readReturnOrder() async =>
      (await getSharedPreferences()).getString(_returnOrderKey);

  /// A public routing ID is not payment proof and never changes the intent.
  static Future<void> rememberPaymentReturn(String? id) async {
    await _persistReturnOrder(
        id != null && RegionalOrder.uuidPattern.hasMatch(id) ? id : '');
  }

  Future<Map<String, dynamic>?> websitePaymentResultContext() async {
    final id = await _loadReturnOrder();
    if (id == null || !RegionalOrder.uuidPattern.hasMatch(id)) {
      return websiteCheckoutContext();
    }
    final result =
        await request('/payments/wata/live/checkout/orders/$id/context', null);
    if ((result['order'] as Map?)?['order_id'] != id) {
      throw const RegionalCheckoutUnavailable();
    }
    return result;
  }

  Future<void> acknowledgePaymentResult(Map<String, dynamic> result) async {
    final id = (result['order'] as Map?)?['order_id'];
    if (id == await _loadReturnOrder()) await _saveReturnOrder('');
    // An old return must not erase a newer purchase opened in another window.
    if (result['intent_id'] == await _loadIntent()) await _saveIntent('');
  }

  Future<void> markPaymentResultSeen(String id) async {
    if (!RegionalOrder.uuidPattern.hasMatch(id)) return;
    try {
      await request('/payments/wata/live/checkout/orders/$id/seen', {})
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Best effort timing only; this request can never grant access.
    }
  }

  Future<Uri> prepareWebsiteCheckout(
      {required int days, required int amountMinor}) async {
    final requestedAt = DateTime.now().toUtc();
    String? country;
    if (requiresStoreCountry) {
      country = await readCountry().timeout(const Duration(seconds: 8));
      if (country != 'RU') throw const RegionalCheckoutUnavailable();
    }
    final response = await request(
        _usesWebsite
            ? '/payments/wata/website/handoff'
            : _usesOrigin
                ? '/payments/wata/live/checkout/origin/handoff'
                : '/payments/wata/live/checkout/handoff',
        {
          if (requiresStoreCountry) 'play_country': country,
          'duration_days': days,
          'expected_amount_minor': amountMinor,
        });
    final id = response['intent_id'];
    final uri = Uri.tryParse(response['checkout_url']?.toString() ?? '');
    if (id is! String ||
        !RegionalOrder.uuidPattern.hasMatch(id) ||
        response['duration_days'] != days ||
        response['amount_minor'] != amountMinor ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'granilink.com' ||
        uri.path != '/ru/checkout' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.hasQuery ||
        !RegExp(r'^handoff=[A-Za-z0-9_-]{43}$').hasMatch(uri.fragment)) {
      throw const RegionalCheckoutUnavailable();
    }
    // Only a public intent ID is persisted. Never store the single-use code.
    await _saveIntent(id);
    await _saveReturnOrder('');
    // The server's code lifetime is three minutes. Starting this clock before
    // the request makes the display conservative when the network is slow.
    handoffExpiresAt = requestedAt.add(const Duration(minutes: 3));
    return uri;
  }

  Future<bool> hasWebsiteIntent() async =>
      RegionalOrder.uuidPattern.hasMatch((await _loadIntent()) ?? '');

  Future<void> acknowledgeWebsiteIntent() async => _saveIntent('');

  Future<Map<String, dynamic>?> websiteCheckoutContext() async {
    final id = await _loadIntent();
    if (id == null || !RegionalOrder.uuidPattern.hasMatch(id)) return null;
    final response =
        await request('/payments/wata/live/checkout/intents/$id', null);
    if (response['intent_id'] != id) throw const RegionalCheckoutUnavailable();
    return response;
  }

  Future<({int? days, RegionalOrder? order})?> websiteIntent() async {
    final response = await websiteCheckoutContext();
    if (response == null) return null;
    final value = response['order'];
    final days = response['duration_days'];
    return (
      days: days is int && const {30, 180, 365}.contains(days) ? days : null,
      order: value == null
          ? null
          : RegionalOrder.fromJson({
              ...Map<String, dynamic>.from(value as Map),
              'access_pending': response['state'] == 'updating_access',
            })
    );
  }

  Future<RegionalOrder?> websiteIntentOrder() async =>
      (await websiteIntent())?.order;

  Future<RegionalCheckoutOptions> resolve() async {
    if (_usesWebsite) {
      try {
        final json = await request('/payments/wata/website/options', {})
            .timeout(const Duration(seconds: 15));
        if (json['routing_version'] != 1 ||
            !const {'wata', 'unavailable'}.contains(json['provider'])) {
          throw const RegionalCheckoutUnavailable();
        }
        final options = RegionalCheckoutOptions.fromJson(json);
        if (options.usesWata && options.environment != 'production') {
          throw const RegionalCheckoutUnavailable();
        }
        return options;
      } catch (_) {
        return const RegionalCheckoutOptions.unavailable(
            'regional_unavailable');
      }
    }
    if (_usesOrigin) {
      try {
        final json = await request('/payments/wata/origin/options', {})
            .timeout(const Duration(seconds: 15));
        if (json['routing_version'] != 2 ||
            !const {'google_play', 'wata', 'unavailable'}
                .contains(json['provider'])) {
          return const RegionalCheckoutOptions.unavailable(
              'region_unavailable');
        }
        return RegionalCheckoutOptions.fromJson(json);
      } catch (_) {
        return const RegionalCheckoutOptions.unavailable('region_unavailable');
      }
    }
    var russianCountryConfirmed = false;
    try {
      var country = await readCountry().timeout(const Duration(seconds: 8));
      // BillingClient can be temporarily unavailable after a browser trip.
      // Retry missing input once; a valid non-RU result is never replaced.
      if (country == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        country = await readCountry().timeout(const Duration(seconds: 4));
      }
      if (country == null || !RegExp(r'^[A-Z]{2}$').hasMatch(country)) {
        return const RegionalCheckoutOptions.unavailable('country_required');
      }
      if (country != 'RU') return const RegionalCheckoutOptions.googlePlay();
      russianCountryConfirmed = true;
      final json = await request(
              '/payments/wata/regional/options', {'play_country': country})
          .timeout(const Duration(seconds: 10));
      final options = RegionalCheckoutOptions.fromJson(json);
      if (!options.usesWata && !options.unavailable) {
        return const RegionalCheckoutOptions.unavailable(
            'regional_unavailable');
      }
      return options;
    } catch (_) {
      // Unknown input is not a foreign country; a Russian provider failure is
      // not permission to replace the selected method with Google Play.
      return RegionalCheckoutOptions.unavailable(russianCountryConfirmed
          ? 'temporarily_unavailable'
          : 'country_required');
    }
  }

  Future<RegionalOrder> create(
      {required int days,
      required int amountMinor,
      required String idempotencyKey,
      String expectedEnvironment = 'sandbox'}) async {
    // Production website orders are created by its Pay action, never by the
    // desktop or QR presentation. A refresh only creates a new login handoff.
    if (_usesWebsite) throw const RegionalCheckoutUnavailable();
    String? country;
    if (!_usesOrigin) {
      country = await readCountry().timeout(const Duration(seconds: 8));
      if (country != 'RU') throw const RegionalCheckoutUnavailable();
    }
    final json = await request(
        _usesOrigin
            ? '/payments/wata/origin/orders'
            : '/payments/wata/regional/orders',
        {
          if (!_usesOrigin) 'play_country': country,
          'duration_days': days,
          'expected_amount_minor': amountMinor,
          'idempotency_key': idempotencyKey,
          'expected_environment': expectedEnvironment,
        });
    final order = RegionalOrder.fromJson(json);
    if (order.days != days ||
        order.amountMinor != amountMinor ||
        order.environment != expectedEnvironment) {
      throw const RegionalCheckoutUnavailable();
    }
    return order;
  }

  Future<RegionalOrder> status(String id,
      {String expectedEnvironment = 'sandbox'}) async {
    if (!RegionalOrder.uuidPattern.hasMatch(id)) {
      throw const RegionalCheckoutUnavailable();
    }
    final prefix = expectedEnvironment == 'production'
        ? '/payments/wata/live/orders'
        : '/payments/wata/orders';
    var order = RegionalOrder.fromJson(await request('$prefix/$id', null));
    if (order.id != id || order.environment != expectedEnvironment) {
      throw const RegionalCheckoutUnavailable();
    }
    if ((expectedEnvironment == 'production' &&
            const {
              'pending',
              'declined',
              'expired',
              'creating',
              'create_unknown'
            }.contains(order.status)) ||
        (const {'creating', 'create_unknown'}.contains(order.status) &&
            order.expiresAt.isAfter(DateTime.now().toUtc()))) {
      try {
        final reconciled =
            RegionalOrder.fromJson(await request('$prefix/$id/reconcile', {}));
        if (reconciled.id == id) order = reconciled;
      } catch (_) {
        // Backend rate limits reconciliation; retain the original order.
      }
    }
    return order;
  }

  Future<RegionalOrder?> latestProductionOrder() async {
    final response = await request('/payments/wata/live/orders/latest', null)
        .timeout(const Duration(seconds: 10));
    final value = response['order'];
    if (value == null) return null;
    final order =
        RegionalOrder.fromJson(Map<String, dynamic>.from(value as Map));
    if (order.environment != 'production') {
      throw const RegionalCheckoutUnavailable();
    }
    return order;
  }

  static String newIdempotencyKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
