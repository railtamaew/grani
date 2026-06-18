import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../models/user.dart';
import '../config/app_config.dart';
import '../core/api/api_client.dart';
import '../core/api/endpoint_router.dart';
import '../core/api/preferred_route_storage.dart';
import '../core/api/network_timeouts.dart';
import '../core/http/grani_network_interceptors.dart';
import '../core/http/grani_request_id.dart';
import '../core/storage/storage_service.dart';
import '../core/storage/shared_preferences_holder.dart';
import 'native_vpn_service.dart';
import '../l10n/localized_messages.dart';

/// Логи для анализа времени авторизации (латиница, grep: [auth-timing])
void _logAuthTiming(String event, Map<String, dynamic> data) {
  final parts = data.entries.map((e) => '${e.key}=${e.value}').join(', ');
  debugPrint('[auth-timing] $event $parts');
}

void _logRouteVerbose(String message) {
  if (AppConfig.enableRouteVerboseLogs) {
    debugPrint(message);
  }
}

String _tokenDebugSummary(String? token) {
  if (token == null || token.isEmpty) return 'present=false len=0';
  final digest = sha256.convert(utf8.encode(token)).toString();
  return 'present=true len=${token.length} sha256=${digest.substring(0, 8)}';
}

String _connectivityLabelForAuth(dynamic result) {
  try {
    final List<ConnectivityResult> types = result is List
        ? List<ConnectivityResult>.from(result)
        : [result as ConnectivityResult];
    if (types.contains(ConnectivityResult.wifi)) return 'wifi';
    if (types.contains(ConnectivityResult.mobile)) return 'mobile';
    if (types.contains(ConnectivityResult.ethernet)) return 'ethernet';
    if (types.contains(ConnectivityResult.none)) return 'none';
    if (types.isNotEmpty) return types.first.name;
  } catch (_) {}
  return 'unknown';
}

