import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';

import '../config/subscription_products.dart';
import '../l10n/localized_messages.dart';

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

  StreamSubscription<List<PurchaseDetails>>? _subscription;
  final InAppPurchase _store = InAppPurchase.instance;

  List<ProductDetails> _products = [];
  bool _isAvailable = false;
  bool _isLoading = false;
  String? _errorMessage;

  Completer<bool>? _pendingPurchaseCompleter;
  String? _pendingProductId;

  /// Восстановленные покупки (для определения текущей активной подписки при апгрейде).
  final List<PurchaseDetails> _restoredPurchases = [];
  bool _restoring = false;

  /// Данные последней успешной покупки для верификации на бэкенде.
  Map<String, String>? _lastPurchaseForVerification;

  /// Таймаут ожидания результата покупки (защита от зависания при закрытии Billing).
  /// Play Billing sheet often stays open >15s; short timeouts cause false failures
  /// and skip verify while the purchase still completes on the stream.
  static const Duration purchaseTimeout = Duration(seconds: 120);

  /// Данные для верификации последней успешной покупки.
  /// Вызывать сразу после buy() вернул true — отправить на бэкенд POST /api/payments/google-play/verify.
  Map<String, String>? get lastPurchaseForVerification => _lastPurchaseForVerification;

  List<ProductDetails> get products => List.unmodifiable(_products);
  bool get isAvailable => _isAvailable;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

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
      final response = await _store.queryProductDetails(SubscriptionProducts.all.toSet());
      if (response.notFoundIDs.isNotEmpty) {
        debugPrint('SubscriptionService: продукты не найдены: ${response.notFoundIDs}');
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
  Future<bool> buy(String productId) async {
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

    _pendingProductId = productId;
    _pendingPurchaseCompleter = Completer<bool>();

    final param = PurchaseParam(productDetails: product);
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
          debugPrint('SubscriptionService: buy() timeout after ${purchaseTimeout.inSeconds}s');
          _completePending(false);
        },
      );
      debugPrint('SubscriptionService: buy() end productId=$productId result=$result');
      return result;
    } finally {
      _pendingProductId = null;
      _pendingPurchaseCompleter = null;
    }
  }

  void _completePending(bool value) {
    if (_pendingPurchaseCompleter != null && !_pendingPurchaseCompleter!.isCompleted) {
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
      debugPrint('SubscriptionService: purchaseStream status=${purchase.status} productID=${purchase.productID}');

      if (purchase.status == PurchaseStatus.restored) {
        if (SubscriptionProducts.all.contains(purchase.productID)) {
          _restoredPurchases.add(purchase);
        }
        _store.completePurchase(purchase);
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
          _store.completePurchase(purchase);
          _completePending(true);
          _pendingProductId = null;
          _pendingPurchaseCompleter = null;
          break;
        case PurchaseStatus.error:
          _completePending(false);
          _pendingProductId = null;
          _pendingPurchaseCompleter = null;
          break;
        case PurchaseStatus.canceled:
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
    _completePending(false);
    _pendingProductId = null;
    _pendingPurchaseCompleter = null;
  }

  /// Восстановить покупки и вернуть активную подписку (для апгрейда/даунгрейда).
  Future<GooglePlayPurchaseDetails?> getActiveSubscriptionPurchase() async {
    if (!_isAndroid || !_isAvailable) return null;
    _restoredPurchases.clear();
    _restoring = true;
    try {
      await _store.restorePurchases();
      await Future.delayed(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('SubscriptionService: restorePurchases error: $e');
    } finally {
      _restoring = false;
    }
    if (_restoredPurchases.isEmpty) return null;
    for (final p in _restoredPurchases.reversed) {
      if (SubscriptionProducts.all.contains(p.productID) && p is GooglePlayPurchaseDetails) {
        debugPrint('SubscriptionService: found active subscription: ${p.productID}');
        return p;
      }
    }
    return null;
  }

  /// Покупка с апгрейдом/даунгрейдом существующей подписки.
  /// Google Play пересчитает стоимость с учётом оставшегося времени (proration).
  Future<bool> buyUpgrade(String productId, GooglePlayPurchaseDetails oldPurchase) async {
    if (!_isAndroid || !_isAvailable) return false;
    final product = _products.cast<ProductDetails?>().firstWhere(
          (p) => p!.id == productId,
          orElse: () => null,
        );
    if (product == null) {
      debugPrint('SubscriptionService: продукт не найден: $productId');
      return false;
    }

    debugPrint('SubscriptionService: buyUpgrade() productId=$productId oldProduct=${oldPurchase.productID}');

    _pendingProductId = productId;
    _pendingPurchaseCompleter = Completer<bool>();

    final param = GooglePlayPurchaseParam(
      productDetails: product,
      changeSubscriptionParam: ChangeSubscriptionParam(
        oldPurchaseDetails: oldPurchase,
        replacementMode: ReplacementMode.withTimeProration,
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
    super.dispose();
  }
}
