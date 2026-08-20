import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';

import '../config/subscription_products.dart';
import '../l10n/localized_messages.dart';

enum BillingPurchaseStatus { pending, purchased, canceled, error }

class BillingPurchaseEvent {
  const BillingPurchaseEvent({
    required this.status,
    required this.productId,
    this.purchaseToken,
    this.orderId,
    this.responseCode,
    this.recovered = false,
  });

  final BillingPurchaseStatus status;
  final String productId;
  final String? purchaseToken;
  final String? orderId;
  final String? responseCode;
  final bool recovered;

  bool get hasVerificationData =>
      purchaseToken != null && purchaseToken!.isNotEmpty;
}

/// Сервис покупки подписок через Google Play (только Android).
/// Инициализация магазина, загрузка продуктов, запуск покупки, ожидание результата по purchaseStream.
class SubscriptionService extends ChangeNotifier {
  SubscriptionService() {
    if (_isAndroid) {
      _subscription = InAppPurchase.instance.purchaseStream.listen(
        _onPurchaseUpdate,
        onError: _onPurchaseError,
      );
    }
  }

  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// Stable non-PII identifier for Google Play's obfuscatedAccountId.
  /// Backend independently computes the same SHA-256 value.
  static String? obfuscatedAccountIdFor(String? userId) {
    final normalized = userId?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    return sha256.convert(utf8.encode('grani:user:$normalized')).toString();
  }

  StreamSubscription<List<PurchaseDetails>>? _subscription;
  final InAppPurchase _store = InAppPurchase.instance;
  final StreamController<BillingPurchaseEvent> _purchaseEvents =
      StreamController<BillingPurchaseEvent>.broadcast();

  List<ProductDetails> _products = [];
  bool _isAvailable = false;
  bool _isLoading = false;
  String? _errorMessage;
  bool _lastRecoveryHadError = false;

  Completer<bool>? _pendingPurchaseCompleter;
  String? _pendingProductId;

  /// Восстановленные покупки (для определения текущей активной подписки при апгрейде).
  final List<PurchaseDetails> _restoredPurchases = [];

  /// Данные последней успешной покупки для верификации на бэкенде.
  Map<String, String>? _lastPurchaseForVerification;

  /// Таймаут ожидания результата покупки (защита от зависания при закрытии Billing).
  /// Play Billing sheet often stays open >15s; short timeouts cause false failures
  /// and skip verify while the purchase still completes on the stream.
  static const Duration purchaseTimeout = Duration(seconds: 120);

  /// Данные для верификации последней успешной покупки.
  /// Вызывать сразу после buy() вернул true — отправить на бэкенд POST /api/payments/google-play/verify.
  Map<String, String>? get lastPurchaseForVerification =>
      _lastPurchaseForVerification;

  List<ProductDetails> get products => List.unmodifiable(_products);
  bool get isAvailable => _isAvailable;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  Stream<BillingPurchaseEvent> get purchaseEvents => _purchaseEvents.stream;
  bool get hasPurchaseInFlight => _pendingProductId != null;
  bool get lastRecoveryHadError => _lastRecoveryHadError;

  /// Поддерживается ли покупка на текущей платформе (сейчас только Android).
  static bool get supported => _isAndroid;

