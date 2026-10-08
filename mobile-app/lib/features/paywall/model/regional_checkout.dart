import 'package:intl/intl.dart';

import 'tariff_ui_model.dart';

class RegionalPlan {
  const RegionalPlan(this.days, this.amountMinor);
  final int days;
  final int amountMinor;

  TariffUiModel toTariff(String locale) {
    final months = {30: 1, 180: 6, 365: 12}[days]!;
    final format = NumberFormat.currency(
        locale: locale, name: 'RUB', symbol: '₽', decimalDigits: 2);
    final monthlyMinor = (amountMinor + months ~/ 2) ~/ months;
    return TariffUiModel(
      id: months == 1 ? '1_month' : '${months}_months',
      productId: 'wata_access_$days',
      periodMonths: months,
      periodDays: days,
      formattedMonthlyPrice: format.format(monthlyMinor / 100),
      formattedTotalPrice: format.format(amountMinor / 100),
      priceMicros: amountMinor * 10000,
      monthlyEquivalentMicros: monthlyMinor * 10000,
      currencyCode: 'RUB',
      illustrationNeutral:
          'assets/images/tariffs/plan_token_${months}_neutral.png',
      illustrationSelected:
          'assets/images/tariffs/plan_token_${months}_selected.png',
      isBestValue: months == 12,
    );
  }
}

class RegionalOrder {
  const RegionalOrder(
      {required this.id,
      required this.days,
      required this.amountMinor,
      required this.status,
      required this.expiresAt,
      required this.environment,
      this.blocksNewOrder,
      this.accessPending = false,
      this.checkoutUri});
  final String id;
  final int days;
  final int amountMinor;
  final String status;
  final DateTime expiresAt;
  final String environment;
  final Uri? checkoutUri;
  final bool? blocksNewOrder;
  final bool accessPending;

  bool get paid => status == 'paid' && !accessPending;
  bool get needsReview =>
      (status == 'expired' && blocksNewOrder != false) ||
      (const {'creating', 'create_unknown'}.contains(status) &&
          !expiresAt.isAfter(DateTime.now().toUtc()));
  bool get isPending =>
      accessPending ||
      const {'creating', 'create_unknown', 'pending', 'declined'}
          .contains(status);
  bool get canOpen =>
      isPending &&
      !accessPending &&
      checkoutUri != null &&
      expiresAt.isAfter(DateTime.now().toUtc());

  factory RegionalOrder.fromJson(Map<String, dynamic> json) {
    final id = json['order_id'];
    final days = json['duration_days'];
    final amount = json['amount_minor'];
    final status = json['status'];
    final isSandbox = json['sandbox'];
    final environment = isSandbox == true ? 'sandbox' : json['environment'];
    final expires = DateTime.tryParse(json['expires_at']?.toString() ?? '');
    final blocksNewOrder = json['blocks_new_order'];
    const statuses = {
      'creating',
      'create_unknown',
      'pending',
      'declined',
      'paid',
      'expired',
      'refunded',
      'refund_review'
    };
    if ((blocksNewOrder != null && blocksNewOrder is! bool) ||
        id is! String ||
        !uuidPattern.hasMatch(id) ||
        !((isSandbox == true && environment == 'sandbox') ||
            (isSandbox == false && environment == 'production')) ||
        !const {30, 180, 365}.contains(days) ||
        amount is! int ||
        amount <= 0 ||
        !statuses.contains(status) ||
        expires == null ||
        json['currency'] != 'RUB') {
      throw const FormatException('Invalid checkout order');
    }
    final url = json['checkout_url'];
    final uri = url is String ? Uri.tryParse(url) : null;
    if (url != null &&
        (uri == null || !isAllowedCheckoutUri(uri, environment))) {
      throw const FormatException('Invalid checkout destination');
    }
    return RegionalOrder(
        id: id,
        days: days as int,
        amountMinor: amount,
        status: status as String,
        environment: environment as String,
        blocksNewOrder: blocksNewOrder as bool?,
        accessPending: json['access_pending'] == true,
        expiresAt: expires.toUtc(),
        checkoutUri: uri);
  }

  static final uuidPattern = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
  static bool isAllowedCheckoutUri(Uri uri, String environment) =>
      uri.scheme == 'https' &&
      uri.host ==
          (environment == 'sandbox'
              ? 'payment-sandbox.wata.pro'
              : 'payment.wata.pro') &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      uri.pathSegments.length == 2 &&
      uri.pathSegments.first == 'pay-form' &&
      uuidPattern.hasMatch(uri.pathSegments.last);
}

class RegionalCheckoutOptions {
  const RegionalCheckoutOptions.googlePlay()
      : plans = const [],
        pendingOrder = null,
        environment = null,
        unavailableReason = null;
  const RegionalCheckoutOptions.wata(
      this.plans, this.pendingOrder, this.environment) : unavailableReason = null;
  const RegionalCheckoutOptions.unavailable(this.unavailableReason)
      : plans = const [], pendingOrder = null, environment = null;
  final List<RegionalPlan> plans;
  final RegionalOrder? pendingOrder;
  final String? environment;
  final String? unavailableReason;
  bool get unavailable => unavailableReason != null;
  bool get usesWata => plans.length == 3;

  factory RegionalCheckoutOptions.fromJson(Map<String, dynamic> json) {
    if (json['provider'] == 'unavailable') {
      final reason = json['reason'];
      return RegionalCheckoutOptions.unavailable(
          reason is String ? reason : 'regional_unavailable');
    }
    if (json['provider'] != 'wata') {
      return const RegionalCheckoutOptions.googlePlay();
    }
    final environment = json['environment'];
    if (environment != 'sandbox' && environment != 'production') {
      throw const FormatException('Invalid WATA environment');
    }
    final raw = json['plans'];
    if (raw is! List || raw.length != 3) {
      throw const FormatException('Invalid plans');
    }
    final plans = <RegionalPlan>[];
    for (final entry in raw) {
      if (entry is! Map ||
          !const {30, 180, 365}.contains(entry['duration_days']) ||
          entry['amount_minor'] is! int ||
          entry['amount_minor'] <= 0 ||
          entry['currency'] != 'RUB') {
        throw const FormatException('Invalid plan');
      }
      plans.add(RegionalPlan(
          entry['duration_days'] as int, entry['amount_minor'] as int));
    }
    if (plans.map((p) => p.days).toSet().length != 3) {
      throw const FormatException('Duplicate plan');
    }
    plans.sort((a, b) => a.days.compareTo(b.days));
    final pending = json['pending_order'];
    final parsedPending = pending is Map
        ? RegionalOrder.fromJson(Map<String, dynamic>.from(pending))
        : null;
    if (parsedPending != null && parsedPending.environment != environment) {
      throw const FormatException('Checkout environment mismatch');
    }
    return RegionalCheckoutOptions.wata(
        plans, parsedPending, environment as String);
  }
}