Map<String, dynamic>? _normalizeMap(dynamic data) {
  if (data is Map<String, dynamic>) {
    return data;
  } else if (data is Map) {
    return data.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

String? _extractErrorMessage(dynamic data) {
  final normalized = _normalizeMap(data);
  if (normalized != null) {
    final detail = normalized['detail'];
    if (detail is String && detail.isNotEmpty) return detail;
    final error = normalized['error'];
    if (error is Map) {
      final message = error['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    final message = normalized['message'];
    if (message is String && message.isNotEmpty) return message;
  }
  if (data is String && data.trim().isNotEmpty) {
    // Например, HTML/текст без JSON — показываем безопасное сообщение.
    return 'Ошибка сервера. Повторите позже.';
  }
  return null;
}

/// Текст ошибки /auth/verify-code для UI: API отдаёт русские строки; при EN-локали подставляем [LocalizedMessages].
String _localizedVerifyCodeApiMessage(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return LocalizedMessages.verifyCodeError;
  }
  final s = raw.trim();
  final lower = s.toLowerCase();
  if (LocalizedMessages.currentLanguageCode == 'ru') {
    return s;
  }
  if (lower.contains('неверный код') || lower.contains('invalid code')) {
    return LocalizedMessages.invalidCode;
  }
  if (lower.contains('код не найден') ||
      (lower.contains('истек') && lower.contains('запросите'))) {
    return LocalizedMessages.codeNotFoundOrExpired;
  }
  if (lower.contains('request_id') || lower.contains('некорректный')) {
    return LocalizedMessages.invalidAuthRequestId;
  }
  if (lower.contains('слишком много попыток') ||
      lower.contains('too many attempts')) {
    return LocalizedMessages.tooManyAttempts;
  }
  if (lower.contains('превышен лимит') || lower.contains('rate_limit')) {
    return LocalizedMessages.tooManyRequests;
  }
  if (RegExp(r'[а-яёА-ЯЁ]').hasMatch(s)) {
    return LocalizedMessages.verifyCodeError;
  }
  return s;
}

/// Результат авторизации через Google OAuth.
class GoogleSignInResult {
  final GoogleSignInStatus status;
  final String? errorMessage;
  final User? user;
  final String? token;

  GoogleSignInResult({
    required this.status,
    this.errorMessage,
    this.user,
    this.token,
  });

  bool get isSuccess => status == GoogleSignInStatus.success;
  bool get isCanceled => status == GoogleSignInStatus.canceled;
  bool get isError => status == GoogleSignInStatus.error;
}

/// Статусы результата Google OAuth.
enum GoogleSignInStatus {
  success, // Авторизация успешно завершена.
  canceled, // Пользователь нажал "Отмена".
  error, // Произошла ошибка.
}

/// Итоговый статус пользователя (для роутинга в UI).
enum UserStatus {
  /// Триал активен, trialSecondsLeft > 0.
  trialActive,

  /// Триал завершен, подписки нет.
  trialEnded,

  /// Есть активная подписка.
  subActive,
}

class AuthService extends ChangeNotifier {
  User? _user;
  String? _token;
  String? _refreshToken; // Refresh token для обновления access token.
  bool _isLoading = false;
  String? _authType; // 'google' или 'email'
  String? _lastError;
  DateTime? _nextCodeRequestAt;
  int? _dailyCodeRemaining;
  int? _dailyCodeSent;
  String? _authCodeRequestId;
  DateTime? _tokenExpiresAt;
  int? _trialSecondsLeft; // Оставшееся время триала в секундах.
  bool _hasActiveSubscription = false; // Есть ли активная подписка.
  DateTime? _subscriptionExpiresAt;
  DateTime? _subscriptionStartedAt;
  String? _subscriptionPlanName;
  // Pending-ошибка лимита устройств, чтобы показать DeviceLimitScreen после авторизации.
  List<dynamic> _pendingDeviceLimitDevices = const [];
  String? _pendingDeviceLimitMessage;
  int _pendingDeviceLimitRevision = 0;
  int? _maxDevices;
  VoidCallback? _onLogoutCallback;

  /// Прогрев DNS/TCP/TLS (bootstrap) — send-code, verify-code, первый connect.
  bool _networkWarmupDone = false;

  /// Единый прогрев перед критичными control-plane вызовами (холодная сеть).
  Future<void> ensureNetworkReady() async {
    if (_networkWarmupDone) return;
    try {
      await fetchBootstrapUrls().timeout(const Duration(seconds: 2));
      _networkWarmupDone = true;
      debugPrint('AuthService: ensureNetworkReady OK');
    } catch (e) {
      debugPrint('AuthService: ensureNetworkReady (не критично): $e');
    }
  }

  /// После успешного refresh access token (single-flight). Напр. [VpnService] сверяет натив/сервер.
  final List<void Function()> _onAccessTokenRefreshedListeners = [];

  /// Подписка на успешное обновление access token (не дублирует [notifyListeners]).
  void addAccessTokenRefreshedListener(void Function() listener) {
    _onAccessTokenRefreshedListeners.add(listener);
  }

  void _notifyAccessTokenRefreshed() {
    for (final l in _onAccessTokenRefreshedListeners) {
      try {
        l();
      } catch (e, st) {
        debugPrint('AuthService: _notifyAccessTokenRefreshed: $e $st');
      }
    }
  }

  /// send-code / resend / verify-code не пересекаются; verify — один логический submit;
  /// request_id не сбрасывается при transport timeout verify (сохраняем пару с последним send-code).
  Future<void> _authEmailSerial = Future.value();
  final Map<String, Future<bool>> _verifyInFlightByKey = {};
  Future<void>? _refreshUserStatusInFlight;
  DateTime? _lastRefreshUserStatusAt;
  static const Duration _refreshUserStatusCooldown = Duration(seconds: 60);

  /// Текущий HTTP для email control-plane (send-code / verify-code); отменяется при [cancelInFlightEmailAuth].
  CancelToken? _emailAuthHttpCancelToken;

  /// Отменить активный POST к `/auth/send-code` или `/auth/verify-code` (например при паузе приложения).
  void cancelInFlightEmailAuth() {
    final t = _emailAuthHttpCancelToken;
    if (t != null && !t.isCancelled) {
      t.cancel('app_paused');
    }
  }

  CancelToken _newEmailAuthHttpCancelToken() {
    final prev = _emailAuthHttpCancelToken;
    if (prev != null && !prev.isCancelled) {
      prev.cancel('superseded');
    }
    final next = CancelToken();
    _emailAuthHttpCancelToken = next;
    return next;
  }

  void _clearEmailAuthHttpCancelTokenIfSame(CancelToken token) {
    if (identical(_emailAuthHttpCancelToken, token)) {
      _emailAuthHttpCancelToken = null;
    }
  }

  Future<T> _withAuthEmailSerial<T>(Future<T> Function() fn) async {
    final done = Completer<void>();
    final prev = _authEmailSerial;
    _authEmailSerial = done.future;
    await prev;
    try {
      return await fn();
    } finally {
      if (!done.isCompleted) done.complete();
    }
  }

  final StorageService _storage = StorageService();
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile'],
    serverClientId: AppConfig.googleOAuthWebClientId,
  );

  static const _bootstrapCacheSavedAtKey = 'grani_bootstrap_saved_at_ms';
  static const _bootstrapCacheUrlsKey = 'grani_bootstrap_cached_urls_json';
  static const _bootstrapCachePortsKey = 'grani_bootstrap_cached_ports_json';
  static const Duration _bootstrapCacheTtl = Duration(minutes: 15);

  /// Единый in-flight для [fetchBootstrapUrls] — connect не дублирует работу.
  Future<void>? _bootstrapFetchInFlight;

  /// Восстанавливает [AppConfig.cachedApiBaseUrls] с диска без сети, если кэш свежий.
  Future<bool> _restoreBootstrapFromCacheIfFresh() async {
    try {
      final prefs = await getSharedPreferences();
      final savedAt = prefs.getInt(_bootstrapCacheSavedAtKey);
      if (savedAt == null) return false;
      final age = DateTime.now().millisecondsSinceEpoch - savedAt;
      if (age > _bootstrapCacheTtl.inMilliseconds) return false;
      final raw = prefs.getString(_bootstrapCacheUrlsKey);
      if (raw == null || raw.isEmpty) return false;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return false;
      final list =
          decoded.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
      if (list.isEmpty) return false;
      AppConfig.cachedApiBaseUrls =
          PreferredRouteStorage.prioritizeDomainRoutes(list);
      final portsJson = prefs.getString(_bootstrapCachePortsKey);
      if (portsJson != null && portsJson.isNotEmpty) {
        final pm = jsonDecode(portsJson);
        if (pm is Map) {
          final m = <String, int>{};
          for (final e in pm.entries) {
            final k = e.key?.toString();
            if (k == null || k.isEmpty) continue;
            final v = e.value;
            final port = v is int ? v : int.tryParse(v?.toString() ?? '');
            if (port != null) m[k] = port;
          }
          if (m.isNotEmpty) {
            AppConfig.cachedXrayExpectedPorts = m;
          }
        }
      }
      _logAuthTiming('bootstrap', {
        'cache_restore': true,
        'age_ms': age,
        'urls_count': list.length,
      });
      debugPrint(
        'AuthService: bootstrap из кэша (age=${age}ms, urls=${list.length})',
      );
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('AuthService: bootstrap cache restore failed: $e');
      return false;
    }
  }

  Future<void> _persistBootstrapToCache(
    List<String> urls,
    Map<String, int>? ports,
  ) async {
    try {
      final prefs = await getSharedPreferences();
      await prefs.setInt(
        _bootstrapCacheSavedAtKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      await prefs.setString(_bootstrapCacheUrlsKey, jsonEncode(urls));
      if (ports != null && ports.isNotEmpty) {
        await prefs.setString(_bootstrapCachePortsKey, jsonEncode(ports));
      } else {
        await prefs.remove(_bootstrapCachePortsKey);
      }
    } catch (e) {
      debugPrint('AuthService: bootstrap cache persist failed: $e');
    }
  }

  /// Данные лимита устройств после логина, чтобы показать экран в MainContentScreen.
  List<dynamic> get pendingDeviceLimitDevices =>
      List.unmodifiable(_pendingDeviceLimitDevices);

  String? get pendingDeviceLimitMessage => _pendingDeviceLimitMessage;

  /// Увеличивается при каждом [setPendingDeviceLimit] — удобно для [Selector] с узким shouldRebuild.
  int get pendingDeviceLimitRevision => _pendingDeviceLimitRevision;

  /// Есть ли что показать в UI: сообщение (в т.ч. после [setPendingDeviceLimit]) или непустой список устройств.
  bool get hasPendingDeviceLimit =>
      _pendingDeviceLimitMessage != null ||
      _pendingDeviceLimitDevices.isNotEmpty;

  void setPendingDeviceLimit(DeviceLimitException e) {
    _pendingDeviceLimitMessage = e.message;
    _pendingDeviceLimitDevices = List<dynamic>.from(e.devices);
    _pendingDeviceLimitRevision++;
    notifyListeners();
  }

  void clearPendingDeviceLimit() {
    _pendingDeviceLimitMessage = null;
    _pendingDeviceLimitDevices = const [];
    notifyListeners();
  }

  /// Загружает список api_base_urls с бэкенда (шаг 6 в censorship-resilient bootstrap).
  /// Дедупликация: повторные вызовы ждут тот же in-flight.
  Future<void> fetchBootstrapUrls() {
    if (_bootstrapFetchInFlight != null) return _bootstrapFetchInFlight!;
    final f = _fetchBootstrapUrlsInternal();
    _bootstrapFetchInFlight = f;
    return f.whenComplete(() {
      if (identical(_bootstrapFetchInFlight, f)) {
        _bootstrapFetchInFlight = null;
      }
    });
  }

  /// Перед VPN connect: не стартовать session/prepare, пока гонится «голый» bootstrap без кэша.
  Future<void> waitForBootstrapForVpnConnect(
      {Duration maxWait = const Duration(seconds: 6)}) async {
    try {
      if (await _restoreBootstrapFromCacheIfFresh()) return;
    } catch (_) {}
    if (AppConfig.cachedApiBaseUrls != null &&
        AppConfig.cachedApiBaseUrls!.isNotEmpty) {
      return;
    }
    final f = _bootstrapFetchInFlight;
    if (f == null) return;
    try {
      await f.timeout(maxWait);
    } catch (_) {
      debugPrint(
        'AuthService: waitForBootstrapForVpnConnect: лимит ${maxWait.inSeconds}s — продолжаем с дефолтными базами',
      );
    }
  }

  Future<void> _fetchBootstrapUrlsInternal() async {
    final vpnAt = AppConfig.vpnTunnelConnectedAt;
    if (vpnAt != null) {
      final since = DateTime.now().difference(vpnAt);
      if (since < const Duration(seconds: 20)) {
        await Future<void>.delayed(const Duration(seconds: 6));
      }
    }
    if (await _restoreBootstrapFromCacheIfFresh()) {
      return;
    }

    final btFast = await NetworkTimeouts.bootstrapFast();
    final bootstrapSw = Stopwatch()..start();

    debugPrint(
        'AuthService: bootstrap wave hostname (EndpointRouter + ApiClient)');
    final okHost = await _bootstrapHostnameWave(btFast);
    bootstrapSw.stop();
    if (okHost) {
      _logAuthTiming('bootstrap', {
        'total_ms': bootstrapSw.elapsedMilliseconds,
        'success': true,
        'wave': 'hostname',
      });
      return;
    }

    _logAuthTiming('bootstrap', {
      'total_ms': bootstrapSw.elapsedMilliseconds,
      'success': false,
      'all_failed': true,
    });
    debugPrint(
      'AuthService: bootstrap не удался, используем URL по умолчанию (вторая волна direct отключена)',
    );
  }

  Future<bool> _bootstrapHostnameWave(
    ({Duration connect, Duration send, Duration receive}) bt,
  ) async {
    try {
      final response = await ApiClient().get(
        '/vpn/bootstrap',
        requestKind: RequestKind.bootstrap,
        bootstrapWave: BootstrapWave.hostname,
        options: Options(
          sendTimeout: bt.send,
          receiveTimeout: bt.receive,
          extra: {'grani_connect_timeout': bt.connect},
        ),
      );
      return await _applyBootstrapFromResponse(response);
    } catch (e, st) {
      debugPrint('AuthService: bootstrap hostname wave: $e');
      debugPrint('$st');
      return false;
    }
  }

  Future<bool> _applyBootstrapFromResponse(Response<dynamic> response) async {
    if (response.statusCode == 200 &&
        response.data != null &&
        response.data is Map &&
        response.data['api_base_urls'] is List) {
      final list = (response.data['api_base_urls'] as List)
          .map((e) => e?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      if (list.isEmpty) return false;
      AppConfig.cachedApiBaseUrls =
          PreferredRouteStorage.prioritizeDomainRoutes(list);
      final portsRaw = response.data['xray_expected_ports'];
      if (portsRaw is Map) {
        final m = <String, int>{};
        for (final e in portsRaw.entries) {
          final k = e.key?.toString();
          if (k == null || k.isEmpty) continue;
          final v = e.value;
          final port = v is int ? v : int.tryParse(v?.toString() ?? '');
          if (port != null) m[k] = port;
        }
        if (m.isNotEmpty) {
          AppConfig.cachedXrayExpectedPorts = m;
        }
      }
      await _persistBootstrapToCache(
        AppConfig.cachedApiBaseUrls!,
        AppConfig.cachedXrayExpectedPorts,
      );
      notifyListeners();
      debugPrint('AuthService: bootstrap URLs получены (${list.length} шт.)');
      return true;
    }
    return false;
  }

  /// GET: hedged/fallback и policy/budget — в [ApiClient].
  Future<Response<dynamic>> _getWithFallbacks(
    String path, {
    Map<String, dynamic>? headers,
    Duration connectTimeout = const Duration(seconds: 8),
    Duration sendTimeout = const Duration(seconds: 8),
    Duration receiveTimeout = const Duration(seconds: 15),
  }) async {
    assert(path.startsWith('/'));
    final correlationId = newGraniRequestId();
    final baseHeaders = <String, dynamic>{
      'X-Request-ID': correlationId,
      ...?headers,
    };
    return ApiClient().get(
      path,
      options: Options(
        headers: baseHeaders,
        sendTimeout: sendTimeout,
        receiveTimeout: receiveTimeout,
        extra: {
          'grani_connect_timeout': connectTimeout,
          'grani_send_timeout': sendTimeout,
          'grani_receive_timeout': receiveTimeout,
        },
      ),
    );
  }

  /// POST через [ApiClient] + [EndpointRouter] (без повторов на уровне AuthService).
  Future<Response<dynamic>> _postViaApiClient(
    String path,
    Map<String, dynamic> data, {
    Map<String, String>? extraHeaders,
    Duration connectTimeout = const Duration(seconds: 5),
    Duration sendTimeout = const Duration(seconds: 10),
    Duration receiveTimeout = const Duration(seconds: 12),
    CancelToken? cancelToken,
    Map<String, dynamic>? authTimingMeta,
  }) async {
    assert(path.startsWith('/'));
    final correlationId = newGraniRequestId();
    _logRouteVerbose('Auth: X-Request-ID=$correlationId path=$path');
    final totalSw = Stopwatch()..start();
    final headers = <String, String>{
      'X-Request-ID': correlationId,
      if (extraHeaders != null) ...extraHeaders,
    };
    final skipHttpRetry = path == '/auth/send-code' ||
        path == '/auth/verify-code' ||
        path == '/payments/google-play/verify';
    debugPrint(
      '[TIMEOUT] path=$path connect=${connectTimeout.inMilliseconds}ms '
      'send=${sendTimeout.inMilliseconds}ms receive=${receiveTimeout.inMilliseconds}ms',
    );
    try {
      final response = await ApiClient().post(
        path,
        data: data,
        cancelToken: cancelToken,
        options: Options(
          headers: headers,
          sendTimeout: sendTimeout,
          receiveTimeout: receiveTimeout,
          extra: {
            'grani_connect_timeout': connectTimeout,
            'grani_send_timeout': sendTimeout,
            'grani_receive_timeout': receiveTimeout,
            if (skipHttpRetry) graniSkipHttpRetryExtra: true,
          },
        ),
      );
      _logAuthTiming('post', {
        'path': path,
        'x_request_id': correlationId,
        'total_ms': totalSw.elapsedMilliseconds,
        'status': response.statusCode ?? 0,
        'success': true,
        ...?authTimingMeta,
      });
      return response;
    } catch (e) {
      if (e is DioException) {
        final ro = e.requestOptions;
        debugPrint(
          '[TIMEOUT] effective path=$path connect=${ro.connectTimeout?.inMilliseconds}ms '
          'send=${ro.sendTimeout?.inMilliseconds}ms receive=${ro.receiveTimeout?.inMilliseconds}ms '
          'dioType=${e.type}',
        );
      }
      _logAuthTiming('post', {
        'path': path,
        'x_request_id': correlationId,
        'total_ms': totalSw.elapsedMilliseconds,
        'success': false,
        ...?authTimingMeta,
      });
      rethrow;
    } finally {
      totalSw.stop();
    }
  }

  User? get user => _user;
  String? get token => _token;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _token != null && _user != null;
  String? get authType => _authType;
  String? get lastError => _lastError;
  DateTime? get tokenExpiresAt => _tokenExpiresAt;
  int get secondsUntilCodeResend {
    if (_nextCodeRequestAt == null) return 0;
    final diff = _nextCodeRequestAt!.difference(DateTime.now());
    return diff.isNegative ? 0 : diff.inSeconds;
  }

  int? get dailyCodeRemaining => _dailyCodeRemaining;
  String? get authCodeRequestId => _authCodeRequestId;
  int? get dailyCodeSent => _dailyCodeSent;
  int? get trialSecondsLeft => _trialSecondsLeft;
  bool get hasActiveSubscription => _hasActiveSubscription;
  DateTime? get subscriptionExpiresAt => _subscriptionExpiresAt;
  DateTime? get subscriptionStartedAt => _subscriptionStartedAt;
  String? get subscriptionPlanName => _subscriptionPlanName;
  int get maxDevices => _maxDevices ?? AppConfig.maxDevices;

  /// Итоговый статус пользователя по hasActiveSubscription и trialSecondsLeft.
  UserStatus get userStatus {
    if (_hasActiveSubscription) return UserStatus.subActive;
    if ((_trialSecondsLeft ?? 0) > 0) return UserStatus.trialActive;
    return UserStatus.trialEnded;
  }

  final Completer<void> _tokenLoadCompleter = Completer<void>();

  /// Задаётся из [VpnService]: пока идёт connect — не дергаем /auth/me (снижает гонки с budget).
  bool Function()? _vpnConnectFlowActive;

  void attachVpnConnectFlowGate(bool Function() isConnectFlowActive) {
    _vpnConnectFlowActive = isConnectFlowActive;
  }

  static const String _prefsPendingGooglePlayVerify =
      'pending_google_play_verify_v1';

  bool _isTransientBillingNetworkError(DioException e) {
    final t = e.type;
    if (t == DioExceptionType.connectionTimeout ||
        t == DioExceptionType.sendTimeout ||
        t == DioExceptionType.receiveTimeout ||
        t == DioExceptionType.connectionError) {
      return true;
    }
    if (t == DioExceptionType.badResponse) {
      final c = e.response?.statusCode ?? 0;
      return c == 502 || c == 503 || c == 504;
    }
    return false;
  }

  /// Сохраняет данные покупки для повторного POST /payments/google-play/verify после появления сети.
  Future<void> savePendingGooglePlayVerification({
    required String purchaseToken,
    required String productId,
    String? orderId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsPendingGooglePlayVerify,
      jsonEncode({
        'purchase_token': purchaseToken,
        'product_id': productId,
        if (orderId != null && orderId.isNotEmpty) 'order_id': orderId,
      }),
    );
    debugPrint(
      '[billing] pending_google_play_verify saved product_id=$productId',
    );
  }

  Future<void> clearPendingGooglePlayVerification() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsPendingGooglePlayVerify);
  }

  /// Повторная верификация сохранённой покупки (после офлайна). Без вложенного refreshUserStatus.
  Future<bool> flushPendingGooglePlayVerification() async {
    if (!isAuthenticated || _token == null) return false;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsPendingGooglePlayVerify);
    if (raw == null || raw.isEmpty) return false;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final token = map['purchase_token'] as String?;
      final product = map['product_id'] as String?;
      if (token == null ||
          token.isEmpty ||
          product == null ||
          product.isEmpty) {
        await prefs.remove(_prefsPendingGooglePlayVerify);
        return false;
      }
      final orderId = map['order_id'] as String?;
      debugPrint(
          '[billing] flushPendingGooglePlayVerification try product_id=$product');
      return await verifyGooglePlayPurchase(
        purchaseToken: token,
        productId: product,
        orderId: (orderId != null && orderId.isNotEmpty) ? orderId : null,
      );
    } catch (e) {
      debugPrint('AuthService: flushPendingGooglePlayVerification: $e');
      return false;
    }
  }

  /// Обновляет статус подписки (trial и подписка) с сервера.
  /// Вызывается автоматически после авторизации и верификации.
  /// Перед запросом проверяет и при необходимости обновляет access token через refresh.
  Future<void> refreshUserStatus({bool force = false}) async {
    if (!isAuthenticated || _token == null) {
      return;
    }
    final now = DateTime.now();
    final last = _lastRefreshUserStatusAt;
    if (!force &&
        last != null &&
        now.difference(last) < _refreshUserStatusCooldown) {
      return;
    }
    final inFlight = _refreshUserStatusInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    return (_refreshUserStatusInFlight = _refreshUserStatusImpl())
        .whenComplete(() {
      _refreshUserStatusInFlight = null;
    });
  }

  Future<void> _refreshUserStatusImpl() async {
    if (!isAuthenticated || _token == null) {
      return;
    }

    if (_vpnConnectFlowActive?.call() == true) {
      debugPrint('AuthService: refreshUserStatus пропущен (идёт VPN connect)');
      return;
    }

    // Проверяем и обновляем токен при необходимости (например access token истек или пустой).
    final valid = await ensureValidToken();
    if (!valid) {
      debugPrint('AuthService: токен невалиден, refreshUserStatus пропущен');
      return;
    }

    final flushed = await flushPendingGooglePlayVerification();
    if (flushed) {
      debugPrint(
          'AuthService: refreshUserStatus — отложенная верификация Google Play успешна');
    }

    try {
      final t = await NetworkTimeouts.authCritical();
      final response = await _getWithFallbacks(
        '/auth/me',
        headers: {'Authorization': 'Bearer $_token'},
        connectTimeout: t.connect,
        sendTimeout: t.send,
        receiveTimeout: t.receive,
      );

      if (response.statusCode == 200) {
        final data = response.data;
        final newTrialSecondsLeft =
            data['trialSecondsLeft'] ?? data['trial_seconds_left'];
        final newHasActiveSubscription = data['hasActiveSubscription'] ??
            data['has_active_subscription'] ??
            false;

        if (newTrialSecondsLeft != null) {
          _trialSecondsLeft = newTrialSecondsLeft;
        }
        _hasActiveSubscription = newHasActiveSubscription;

        _parseSubscriptionDetails(data);

        final prefs = await SharedPreferences.getInstance();
        if (_trialSecondsLeft != null) {
          await prefs.setInt('trial_seconds_left', _trialSecondsLeft!);
        }
        await prefs.setBool('has_active_subscription', _hasActiveSubscription);
        await _saveSubscriptionDetailsToPrefs(prefs);

        _syncAllowTileConnect();
        notifyListeners();
        _lastRefreshUserStatusAt = DateTime.now();
        debugPrint(
            'AuthService: статус обновлён: trialSecondsLeft=$_trialSecondsLeft, hasActiveSubscription=$_hasActiveSubscription, expiresAt=$_subscriptionExpiresAt, plan=$_subscriptionPlanName');
      }
    } catch (e) {
      debugPrint('AuthService: ошибка обновления статуса: $e');
    }
  }

  Future<void> applyUserStatusSnapshot(
    Map<String, dynamic> data, {
    bool persist = true,
    bool notify = true,
  }) async {
    final newTrialSecondsLeft =
        data['trialSecondsLeft'] ?? data['trial_seconds_left'];
    final newHasActiveSubscription = data['hasActiveSubscription'] ??
        data['has_active_subscription'] ??
        false;

    if (newTrialSecondsLeft != null) {
      _trialSecondsLeft = newTrialSecondsLeft;
    }
    _hasActiveSubscription = newHasActiveSubscription == true;
    _parseSubscriptionDetails(data);

    if (persist) {
      final prefs = await SharedPreferences.getInstance();
      if (_trialSecondsLeft != null) {
        await prefs.setInt('trial_seconds_left', _trialSecondsLeft!);
      }
      await prefs.setBool('has_active_subscription', _hasActiveSubscription);
      await _saveSubscriptionDetailsToPrefs(prefs);
    }

    _syncAllowTileConnect();
    _lastRefreshUserStatusAt = DateTime.now();
    if (notify) {
      notifyListeners();
    }
  }

  /// Верификация покупки Google Play на бэкенде. Вызывать после успешного buy().
  /// Возвращает true при успехе.
  Future<bool> verifyGooglePlayPurchase({
    required String purchaseToken,
    required String productId,
    String? orderId,
  }) async {
    if (!isAuthenticated || _token == null) return false;
    final valid = await ensureValidToken();
    if (!valid) return false;
    try {
      final data = <String, dynamic>{
        'purchase_token': purchaseToken,
        'product_id': productId,
      };
      if (orderId != null && orderId.isNotEmpty) {
        data['order_id'] = orderId;
      }
      final ht = await NetworkTimeouts.paymentsGooglePlayVerify();
      final response = await _postViaApiClient(
        '/payments/google-play/verify',
        data,
        extraHeaders: {'Authorization': 'Bearer $_token'},
        connectTimeout: ht.connect,
        sendTimeout: ht.send,
        receiveTimeout: ht.receive,
      );
      if (response.statusCode == 200) {
        final body = response.data;
        if (body is Map && (body['success'] == true)) {
          await clearPendingGooglePlayVerification();
          debugPrint(
            '[billing] verifyGooglePlayPurchase ok product_id=$productId',
          );
          return true;
        }
        debugPrint(
          'AuthService: verifyGooglePlayPurchase non-success body status=200 data=$body',
        );
        await clearPendingGooglePlayVerification();
      } else {
        debugPrint(
          'AuthService: verifyGooglePlayPurchase HTTP ${response.statusCode} data=${response.data}',
        );
        if (response.statusCode == 400) {
          await clearPendingGooglePlayVerification();
        }
      }
      return false;
    } on DioException catch (e) {
      debugPrint(
        'AuthService: verifyGooglePlayPurchase DioException '
        'status=${e.response?.statusCode} type=${e.type} data=${e.response?.data}',
      );
      final status = e.response?.statusCode;
      if (status == 400) {
        await clearPendingGooglePlayVerification();
      } else if (_isTransientBillingNetworkError(e)) {
        await savePendingGooglePlayVerification(
          purchaseToken: purchaseToken,
          productId: productId,
          orderId: orderId,
        );
      }
      return false;
    } catch (e) {
      debugPrint('AuthService: verifyGooglePlayPurchase error: $e');
      return false;
    }
  }

  AuthService() {
    _loadToken().catchError((error) {
      debugPrint('Ошибка загрузки токена: $error');
      // Продолжаем работу без токена.
    }).whenComplete(() {
      if (!_tokenLoadCompleter.isCompleted) {
        _tokenLoadCompleter.complete();
      }
      if (_token != null) {
        flushPendingGooglePlayVerification().then((ok) {
          if (ok) refreshUserStatus();
        }).catchError((_) {});
      }
      // Загружаем fallback URL в фоне (bootstrap) для устойчивости к блокировкам.
      fetchBootstrapUrls().catchError((_) {});
    });
  }

  /// Синхронизирует флаг в нативном слое: разрешен ли коннект из Quick Tile.
  void _syncAllowTileConnect() {
    final allow = isAuthenticated &&
        (_hasActiveSubscription || ((_trialSecondsLeft ?? 0) > 0));
    NativeVpnService.setAllowTileConnect(allow);
  }

  void _parseSubscriptionDetails(Map<String, dynamic> data) {
    final expiresStr = data['subscription_expires_at'] as String?;
    _subscriptionExpiresAt =
        expiresStr != null ? DateTime.tryParse(expiresStr) : null;

    final startedStr = data['subscription_started_at'] as String?;
    _subscriptionStartedAt =
        startedStr != null ? DateTime.tryParse(startedStr) : null;

    _subscriptionPlanName = data['subscription_plan_name'] as String?;

    final md = data['max_devices'];
    _maxDevices = md is int ? md : null;
  }

  Future<void> _saveSubscriptionDetailsToPrefs(SharedPreferences prefs) async {
    if (_subscriptionExpiresAt != null) {
      await prefs.setString(
          'subscription_expires_at', _subscriptionExpiresAt!.toIso8601String());
    } else {
      await prefs.remove('subscription_expires_at');
    }
    if (_subscriptionStartedAt != null) {
      await prefs.setString(
          'subscription_started_at', _subscriptionStartedAt!.toIso8601String());
    } else {
      await prefs.remove('subscription_started_at');
    }
    if (_subscriptionPlanName != null) {
      await prefs.setString('subscription_plan_name', _subscriptionPlanName!);
    } else {
      await prefs.remove('subscription_plan_name');
    }
    if (_maxDevices != null) {
      await prefs.setInt('max_devices', _maxDevices!);
    } else {
      await prefs.remove('max_devices');
    }
  }

  Future<void> waitForTokenLoad() async {
    if (!_tokenLoadCompleter.isCompleted) {
      await _tokenLoadCompleter.future;
    }
  }

  Future<void> _loadToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      debugPrint('AuthService._loadToken: загружаю из secure storage');
      _token = await _storage.getSecureString('auth_token');
      _refreshToken = await _storage.getSecureString('refresh_token');
      debugPrint(
          'AuthService._loadToken: auth_token=${_token != null ? "есть (${_token!.length} символов)" : "null"}, refresh_token=${_refreshToken != null ? "есть (${_refreshToken!.length} символов)" : "null"}');
      _authType = prefs.getString('auth_type');
      if (_token == null) {
        final legacyToken = prefs.getString('auth_token');
        if (legacyToken != null) {
          _token = legacyToken;
          await _storage.setSecureString('auth_token', legacyToken);
          await prefs.remove('auth_token');
        }
      }
      final expiryIso = prefs.getString('token_expires_at');
      if (expiryIso != null) {
        try {
          _tokenExpiresAt = DateTime.parse(expiryIso);
        } catch (_) {
          _tokenExpiresAt = null;
        }
      }
      _authType = prefs.getString('auth_type');
      final email = prefs.getString('user_email');

      _trialSecondsLeft = prefs.getInt('trial_seconds_left');
      _hasActiveSubscription =
          prefs.getBool('has_active_subscription') ?? false;

      final expiresStr = prefs.getString('subscription_expires_at');
      _subscriptionExpiresAt =
          expiresStr != null ? DateTime.tryParse(expiresStr) : null;
      final startedStr = prefs.getString('subscription_started_at');
      _subscriptionStartedAt =
          startedStr != null ? DateTime.tryParse(startedStr) : null;
      _subscriptionPlanName = prefs.getString('subscription_plan_name');
      final savedMaxDevices = prefs.getInt('max_devices');
      _maxDevices = savedMaxDevices;

      _syncAllowTileConnect();

      // Восстанавливаем пользователя из сохраненного email.
      if (_token != null && email != null) {
        _user = User(
          id: prefs.getString('user_id') ?? '1',
          email: email,
          name: prefs.getString('user_name'),
          isEmailVerified: true,
          createdAt: DateTime.now(),
          isBlocked: false,
          avatarUrl: prefs.getString('user_avatar_url'),
        );
      }

      notifyListeners();
    } catch (e, stackTrace) {
      debugPrint('AuthService._loadToken: ошибка загрузки токенов: $e');
      debugPrint('AuthService._loadToken: stackTrace: $stackTrace');
      // Продолжаем без токена.
      notifyListeners();
    } finally {
      if (!_tokenLoadCompleter.isCompleted) {
        _tokenLoadCompleter.complete();
      }
    }
  }

  Future<void> _saveToken(
    String token, {
    String? refreshToken,
    String? authType,
    String? email,
    String? name,
    String? userId,
    String? avatarUrl,
    int? trialSecondsLeft,
    bool? hasActiveSubscription,
  }) async {
    _setError(null);
    try {
      final prefs = await SharedPreferences.getInstance();
      debugPrint(
          'AuthService._saveToken: сохраняю auth_token (длина=${token.length})');
      final okAuth = await _storage.setSecureString('auth_token', token);
      if (!okAuth) {
        debugPrint(
            'AuthService._saveToken: ОШИБКА сохранения auth_token в secure storage');
      }
      await prefs.remove('auth_token');
      _token = token;

      if (refreshToken != null) {
        debugPrint(
            'AuthService._saveToken: сохраняю refresh_token (длина=${refreshToken.length})');
        _refreshToken = refreshToken;
        final okRefresh =
            await _storage.setSecureString('refresh_token', refreshToken);
        if (!okRefresh) {
          debugPrint(
              'AuthService._saveToken: ОШИБКА сохранения refresh_token в secure storage');
        }
      } else {
        debugPrint('AuthService._saveToken: refresh_token null, не сохраняю');
      }

      final expiry = _decodeJwtExpiry(token);
      _tokenExpiresAt = expiry;
      if (expiry != null) {
        await prefs.setString('token_expires_at', expiry.toIso8601String());
      } else {
        await prefs.remove('token_expires_at');
      }

      if (authType != null) {
        await prefs.setString('auth_type', authType);
        _authType = authType;
      }

      if (email != null) {
        await prefs.setString('user_email', email);
      }

      if (name != null) {
        await prefs.setString('user_name', name);
      }

      if (userId != null) {
        await prefs.setString('user_id', userId);
      }

      if (avatarUrl != null) {
        await prefs.setString('user_avatar_url', avatarUrl);
      }

      // Обновляем информацию о trial и подписке.
      if (trialSecondsLeft != null) {
        _trialSecondsLeft = trialSecondsLeft;
        await prefs.setInt('trial_seconds_left', trialSecondsLeft);
      }

      if (hasActiveSubscription != null) {
        _hasActiveSubscription = hasActiveSubscription;
        await prefs.setBool('has_active_subscription', hasActiveSubscription);
      }
      debugPrint('AuthService._saveToken: успешно сохранено');
    } catch (e, st) {
      debugPrint('AuthService._saveToken: исключение при сохранении: $e');
      debugPrint('AuthService._saveToken: stackTrace: $st');
      rethrow;
    }
  }

  Future<void> _clearToken() async {
    _setError(null);
    final prefs = await SharedPreferences.getInstance();
    await _storage.removeSecureString('auth_token');
    await _storage.removeSecureString('refresh_token');
    await prefs.remove('auth_type');
    await prefs.remove('user_email');
    await prefs.remove('user_name');
    await prefs.remove('user_id');
    await prefs.remove('user_avatar_url');
    await prefs.remove('token_expires_at');
    await prefs.remove('subscription_expires_at');
    await prefs.remove('subscription_started_at');
    await prefs.remove('subscription_plan_name');
    await prefs.remove('max_devices');
    await prefs.remove(_prefsPendingGooglePlayVerify);
    _token = null;
    _refreshToken = null;
    _user = null;
    _authType = null;
    _tokenExpiresAt = null;
    _subscriptionExpiresAt = null;
    _subscriptionStartedAt = null;
    _subscriptionPlanName = null;
    _maxDevices = null;
    _authCodeRequestId = null;
    _networkWarmupDone = false;
  }

  void _setError(String? message) {
    _lastError = message;
  }

  void _updateRateLimitState(Map<String, dynamic>? data) {
    if (data == null) {
      _nextCodeRequestAt = null;
      return;
    }
    final retryAfter = data['retry_after'];
    if (retryAfter is num) {
      _nextCodeRequestAt =
          DateTime.now().add(Duration(seconds: retryAfter.toInt()));
    } else if (retryAfter == null) {
      _nextCodeRequestAt = null;
    }
    final dailyRemaining = data['daily_remaining'];
    if (dailyRemaining is num) {
      _dailyCodeRemaining = dailyRemaining.toInt();
    } else if (dailyRemaining == null) {
      _dailyCodeRemaining = null;
    }
    final dailySent = data['daily_sent'];
    if (dailySent is num) {
      _dailyCodeSent = dailySent.toInt();
    } else if (dailySent == null) {
      _dailyCodeSent = null;
    }
  }

  @visibleForTesting
  static String? extractErrorMessageForTest(dynamic data) {
    return _extractErrorMessage(data);
  }

  DateTime? _decodeJwtExpiry(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = parts[1];
      final normalized = base64Url.normalize(payload);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final data = jsonDecode(decoded);
      final exp = data['exp'];
      if (exp is int) {
        return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true)
            .toLocal();
      } else if (exp is double) {
        return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000,
                isUtc: true)
            .toLocal();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Не удалось декодировать exp из JWT: $e');
      }
    }
    return null;
  }

  /// Проверяет, истек ли access token.
  bool isTokenExpired() {
    if (_token == null) return true;

    // Если дата истечения не вычислена, пробуем декодировать из токена.
    if (_tokenExpiresAt == null) {
      _tokenExpiresAt = _decodeJwtExpiry(_token!);
    }

    if (_tokenExpiresAt == null) {
      // Не удалось определить exp, считаем токен валидным (не ломаем рабочую сессию).
      return false;
    }

    // Считаем токен истекшим за 5 минут до реального срока (защитный буфер).
    final now = DateTime.now();
    final expiresAt = _tokenExpiresAt!;
    final isExpired =
        now.isAfter(expiresAt.subtract(const Duration(minutes: 5)));

    if (isExpired) {
      debugPrint(
          'AuthService: токен истек. Время истечения: $expiresAt, текущее время: $now');
    }

    return isExpired;
  }

  /// Один inflight refresh на всех параллельных вызовах (401 interceptor + ensureValidToken).
  Future<bool>? _refreshAccessTokenInFlight;

  /// Обновляет access token через refresh token.
  /// Использует fallback URLs и retry для сетевой устойчивости.
  Future<bool> refreshAccessToken() async {
    final existing = _refreshAccessTokenInFlight;
    if (existing != null) return existing;
    final future = _executeRefreshAccessToken();
    _refreshAccessTokenInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_refreshAccessTokenInFlight, future)) {
        _refreshAccessTokenInFlight = null;
      }
    }
  }

  Future<bool> _executeRefreshAccessToken() async {
    if (_refreshToken == null) {
      debugPrint('AuthService: Refresh token отсутствует');
      return false;
    }

    try {
      debugPrint('AuthService: обновляем access token через refresh token...');
      final rt = await NetworkTimeouts.authRefreshToken();
      final response = await _postViaApiClient(
        '/auth/refresh-token',
        {'refresh_token': _refreshToken!},
        connectTimeout: rt.connect,
        sendTimeout: rt.send,
        receiveTimeout: rt.receive,
      );

      if (response.statusCode == 200) {
        final data = response.data;
        final newToken = data['access_token'] ?? data['token'];

        if (newToken != null) {
          await _saveToken(newToken, refreshToken: _refreshToken);
          debugPrint('AuthService: access token успешно обновлен');
          notifyListeners();
          _notifyAccessTokenRefreshed();
          return true;
        }
      }
    } on DioException catch (e) {
      debugPrint('AuthService: ошибка обновления токена: ${e.message}');
      if (e.response?.statusCode == 401) {
        debugPrint(
            'AuthService: refresh token истек, выполняем выход из аккаунта');
        await logout();
      }
    } catch (e) {
      debugPrint('AuthService: непредвиденная ошибка обновления токена: $e');
    }

    return false;
  }

  /// Гарантирует валидный токен перед защищенными запросами.
  Future<bool> ensureValidToken() async {
    if (isTokenExpired()) {
      debugPrint(
          'AuthService: access token истек, пытаемся обновить через refresh token');
      final refreshed = await refreshAccessToken();
      if (!refreshed) {
        debugPrint(
            'AuthService: не удалось обновить токен, требуется повторная авторизация');
        return false;
      }
    }
    return true;
  }

  Future<bool> login(String email, String password) async {
    _isLoading = true;
    _setError(null);
    notifyListeners();

    try {
      final t = await NetworkTimeouts.authCritical();
      final response = await _postViaApiClient(
        '/auth/login',
        {'email': email, 'password': password},
        connectTimeout: t.connect,
        sendTimeout: t.send,
        receiveTimeout: t.receive,
      );

      if (response.statusCode == 200) {
        final data = response.data;
        _token = data['access_token'];

        try {
          final userResponse = await _getWithFallbacks(
            '/auth/me',
            headers: {'Authorization': 'Bearer $_token'},
            connectTimeout: t.connect,
            sendTimeout: t.send,
            receiveTimeout: t.receive,
          );
          if (userResponse.statusCode == 200) {
            final userData = userResponse.data;
            _user = User(
              id: userData['id'].toString(),
              email: userData['email'],
              name: userData['name'] ?? email.split('@')[0],
              isEmailVerified: userData['is_verified'] ?? true,
              createdAt: DateTime.parse(
                  userData['created_at'] ?? DateTime.now().toIso8601String()),
              isBlocked: userData['is_blocked'] ?? false,
              avatarUrl: userData['avatar_url'],
            );
          }
        } catch (e) {
          debugPrint(
              'login: /auth/me не удался, используем данные из login: $e');
          _user = User(
            id: data['user_id']?.toString() ?? '1',
            email: data['email'] ?? email,
            name: email.split('@')[0],
            isEmailVerified: true,
            createdAt: DateTime.now(),
            isBlocked: false,
          );
        }

        await _saveToken(
          _token!,
          authType: 'email',
          email: _user!.email,
          name: _user!.name,
          userId: _user!.id,
          avatarUrl: _user!.avatarUrl,
        );

        _authCodeRequestId = null;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _setError(LocalizedMessages.authError);
        throw Exception(LocalizedMessages.authError);
      }
    } catch (e) {
      debugPrint('Ошибка входа: $e');
      _setError(LocalizedMessages.loginError);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> register(String email, String password, String name) async {
    _isLoading = true;
    notifyListeners();

    try {
      final t = await NetworkTimeouts.authSendCode();
      final response = await _postViaApiClient(
        '/auth/send-code',
        {'email': email},
        connectTimeout: t.connect,
        sendTimeout: t.send,
        receiveTimeout: t.receive,
      );

      if (response.statusCode == 200) {
        final data = response.data;
        _updateRateLimitState(_normalizeMap(data));
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        throw Exception(
            response.data['detail'] ?? LocalizedMessages.registrationError);
      }
    } catch (e) {
      debugPrint('Ошибка регистрации: $e');
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Авторизация через Google OAuth.
  /// Возвращает результат с нормализованным статусом (success/canceled/error).
  Future<GoogleSignInResult> signInWithGoogle() async {
    final authTotalSw = Stopwatch()..start();
    _isLoading = true;
    _setError(null);
    notifyListeners();

    try {
      _logAuthTiming('google_auth_start', {'event': 'start'});
      debugPrint('Google OAuth: start (log ASCII for logcat UTF-8 issues)');
      if (kDebugMode) {
        debugPrint(
            'Google OAuth: Web Client ID = ${AppConfig.googleOAuthWebClientId}');
        debugPrint('Google OAuth: API Base URL = ${AppConfig.apiBaseUrl}');
        debugPrint(
            'Google OAuth: GoogleSignIn scopes = ${_googleSignIn.scopes}');
      }

      final signInSw = Stopwatch()..start();
      debugPrint('Google OAuth: calling GoogleSignIn.signIn()...');
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      signInSw.stop();
      _logAuthTiming('google_ui', {
        'elapsed_ms': signInSw.elapsedMilliseconds,
        'canceled': googleUser == null
      });

      if (googleUser == null) {
        authTotalSw.stop();
        _logAuthTiming('google_auth_done', {
          'total_ms': authTotalSw.elapsedMilliseconds,
          'status': 'canceled'
        });
        _isLoading = false;
        notifyListeners();
        return GoogleSignInResult(
          status: GoogleSignInStatus.canceled,
        );
      }

      final tokenSw = Stopwatch()..start();
      debugPrint(
          'Google OAuth: fetching authentication for ${googleUser.email}');
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      tokenSw.stop();
      _logAuthTiming(
          'google_token', {'elapsed_ms': tokenSw.elapsedMilliseconds});

      debugPrint('Google OAuth: authentication received');
      debugPrint(
          'Google OAuth: idToken ${_tokenDebugSummary(googleAuth.idToken)}');
      debugPrint(
          'Google OAuth: accessToken ${_tokenDebugSummary(googleAuth.accessToken)}');

      // Проверяем наличие id_token (обязательно для авторизации на сервере)
      if (googleAuth.idToken == null) {
        debugPrint('Google OAuth: ошибка — idToken не получен от Google');
        debugPrint(
            'Google OAuth: AccessToken: ${googleAuth.accessToken != null ? "получен" : "не получен"}');
        debugPrint('Google OAuth: что проверить:');
        debugPrint('  1. SHA-1 fingerprint приложения в Google Cloud Console');
        debugPrint('  2. Client ID соответствует package name');
        debugPrint('  3. OAuth client создан для Android-приложения');
        debugPrint(
            'Google OAuth: проверить SHA-1: keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey');
        _isLoading = false;
        _setError(LocalizedMessages.googleTokenMissing);
        notifyListeners();
        return GoogleSignInResult(
          status: GoogleSignInStatus.error,
          errorMessage: LocalizedMessages.googleTokenMissing,
        );
      }

      debugPrint('Google OAuth: idToken OK, POST /auth/google/callback...');

      final callbackSw = Stopwatch()..start();
      _logAuthTiming('callback_start',
          {'total_so_far_ms': authTotalSw.elapsedMilliseconds});
      try {
        final gt = await NetworkTimeouts.authHeavy();
        final response = await _postViaApiClient(
          '/auth/google/callback',
          {
            'id_token': googleAuth.idToken,
            'access_token': googleAuth.accessToken,
          },
          connectTimeout: gt.connect,
          sendTimeout: gt.send,
          receiveTimeout: gt.receive,
        );
        callbackSw.stop();

        debugPrint(
            'Google OAuth: ответ получен от сервера, статус: ${response.statusCode}');

        if (response.statusCode == 200) {
          final data = response.data;
          debugPrint(
              'Google OAuth: авторизация успешна, user_id: ${data['user_id']}');
          debugPrint(
              'Google OAuth: ключи в ответе: ${(data is Map ? data.keys.toList() : []).join(", ")}');
          _token = data['access_token'] ?? data['token'];
          // Критично: устанавливаем _refreshToken и _tokenExpiresAt СРАЗУ, до любых await,
          // чтобы параллельные вызовы ensureValidToken/refreshAccessToken не видели null.
          final rt = data['refresh_token'] ?? data['refreshToken'];
          _refreshToken = rt is String ? rt : null;
          if (_refreshToken != null) {
            debugPrint(
                'Google OAuth: refresh_token получен (длина=${_refreshToken!.length})');
          } else {
            debugPrint(
                'Google OAuth: WARN refresh_token отсутствует в ответе callback');
          }
          _tokenExpiresAt = _decodeJwtExpiry(_token ?? '');

          // Сначала берём trial/subscription из ответа callback — он уже содержит актуальные данные.
          // Это устраняет гонку: пользователь с подпиской из админки не попадает в trial.
          int? trialSecondsLeft =
              data['trialSecondsLeft'] ?? data['trial_seconds_left'];
          bool hasActiveSubscription = data['hasActiveSubscription'] ??
              data['has_active_subscription'] ??
              false;

          _user = User(
            id: (data['user_id'] ?? data['id'] ?? '1').toString(),
            email: data['email'] ?? googleUser.email,
            name: data['name'] ??
                googleUser.displayName ??
                googleUser.email.split('@')[0],
            isEmailVerified: true,
            createdAt: DateTime.now(),
            isBlocked: false,
            avatarUrl: googleUser.photoUrl,
          );

          // Применяем статус подписки/триала
          _trialSecondsLeft = trialSecondsLeft;
          _hasActiveSubscription = hasActiveSubscription;

          final refreshTokenFromServer = _refreshToken;
          final saveTokenSw = Stopwatch()..start();
          await _saveToken(
            _token!,
            refreshToken: refreshTokenFromServer,
            authType: 'google',
            email: _user!.email,
            name: _user!.name,
            userId: _user!.id,
            avatarUrl: _user!.avatarUrl,
            trialSecondsLeft: trialSecondsLeft,
            hasActiveSubscription: hasActiveSubscription,
          );
          saveTokenSw.stop();
          _logAuthTiming('save_token', {
            'elapsed_ms': saveTokenSw.elapsedMilliseconds,
            'total_so_far_ms': authTotalSw.elapsedMilliseconds,
          });

          final notifySw = Stopwatch()..start();
          _isLoading = false;
          notifyListeners();
          notifySw.stop();

          authTotalSw.stop();
          _logAuthTiming('google_auth_done', {
            'total_ms': authTotalSw.elapsedMilliseconds,
            'callback_ms': callbackSw.elapsedMilliseconds,
            'save_token_ms': saveTokenSw.elapsedMilliseconds,
            'notify_ms': notifySw.elapsedMilliseconds,
            'status': 'success',
          });

          // Фоновое обновление статуса через /auth/me (не блокирует авторизацию)
          refreshUserStatus().catchError((_) {});

          debugPrint('Google OAuth: авторизация завершена успешно');
          _setError(null);
          return GoogleSignInResult(
            status: GoogleSignInStatus.success,
            user: _user,
            token: _token,
          );
        } else {
          authTotalSw.stop();
          _logAuthTiming('google_auth_done', {
            'total_ms': authTotalSw.elapsedMilliseconds,
            'callback_ms': callbackSw.elapsedMilliseconds,
            'status': 'callback_failed',
            'http_status': response.statusCode ?? 0,
          });
          final body = response.data;
          debugPrint(
              'Google OAuth: CALLBACK FAILED status=${response.statusCode} body=$body');
          final detail = body is Map ? (body['detail'] ?? body['error']) : null;
          final detailStr = detail is String
              ? detail
              : (detail is Map ? detail['message'] : null);
          final message =
              detailStr ?? 'Ошибка авторизации Google: ${response.statusCode}';
          _setError(message);
          _isLoading = false;
          notifyListeners();
          return GoogleSignInResult(
            status: GoogleSignInStatus.error,
            errorMessage: message,
          );
        }
      } on DioException catch (dioError) {
        callbackSw.stop();
        authTotalSw.stop();
        _logAuthTiming('google_auth_done', {
          'total_ms': authTotalSw.elapsedMilliseconds,
          'callback_ms': callbackSw.elapsedMilliseconds,
          'status': 'dio_error',
          'error_type': dioError.type.toString(),
          'status_code': dioError.response?.statusCode ?? 0,
        });
        final statusCode = dioError.response?.statusCode;
        debugPrint(
            'Google OAuth: CALLBACK FAILED DioException type=${dioError.type} status=$statusCode url=${dioError.requestOptions.uri}');
        debugPrint('Google OAuth: response.data=${dioError.response?.data}');
        if (statusCode == 502 || statusCode == 503) {
          final message = LocalizedMessages.errorByHttpCode(503);
          debugPrint('Google OAuth: DioException при callback на сервер');
          debugPrint('Google OAuth: Status Code: $statusCode');
          debugPrint('Google OAuth: пользовательское сообщение: $message');
          _setError(message);
          _isLoading = false;
          notifyListeners();
          return GoogleSignInResult(
            status: GoogleSignInStatus.error,
            errorMessage: message,
          );
        }
        String? serverMessage;
        final errorData = dioError.response?.data;
        if (errorData is Map<String, dynamic>) {
          serverMessage = errorData['detail'] ?? errorData['error']?['message'];
        }
        String message = serverMessage ?? LocalizedMessages.authRelogin;
        if (dioError.response == null) {
          if (dioError.type == DioExceptionType.connectionTimeout ||
              dioError.type == DioExceptionType.sendTimeout ||
              dioError.type == DioExceptionType.receiveTimeout) {
            message =
                'Таймаут сети. Домен api.granilink.com может быть недоступен в текущей сети.';
          } else if (dioError.type == DioExceptionType.connectionError) {
            message = LocalizedMessages.connectionError;
          } else {
            message = LocalizedMessages.serverUnavailable;
          }
        }
        debugPrint('Google OAuth: DioException при callback на сервер');
        debugPrint('Google OAuth: DioException.type: ${dioError.type}');
        debugPrint('Google OAuth: DioException.message: ${dioError.message}');
        debugPrint(
            'Google OAuth: Status Code: ${dioError.response?.statusCode}');
        debugPrint('Google OAuth: Response Data: ${dioError.response?.data}');
        debugPrint('Google OAuth: Request URL: ${dioError.requestOptions.uri}');
        debugPrint('Google OAuth: пользовательское сообщение: $message');
        _setError(message);
        _isLoading = false;
        notifyListeners();
        return GoogleSignInResult(
          status: GoogleSignInStatus.error,
          errorMessage: message,
        );
      } catch (e, stackTrace) {
        callbackSw.stop();
        authTotalSw.stop();
        _logAuthTiming('google_auth_done', {
          'total_ms': authTotalSw.elapsedMilliseconds,
          'callback_ms': callbackSw.elapsedMilliseconds,
          'status': 'exception',
          'error': e.toString().length > 100
              ? '${e.toString().substring(0, 100)}...'
              : e.toString(),
        });
        debugPrint(
            'Google OAuth: непредвиденная ошибка callback на сервере: $e');
        debugPrint('Google OAuth: Stack trace: $stackTrace');
        final message = LocalizedMessages.authRelogin;
        _setError(message);
        _isLoading = false;
        notifyListeners();
        return GoogleSignInResult(
          status: GoogleSignInStatus.error,
          errorMessage: message,
        );
      }
    } catch (e, stackTrace) {
      authTotalSw.stop();
      _logAuthTiming('google_auth_done', {
        'total_ms': authTotalSw.elapsedMilliseconds,
        'status': 'exception_outer'
      });
      // Непредвиденная ошибка - возвращаем error.
      debugPrint('Google OAuth: непредвиденная ошибка: $e');
      debugPrint('Google OAuth: тип ошибки: ${e.runtimeType}');
      debugPrint('Google OAuth: Stack trace: $stackTrace');
      debugPrint(
          'Google OAuth: строковое представление ошибки: ${e.toString()}');

      String errorMessage = LocalizedMessages.authRelogin;
      final errorString = e.toString();

      if (errorString.contains('ApiException: 10') ||
          errorString.contains('DEVELOPER_ERROR') ||
          errorString.contains('10:')) {
        errorMessage = LocalizedMessages.googleOAuthConfigError;
        debugPrint(
            'Google OAuth: обнаружен DEVELOPER_ERROR (ApiException: 10)');
        debugPrint('Google OAuth: что проверить в конфигурации OAuth:');
        debugPrint('  1. SHA-1 fingerprint добавлен');
        debugPrint('  2. Client ID корректный');
        debugPrint('  3. Package name совпадает');
        debugPrint(
            'Google OAuth: текущий Client ID: ${AppConfig.googleOAuthWebClientId}');
        debugPrint(
            'Google OAuth: проверить SHA-1 можно: keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android');
      } else if (errorString.contains('sign_in_failed')) {
        errorMessage = LocalizedMessages.timeoutGeneric;
        debugPrint('Google OAuth: обнаружен sign_in_failed');
      } else {
        debugPrint(
            'Google OAuth: неизвестный тип ошибки, используем общее сообщение');
      }

      _setError(errorMessage);
      _isLoading = false;
      notifyListeners();
      return GoogleSignInResult(
        status: GoogleSignInStatus.error,
        errorMessage: errorMessage,
      );
    }
  }

  /// Устаревшая обертка для обратной совместимости.
  /// Рекомендуется использовать signInWithGoogle() с результатом GoogleSignInResult.
  @Deprecated(
      'Используйте signInWithGoogle() и обрабатывайте GoogleSignInResult')
  Future<bool> signInWithGoogleLegacy() async {
    final result = await signInWithGoogle();
    return result.isSuccess;
  }

  Future<void> logout() async {
    // Выход из Google-сессии.
    if (_authType == 'google') {
      await _googleSignIn.signOut();
    }

    await _clearToken();
    _onLogoutCallback?.call();
    notifyListeners();
  }

  void setOnLogoutCallback(VoidCallback? callback) {
    _onLogoutCallback = callback;
  }

  Future<bool> verifyEmail(String code) async {
    if (_user == null) return false;
    try {
      return await verifyCode(
        _user!.email,
        code,
      );
    } catch (e) {
      return false;
    }
  }

  Future<bool> resetPassword(String email) async {
    try {
      // TODO: Реализовать интеграцию с API.
      await Future.delayed(const Duration(seconds: 1));
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Отправляет код подтверждения (для email авторизации), POST `/auth/send-code`.
  /// [omitGlobalLoadingState]: не трогать [_isLoading] — для optimistic UI (сразу переход на экран кода).
  Future<bool> sendCode(String email, {bool omitGlobalLoadingState = false}) =>
      _withAuthEmailSerial(
        () => _sendCodeBody(
          email,
          forceResend: false,
          omitGlobalLoadingState: omitGlobalLoadingState,
        ),
      );

  /// Повторная отправка кода — тот же эндпоинт; [forceResend] просит новый код и письмо.
  Future<bool> resendCode(String email) =>
      _withAuthEmailSerial(() => _sendCodeBody(email, forceResend: true));

  Future<bool> _sendCodeBody(
    String email, {
    bool forceResend = false,
    bool omitGlobalLoadingState = false,
  }) async {
    final cancelToken = _newEmailAuthHttpCancelToken();
    int sendCodeAttempts = 0;
    String networkType = 'unknown';
    final trackLoading = !omitGlobalLoadingState;
    if (trackLoading) {
      _isLoading = true;
    }
    _setError(null);
    notifyListeners();

    try {
      debugPrint(
          'Email Auth: отправка кода на $email${forceResend ? " (force_resend)" : ""}');
      debugPrint('Email Auth: дефолтный host (инфо): ${AppConfig.apiBaseUrl}');
      await ensureNetworkReady();
      try {
        networkType =
            _connectivityLabelForAuth(await Connectivity().checkConnectivity());
      } catch (_) {
        networkType = 'unknown';
      }

      final t = await NetworkTimeouts.authSendCode();
      final payload = <String, dynamic>{'email': email};
      if (forceResend) {
        payload['force_resend'] = true;
      }
      Response<dynamic>? response;
      const maxAttempts = 2;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        sendCodeAttempts = attempt;
        try {
          response = await _postViaApiClient(
            '/auth/send-code',
            payload,
            connectTimeout: t.connect,
            sendTimeout: t.send,
            receiveTimeout: t.receive,
            cancelToken: cancelToken,
            authTimingMeta: {
              'attempt': attempt,
              'network_type': networkType,
              'flow': 'send_code',
            },
          );
          if (attempt > 1) {
            debugPrint(
              'Email Auth: send-code retry success attempt=$attempt/$maxAttempts network=$networkType',
            );
          }
          break;
        } on DioException catch (e) {
          final canRetry = e.type == DioExceptionType.receiveTimeout &&
              e.response == null &&
              attempt < maxAttempts;
          if (!canRetry) rethrow;
          final jitterMs = 500 + Random().nextInt(301);
          debugPrint(
            'Email Auth: send-code retry after receiveTimeout '
            'attempt=$attempt/$maxAttempts wait_ms=$jitterMs network=$networkType',
          );
          await Future.delayed(Duration(milliseconds: jitterMs));
        }
      }
      if (response == null) {
        throw Exception('send-code response is null after retry');
      }

      debugPrint(
          'Email Auth: ответ сервера по отправке, статус: ${response.statusCode}');
      debugPrint('Email Auth: тело ответа: ${response.data}');
      if (response.statusCode == 200) {
        // Нормализуем формат ответа: {"ok": true} или {"ok": true, ...}
        final responseData = _normalizeMap(response.data) ?? {};
        debugPrint('Email Auth: нормализованный ответ сервера: $responseData');

        // Принимаем ok как true, "true", 1 или отсутствие поля (если статус 200).
        final okValue = responseData['ok'];
        final isOk = okValue == true ||
            okValue == 'true' ||
            okValue == 1 ||
            (okValue == null &&
                response.statusCode ==
                    200); // если ok отсутствует, но статус 200 — считаем успехом

        debugPrint(
            'Email Auth: проверка ok: $isOk (значение: $okValue, тип: ${okValue?.runtimeType})');

        if (isOk) {
          _updateRateLimitState(responseData);
          final reqId = responseData['request_id'] ?? responseData['requestId'];
          final reqIdStr = reqId?.toString().trim();
          if (reqIdStr != null && reqIdStr.isNotEmpty) {
            _authCodeRequestId = reqIdStr;
          }
          if (responseData['deduplicated'] == true) {
            debugPrint(
                'Email Auth: идемпотентный ответ сервера (код уже был активен), request_id=$_authCodeRequestId');
          }
          debugPrint('Email Auth: request_id: ${_authCodeRequestId ?? "none"}');
          debugPrint('Email Auth: код успешно отправлен на $email');
          if (trackLoading) _isLoading = false;
          notifyListeners();
          return true;
        } else {
          debugPrint(
              'Email Auth: в ответе нет подтверждения ok=true: $responseData');
          debugPrint(
              'Email Auth: значение ok: $okValue, тип: ${okValue?.runtimeType}');
          _authCodeRequestId = null;
          _setError(LocalizedMessages.sendCodeError);
          if (trackLoading) _isLoading = false;
          notifyListeners();
          return false;
        }
      } else {
        final errorMsg = response.data['detail'] ??
            response.data['error']?['message'] ??
            LocalizedMessages.sendCodeError;
        debugPrint('Ошибка отправки кода: $errorMsg');
        _authCodeRequestId = null;
        _setError(errorMsg);
        if (trackLoading) _isLoading = false;
        notifyListeners();
        return false;
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        debugPrint('Email Auth: запрос send-code отменён (lifecycle)');
        _setError(LocalizedMessages.authInterruptedInBackground);
        if (trackLoading) _isLoading = false;
        notifyListeners();
        return false;
      }
      debugPrint('Email Auth: DioException при отправке кода');
      debugPrint('  Тип: ${e.type}');
      debugPrint('  StatusCode: ${e.response?.statusCode}');
      debugPrint('  Response data: ${e.response?.data}');
      debugPrint('  Message: ${e.message}');
      debugPrint('  Error: ${e.error}');
      debugPrint('  Request URL: ${e.requestOptions.uri}');

      String errorMessage = LocalizedMessages.sendCodeError;

      if (e.response?.statusCode == 400) {
        final detail = _extractErrorMessage(e.response?.data);
        // Специальная обработка - ошибка "email невалидный" приходит как invalid_email_format
        if (detail?.toString().toLowerCase().contains('invalid_email_format') ==
            true) {
          errorMessage = LocalizedMessages.invalidEmailFormat;
        } else {
          errorMessage = detail ?? LocalizedMessages.invalidEmailFormat;
        }
        debugPrint('Email Auth: 400 Bad Request - $errorMessage');
      } else if (e.response?.statusCode == 429) {
        errorMessage = LocalizedMessages.tooManyRequests;
        debugPrint('Email Auth: 429 Too Many Requests');
      } else if (e.response?.statusCode == 500) {
        // Ошибка отправки email (email_send_failed)
        final detail = _extractErrorMessage(e.response?.data);
        if (detail?.toString().contains('email_send_failed') == true) {
          errorMessage = LocalizedMessages.sendCodeRetry;
        } else {
          errorMessage = LocalizedMessages.serverError;
        }
        debugPrint('Email Auth: 500 Internal Server Error - $errorMessage');
      } else if (e.type == DioExceptionType.receiveTimeout) {
        debugPrint(
          'Email Auth: receiveTimeout send-code — условный успех '
          '(attempts=$sendCodeAttempts, network=$networkType), '
          'код, скорее всего, отправлен; переход к вводу кода',
        );
        _setError(null);
        if (trackLoading) _isLoading = false;
        notifyListeners();
        return true;
      } else if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout) {
        errorMessage = LocalizedMessages.timeoutWithNetworkHint;
        debugPrint('Email Auth: connect/send Timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        final errorMsg = e.message ?? '';
        if (errorMsg.contains('Connection refused') ||
            errorMsg.contains('Failed to connect')) {
          errorMessage = '${LocalizedMessages.connectionError} ';
        } else {
          errorMessage = '${LocalizedMessages.connectionError} ';
        }
        errorMessage += LocalizedMessages.connectionRetryHint;
        debugPrint('Email Auth: Connection Error - ${e.message}');
      } else if (e.type == DioExceptionType.badResponse) {
        final statusCode = e.response?.statusCode;
        if (statusCode == 502 || statusCode == 503) {
          errorMessage = LocalizedMessages.authServiceError;
        } else {
          final detail = _extractErrorMessage(e.response?.data);
          errorMessage = detail ??
              LocalizedMessages.errorByHttpCode(e.response?.statusCode ?? 500);
        }
        debugPrint('Email Auth: Bad Response - $errorMessage');
      } else if (e.type == DioExceptionType.unknown) {
        // Неизвестная сетевая ошибка
        final errorMsg = e.error?.toString() ?? e.message ?? '';
        debugPrint('Email Auth: Unknown DioException');
        debugPrint('Email Auth: Error: $errorMsg');
        debugPrint('Email Auth: Request URL: ${e.requestOptions.uri}');

        if (errorMsg.contains('SocketException') ||
            errorMsg.contains('Failed host lookup')) {
          errorMessage = LocalizedMessages.connectionError;
        } else if (errorMsg.contains('Network is unreachable')) {
          errorMessage = LocalizedMessages.networkUnavailable;
        } else if (errorMsg
            .contains('Connection closed before full header was received')) {
          errorMessage = LocalizedMessages.networkGeneric;
        } else {
          errorMessage = LocalizedMessages.connectionError;
        }
        debugPrint('Email Auth: Unknown Error - $errorMessage');
      }
      if (e.response == null &&
          e.type != DioExceptionType.receiveTimeout &&
          !errorMessage.contains(LocalizedMessages.connectionRetryHint)) {
        errorMessage += ' ${LocalizedMessages.connectionRetryHint}';
      }
      debugPrint('Email Auth: итоговая ошибка: $errorMessage');
      _setError(errorMessage);
      if (trackLoading) _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      debugPrint('Неожиданная ошибка отправки кода: $e');
      _authCodeRequestId = null;
      _setError(LocalizedMessages.unexpectedSendCodeError);
      if (trackLoading) _isLoading = false;
      notifyListeners();
      return false;
    } finally {
      _clearEmailAuthHttpCancelTokenIfSame(cancelToken);
    }
  }

  Future<bool> verifyCode(String email, String code) {
    final normalizedCode = code.trim().replaceAll(RegExp(r'\s+'), '');
    final key = '${email.toLowerCase()}|$normalizedCode';
    return _withAuthEmailSerial(() async {
      final existing = _verifyInFlightByKey[key];
      if (existing != null) {
        debugPrint(
            'Email Auth: verifyCode — объединение с текущим запросом (тот же email/код)');
        return await existing;
      }
      final fut = _verifyCodeBody(email, normalizedCode).whenComplete(() {
        _verifyInFlightByKey.remove(key);
      });
      _verifyInFlightByKey[key] = fut;
      return await fut;
    });
  }

  Future<bool> _verifyCodeBody(String email, String normalizedCode) async {
    final cancelToken = _newEmailAuthHttpCancelToken();
    final verifySw = Stopwatch()..start();
    _logAuthTiming('email_verify_start', {'email': email});
    _isLoading = true;
    _setError(null);
    notifyListeners();

    try {
      debugPrint('Email Auth: ========== НАЧАЛО ПРОВЕРКИ КОДА ==========');
      debugPrint('Email Auth: проверка кода для $email');
      debugPrint(
          'Email Auth: нормализованный код: "$normalizedCode" (длина: ${normalizedCode.length})');
      debugPrint(
          'Email Auth: normalizedCode.codeUnits: ${normalizedCode.codeUnits}');

      // Формируем payload для запроса.
      final requestData = {
        'email': email,
        'code': normalizedCode,
        if ((_authCodeRequestId ?? '').isNotEmpty)
          'request_id': _authCodeRequestId,
      };
      debugPrint('Email Auth: payload запроса: $requestData');
      debugPrint(
          'Email Auth: request_id в verify: ${requestData['request_id'] ?? "none"}');
      debugPrint(
          'Email Auth: тип code в payload: ${requestData['code'].runtimeType}');
      debugPrint('Email Auth: выполняем POST /auth/verify-code');

      await ensureNetworkReady();

      final t = await NetworkTimeouts.authVerifyCode();
      // Один POST без повтора: повтор инвалидирует одноразовый код на сервере.
      final response = await _postViaApiClient(
        '/auth/verify-code',
        requestData,
        connectTimeout: t.connect,
        sendTimeout: t.send,
        receiveTimeout: t.receive,
        cancelToken: cancelToken,
      );

      debugPrint(
          'Email Auth: ответ сервера по проверке, статус: ${response.statusCode}');
      debugPrint('Email Auth: тело ответа: ${response.data}');
      debugPrint('Email Auth: тип ответа: ${response.data.runtimeType}');

      if (response.statusCode == 200) {
        final data = _normalizeMap(response.data) ?? {};
        // Нормализуем варианты полей ответа /auth/verify-code.
        _token = data['token'] ??
            data['access_token'] ??
            response.data['token'] ??
            response.data['access_token'];
        final refreshToken = data['refresh_token'];
        final userData = data['user'] ?? {};
        final trialSecondsLeft =
            data['trialSecondsLeft'] ?? data['trial_seconds_left'] ?? 0;
        final hasActiveSubscription = data['hasActiveSubscription'] ??
            data['has_active_subscription'] ??
            false;

        debugPrint(
            'Email Auth: авторизация подтверждена, user_id: ${userData['id'] ?? data['user_id'] ?? data['id']}');
        debugPrint(
            'Email Auth: trialSecondsLeft: $trialSecondsLeft, hasActiveSubscription: $hasActiveSubscription');

        final createdAtRaw =
            userData['created_at'] ?? data['created_at'] ?? data['createdAt'];
        DateTime createdAt = DateTime.now();
        if (createdAtRaw is String) {
          createdAt = DateTime.tryParse(createdAtRaw) ?? DateTime.now();
        }

        // Нормализуем данные user из API с fallback по ключам.
        _user = User(
          id: (userData['id'] ?? data['user_id'] ?? data['id'] ?? '1')
              .toString(),
          email: userData['email'] ?? data['email'] ?? email,
          name: userData['name'] ?? data['name'] ?? email.split('@')[0],
          isEmailVerified: userData['is_verified'] ??
              data['is_verified'] ??
              data['is_email_verified'] ??
              true,
          createdAt: createdAt,
          isBlocked: userData['is_blocked'] ??
              data['is_blocked'] ??
              data['isBlocked'] ??
              false,
          avatarUrl:
              userData['avatar_url'] ?? data['avatar_url'] ?? data['avatarUrl'],
        );

        // Сохраняем состояние подписки и trial.
        _trialSecondsLeft = trialSecondsLeft;
        _hasActiveSubscription = hasActiveSubscription;

        await _saveToken(
          _token!,
          refreshToken: refreshToken,
          authType: 'email',
          email: _user!.email,
          name: _user!.name,
          userId: _user!.id,
          avatarUrl: _user!.avatarUrl,
          trialSecondsLeft: trialSecondsLeft is int
              ? trialSecondsLeft
              : int.tryParse(trialSecondsLeft.toString()) ?? 0,
          hasActiveSubscription: hasActiveSubscription,
        );
        _authCodeRequestId = null;

        _isLoading = false;
        notifyListeners();
        verifySw.stop();
        _logAuthTiming('email_verify_done',
            {'total_ms': verifySw.elapsedMilliseconds, 'success': true});
        debugPrint('Email Auth: ✅ авторизация успешно завершена');
        debugPrint('Email Auth: ========== ПРОВЕРКА ЗАВЕРШЕНА ==========');
        return true;
      } else {
        verifySw.stop();
        _logAuthTiming('email_verify_done', {
          'total_ms': verifySw.elapsedMilliseconds,
          'success': false,
          'status': response.statusCode ?? 0
        });
        final errorMsg = _localizedVerifyCodeApiMessage(
          _extractErrorMessage(response.data),
        );
        debugPrint('Ошибка проверки кода: $errorMsg');
        _setError(errorMsg);
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } on DioException catch (e) {
      verifySw.stop();
      _logAuthTiming('email_verify_done', {
        'total_ms': verifySw.elapsedMilliseconds,
        'success': false,
        'error_type': e.type.toString(),
        'status_code': e.response?.statusCode ?? 0,
      });
      if (e.type == DioExceptionType.cancel) {
        debugPrint('Email Auth: запрос verify-code отменён (lifecycle)');
        _setError(LocalizedMessages.authInterruptedInBackground);
        _isLoading = false;
        notifyListeners();
        return false;
      }
      debugPrint('Email Auth: ⚠ DioException при проверке кода');
      debugPrint('Email Auth: тип ошибки: ${e.type}');
      debugPrint('Email Auth: статус ответа: ${e.response?.statusCode}');
      debugPrint('Email Auth: тело ответа: ${e.response?.data}');
      debugPrint('Email Auth: заголовки ответа: ${e.response?.headers}');
      debugPrint('Email Auth: request URL: ${e.requestOptions.uri}');
      debugPrint('Email Auth: request payload: ${e.requestOptions.data}');

      String errorMessage = LocalizedMessages.invalidCode;

      if (e.response?.statusCode == 400) {
        final detail = _extractErrorMessage(e.response?.data);
        debugPrint('Email Auth: ответ 400, detail: $detail');
        if (detail?.toString().contains('invalid_code') == true) {
          errorMessage = LocalizedMessages.invalidCode;
        } else {
          errorMessage = _localizedVerifyCodeApiMessage(detail);
        }
      } else if (e.response?.statusCode == 410) {
        // code_expired
        debugPrint('Email Auth: ответ 410 - код истёк');
        _authCodeRequestId = null;
        errorMessage = LocalizedMessages.codeExpired;
      } else if (e.response?.statusCode == 429) {
        final detail = _extractErrorMessage(e.response?.data);
        debugPrint('Email Auth: ответ 429, detail: $detail');
        if (detail?.toString().contains('too_many_attempts') == true) {
          errorMessage = LocalizedMessages.tooManyAttempts;
        } else {
          errorMessage = _localizedVerifyCodeApiMessage(detail);
        }
      } else if (e.type == DioExceptionType.receiveTimeout) {
        debugPrint('Email Auth: receiveTimeout verify-code (без автоповтора)');
        errorMessage = LocalizedMessages.verifyCodeReceiveTimeoutNoRetry;
      } else if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout) {
        debugPrint('Email Auth: connect/send timeout verify-code');
        errorMessage = LocalizedMessages.timeoutGeneric;
      } else if (e.type == DioExceptionType.connectionError) {
        debugPrint('Email Auth: ошибка соединения');
        errorMessage = LocalizedMessages.connectionError;
      }

      debugPrint('Email Auth: итоговая ошибка проверки кода: $errorMessage');
      debugPrint('Email Auth: ========== ОШИБКА ПРОВЕРКИ КОДА ==========');
      _setError(errorMessage);
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e, stackTrace) {
      verifySw.stop();
      _logAuthTiming('email_verify_done', {
        'total_ms': verifySw.elapsedMilliseconds,
        'success': false,
        'exception': e.toString().length > 50
            ? '${e.toString().substring(0, 50)}...'
            : e.toString()
      });
      debugPrint('Email Auth: ❌ Неожиданная ошибка при проверке кода: $e');
      debugPrint('Email Auth: тип ошибки: ${e.runtimeType}');
      debugPrint('Email Auth: stack trace: $stackTrace');
      debugPrint('Email Auth: ========== НЕОЖИДАННАЯ ОШИБКА ==========');
      _setError(LocalizedMessages.unexpectedVerifyCodeError);
      _isLoading = false;
      notifyListeners();
      return false;
    } finally {
      _clearEmailAuthHttpCancelTokenIfSame(cancelToken);
    }
  }

  Future<void> syncPreferredLanguage(String languageCode) async {
    if (!isAuthenticated || token == null) return;
    try {
      await ApiClient().post(
        '/auth/language',
        data: {'language': languageCode},
      );
    } catch (_) {
      // Endpoint can be absent on older backend versions.
    }
  }
}