  /// Инициализация и загрузка продуктов. Вызывать при старте экрана подписки.
  Future<void> initialize() async {
    if (!_isAndroid) {
      _isAvailable = false;
      notifyListeners();
      return;
    }
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _isAvailable = await _store.isAvailable();
      if (!_isAvailable) {
        _errorMessage = LocalizedMessages.storeUnavailable;
        _isLoading = false;
        notifyListeners();
        return;
      }
      final response =
          await _store.queryProductDetails(SubscriptionProducts.all.toSet());
      if (response.notFoundIDs.isNotEmpty) {
        debugPrint(
            'SubscriptionService: продукты не найдены: ${response.notFoundIDs}');
      }
      _products = response.productDetails;
      _errorMessage = response.error?.message;
    } catch (e) {
      debugPrint('SubscriptionService: ошибка инициализации: $e');
      _errorMessage = e.toString();
      _products = [];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Запуск покупки по product id. Возвращает true при успешной покупке (доставка через purchaseStream).
  Future<bool> buy(
    String productId, {
    String? applicationUserName,
  }) async {
    if (!_isAndroid || !_isAvailable) {
      return false;
    }
    final product = _products.cast<ProductDetails?>().firstWhere(
          (p) => p!.id == productId,
          orElse: () => null,
        );
    if (product == null) {
      debugPrint('SubscriptionService: продукт не найден: $productId');
      return false;
    }

    debugPrint('SubscriptionService: buy() start productId=$productId');

    _lastPurchaseForVerification = null;
    _pendingProductId = productId;
    _pendingPurchaseCompleter = Completer<bool>();

    final param = GooglePlayPurchaseParam(
      productDetails: product,
      applicationUserName: applicationUserName,
    );
    final launchOk = await _store.buyNonConsumable(purchaseParam: param);
    if (!launchOk) {
      debugPrint('SubscriptionService: buy() launch failed');
      _pendingProductId = null;
      _pendingPurchaseCompleter!.complete(false);
      _pendingPurchaseCompleter = null;
      return false;
    }

    try {
      final result = await _raceWithTimeout(
        _pendingPurchaseCompleter!.future,
        purchaseTimeout,
        onTimeout: () {
          debugPrint(
              'SubscriptionService: buy() timeout after ${purchaseTimeout.inSeconds}s');
          _completePending(false);
        },
      );
      debugPrint(
          'SubscriptionService: buy() end productId=$productId result=$result');
      return result;
    } finally {
      _pendingProductId = null;
      _pendingPurchaseCompleter = null;
    }
  }

  /// Buy a repeatable paid-access extension.
  ///
  /// autoConsume is deliberately disabled: the backend first verifies the
  /// token, grants the exact number of days, and then consumes the purchase
  /// through Android Publisher API. This prevents both replay and entitlement
  /// loss when the network fails between Play Billing and our backend.
  Future<bool> buyExtension(
    String productId, {
    String? applicationUserName,
  }) async {
    if (!_isAndroid ||
        !_isAvailable ||
        !SubscriptionProducts.isExtension(productId)) {
      return false;
    }
    final product = _products.cast<ProductDetails?>().firstWhere(
          (p) => p!.id == productId,
          orElse: () => null,
        );
    if (product == null) {
      debugPrint(
          'SubscriptionService: extension product not found: $productId');
      return false;
    }

    debugPrint(
        'SubscriptionService: buyExtension() start productId=$productId');
    _lastPurchaseForVerification = null;
    _pendingProductId = productId;
    _pendingPurchaseCompleter = Completer<bool>();

    final param = GooglePlayPurchaseParam(
      productDetails: product,
      applicationUserName: applicationUserName,
    );
    final launchOk = await _store.buyConsumable(
      purchaseParam: param,
      autoConsume: false,
    );
    if (!launchOk) {
      debugPrint('SubscriptionService: buyExtension() launch failed');
      _pendingProductId = null;
      _pendingPurchaseCompleter!.complete(false);
      _pendingPurchaseCompleter = null;
      return false;
    }

    try {
      final result = await _raceWithTimeout(
        _pendingPurchaseCompleter!.future,
        purchaseTimeout,
        onTimeout: () {
          debugPrint('SubscriptionService: buyExtension() timeout');
          _completePending(false);
        },
      );
      debugPrint(
          'SubscriptionService: buyExtension() end productId=$productId result=$result');
      return result;
    } finally {
      _pendingProductId = null;
      _pendingPurchaseCompleter = null;
    }
  }

  /// Opens Google Play for a repeatable one-time access product and returns as
  /// soon as Billing accepts/rejects the launch. Purchase results are delivered
  /// through [purchaseEvents], which keeps cancellation and pending states
  /// distinct and prevents a long-lived UI spinner.
  Future<bool> launchExtensionPurchase(
    String productId, {
    String? applicationUserName,
  }) async {
    if (!_isAndroid ||
        !_isAvailable ||
        _pendingProductId != null ||
        !SubscriptionProducts.isExtension(productId)) {
      return false;
    }
    final product = _products.cast<ProductDetails?>().firstWhere(
          (candidate) => candidate?.id == productId,
          orElse: () => null,
        );
    if (product == null) return false;

    _lastPurchaseForVerification = null;
    _pendingProductId = productId;
    var launched = false;
    try {
      launched = await _store.buyConsumable(
        purchaseParam: GooglePlayPurchaseParam(
          productDetails: product,
          applicationUserName: applicationUserName,
        ),
        autoConsume: false,
      );
    } catch (error) {
      debugPrint('SubscriptionService: launchExtensionPurchase failed: $error');
    }
    if (!launched) {
      _pendingProductId = null;
    }
    return launched;
  }

  /// Returns unconsumed one-time purchases after a process/lifecycle gap.
  /// The caller must send every token to the existing idempotent backend
  /// verifier before granting access.
  Future<List<BillingPurchaseEvent>> recoverUnconsumedExtensions({
    String? applicationUserName,
  }) async {
    if (!_isAndroid || !_isAvailable) return const [];
    _lastRecoveryHadError = false;
    try {
      final addition =
          _store.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
      final response = await addition.queryPastPurchases(
        applicationUserName: applicationUserName,
      );
      if (response.error != null) {
        _lastRecoveryHadError = true;
        return const [];
      }
      return response.pastPurchases
          .where((purchase) =>
              SubscriptionProducts.isExtension(purchase.productID) &&
              (purchase.status == PurchaseStatus.purchased ||
                  purchase.status == PurchaseStatus.pending))
          .map((purchase) => BillingPurchaseEvent(
                status: purchase.status == PurchaseStatus.pending
                    ? BillingPurchaseStatus.pending
                    : BillingPurchaseStatus.purchased,
                productId: purchase.productID,
                purchaseToken:
                    purchase.verificationData.serverVerificationData.isEmpty
                        ? null
                        : purchase.verificationData.serverVerificationData,
                orderId: purchase.purchaseID,
                recovered: true,
              ))
          .toList(growable: false);
    } catch (error) {
      _lastRecoveryHadError = true;
      debugPrint('SubscriptionService: recovery failed: $error');
      return const [];
    }
  }

  /// Clears a local launch lock after lifecycle recovery proved that Google
  /// Play has no active one-time purchase for the flow.
  void resetPendingPurchaseFlow() {
    _pendingProductId = null;
    _pendingPurchaseCompleter = null;
    _lastPurchaseForVerification = null;
  }

  void _completePending(bool value) {
    if (_pendingPurchaseCompleter != null &&
        !_pendingPurchaseCompleter!.isCompleted) {
      _pendingPurchaseCompleter!.complete(value);
    }
  }

  Future<bool> _raceWithTimeout(
    Future<bool> future,
    Duration timeout, {
    required void Function() onTimeout,
  }) async {
    late bool result;
    bool completed = false;
    final timer = Timer(timeout, () {
      if (!completed) {
        completed = true;
        onTimeout();
      }
    });
    try {
      result = await future;
      completed = true;
      return result;
    } catch (e) {
      completed = true;
      return false;
    } finally {
      timer.cancel();
    }
  }

  void _onPurchaseUpdate(List<PurchaseDetails> purchaseDetailsList) {
    for (final purchase in purchaseDetailsList) {
      debugPrint(
          'SubscriptionService: purchaseStream status=${purchase.status} productID=${purchase.productID}');

      if (purchase.status == PurchaseStatus.restored) {
        if (SubscriptionProducts.isSubscription(purchase.productID)) {
          _restoredPurchases.add(purchase);
        }
        if (!SubscriptionProducts.isExtension(purchase.productID)) {
          _store.completePurchase(purchase);
        }
        if (purchase.productID == _pendingProductId) {
          _completePending(true);
          _pendingProductId = null;
          _pendingPurchaseCompleter = null;
        }
        continue;
      }

      if (purchase.productID != _pendingProductId) continue;
      switch (purchase.status) {
        case PurchaseStatus.pending:
          _purchaseEvents.add(BillingPurchaseEvent(
            status: BillingPurchaseStatus.pending,
            productId: purchase.productID,
          ));
          break;
        case PurchaseStatus.purchased:
          final v = purchase.verificationData;
          if (v.serverVerificationData.isNotEmpty) {
            _lastPurchaseForVerification = {
              'purchase_token': v.serverVerificationData,
              'product_id': purchase.productID,
              'order_id': purchase.purchaseID ?? '',
            };
          } else {
            _lastPurchaseForVerification = null;
          }
          if (!SubscriptionProducts.isExtension(purchase.productID)) {
            _store.completePurchase(purchase);
          }
          _purchaseEvents.add(BillingPurchaseEvent(
            status: BillingPurchaseStatus.purchased,
            productId: purchase.productID,
            purchaseToken: v.serverVerificationData.isEmpty
                ? null
                : v.serverVerificationData,
            orderId: purchase.purchaseID,
          ));
          _completePending(true);
          _pendingProductId = null;
          _pendingPurchaseCompleter = null;
          break;
        case PurchaseStatus.error:
          _purchaseEvents.add(BillingPurchaseEvent(
            status: BillingPurchaseStatus.error,
            productId: purchase.productID,
            responseCode: purchase.error?.code,
          ));
          _completePending(false);
          _pendingProductId = null;
          _pendingPurchaseCompleter = null;
          break;
        case PurchaseStatus.canceled:
          _purchaseEvents.add(BillingPurchaseEvent(
            status: BillingPurchaseStatus.canceled,
            productId: purchase.productID,
          ));
          _completePending(false);
          _pendingProductId = null;
          _pendingPurchaseCompleter = null;
          break;
        case PurchaseStatus.restored:
          break;
      }
    }
  }

  void _onPurchaseError(dynamic error) {
    debugPrint('SubscriptionService: ошибка purchaseStream: $error');
    final productId = _pendingProductId;
    if (productId != null) {
      _purchaseEvents.add(BillingPurchaseEvent(
        status: BillingPurchaseStatus.error,
        productId: productId,
        responseCode: 'purchase_stream_error',
      ));
    }
    _completePending(false);
    _pendingProductId = null;
    _pendingPurchaseCompleter = null;
  }

  /// Восстановить покупки и вернуть активную подписку (для апгрейда/даунгрейда).
  Future<GooglePlayPurchaseDetails?> getActiveSubscriptionPurchase() async {
    if (!_isAndroid || !_isAvailable) return null;
    _restoredPurchases.clear();
    try {
      await _store.restorePurchases();
      await Future.delayed(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('SubscriptionService: restorePurchases error: $e');
    }
    if (_restoredPurchases.isEmpty) return null;
    for (final p in _restoredPurchases.reversed) {
      if (SubscriptionProducts.isSubscription(p.productID) &&
          p is GooglePlayPurchaseDetails) {
        debugPrint(
            'SubscriptionService: found active subscription: ${p.productID}');
        return p;
      }
    }
    return null;
  }

  /// Покупка с апгрейдом/даунгрейдом существующей подписки.
  /// Google Play пересчитает стоимость с учётом оставшегося времени (proration).
  Future<bool> buyUpgrade(
    String productId,
    GooglePlayPurchaseDetails oldPurchase, {
    String? applicationUserName,
  }) async {
    if (!_isAndroid || !_isAvailable) return false;
    final product = _products.cast<ProductDetails?>().firstWhere(
          (p) => p!.id == productId,
          orElse: () => null,
        );
    if (product == null) {
      debugPrint('SubscriptionService: продукт не найден: $productId');
      return false;
    }

    debugPrint(
        'SubscriptionService: buyUpgrade() productId=$productId oldProduct=${oldPurchase.productID}');

    _lastPurchaseForVerification = null;
    _pendingProductId = productId;
    _pendingPurchaseCompleter = Completer<bool>();

    final param = GooglePlayPurchaseParam(
      productDetails: product,
      applicationUserName: applicationUserName,
      changeSubscriptionParam: ChangeSubscriptionParam(
        oldPurchaseDetails: oldPurchase,
        // User is charged for a full new billing period immediately. Google
        // Play carries the remaining value from the old subscription forward.
        replacementMode: ReplacementMode.chargeFullPrice,
      ),
    );
    final launchOk = await _store.buyNonConsumable(purchaseParam: param);
    if (!launchOk) {
      debugPrint('SubscriptionService: buyUpgrade() launch failed');
      _pendingProductId = null;
      _pendingPurchaseCompleter!.complete(false);
      _pendingPurchaseCompleter = null;
      return false;
    }

    try {
      final result = await _raceWithTimeout(
        _pendingPurchaseCompleter!.future,
        purchaseTimeout,
        onTimeout: () {
          debugPrint('SubscriptionService: buyUpgrade() timeout');
          _completePending(false);
        },
      );
      debugPrint('SubscriptionService: buyUpgrade() result=$result');
      return result;
    } finally {
      _pendingProductId = null;
      _pendingPurchaseCompleter = null;
    }
  }

  /// Цена продукта по id (из загруженных продуктов).
  String? priceFor(String productId) {
    for (final p in _products) {
      if (p.id == productId) return p.price;
    }
    return null;
  }

  /// Числовая цена продукта (для аналитики).
  double? getProductPrice(String productId) {
    for (final p in _products) {
      if (p.id == productId) return p.rawPrice;
    }
    return null;
  }

  /// Код валюты продукта.
  String? getProductCurrency(String productId) {
    for (final p in _products) {
      if (p.id == productId) return p.currencyCode;
    }
    return null;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _purchaseEvents.close();
    super.dispose();
  }
}
