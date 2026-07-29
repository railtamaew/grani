part of '../../services/vpn_service.dart';

/// Device registration, quota checks, and device list helpers for [VpnService].
extension VpnDeviceRegistrationHelpers on VpnService {
  /// Регистрация устройства на уровне авторизации (и при холодном старте). Параллельные вызовы
  /// с разных мест сходятся в один in-flight `/vpn/device/register` (поле `_ensureDeviceRegisterInFlight`).
  Future<void> ensureDeviceRegistered(
    String token, {
    bool verifyQuota = true,
    bool force = false,
  }) async {
    final lastEnsure = _lastEnsureDeviceRegisteredAt;
    if (!force && _deviceRegistrationDoneThisSession && lastEnsure != null) {
      final elapsed = DateTime.now().difference(lastEnsure);
      if (elapsed < VpnService._ensureDeviceRegisteredCooldown) {
        return;
      }
    }
    await (_ensureDeviceRegisterInFlight ??= _runEnsureDeviceRegistered(
      token,
      verifyQuota: verifyQuota,
      force: force,
    ));
  }

  Future<void> _runEnsureDeviceRegistered(
    String token, {
    required bool verifyQuota,
    required bool force,
  }) async {
    try {
      if (_deviceId == null) await _loadDeviceId();
      final hasPendingDeviceLimit = _authService.hasPendingDeviceLimit;
      if (!force &&
          !hasPendingDeviceLimit &&
          _deviceRegistrationDoneThisSession) {
        return;
      }
      if (!force &&
          !hasPendingDeviceLimit &&
          await _hasFreshDeviceRegistrationCache()) {
        _deviceRegistrationDoneThisSession = true;
        _lastEnsureDeviceRegisteredAt = DateTime.now();
        _log(
          'VpnService.ensureDeviceRegistered: skip /vpn/device/register '
          '(fresh local cache)',
        );
        return;
      }
      await _registerDeviceIfNeeded(token, verifyQuota: verifyQuota);
      if (_authService.hasPendingDeviceLimit) {
        _authService.clearPendingDeviceLimit();
      }
      _lastEnsureDeviceRegisteredAt = DateTime.now();
    } finally {
      _ensureDeviceRegisterInFlight = null;
    }
  }

  String? _deviceRegistrationCacheKey() {
    final deviceId = _deviceId;
    if (deviceId == null || deviceId.isEmpty) return null;
    final user = _authService.user;
    final userKey = (user?.id.isNotEmpty == true ? user!.id : user?.email)
        ?.trim()
        .toLowerCase();
    if (userKey == null || userKey.isEmpty) return null;
    final safeUser = userKey.replaceAll(RegExp(r'[^a-z0-9_.@-]'), '_');
    final safeDevice = deviceId.replaceAll(RegExp(r'[^a-zA-Z0-9_.@-]'), '_');
    return 'device_registration_ok_v2_${safeUser}_$safeDevice';
  }

  Future<bool> _hasFreshDeviceRegistrationCache() async {
    try {
      final key = _deviceRegistrationCacheKey();
      if (key == null) return false;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final expiresAt = await _storageService.getInt('${key}_expires_at');
      if (expiresAt != null && expiresAt > nowMs) return true;

      // Backward compatibility for the previous v2 cache value: it stored
      // saved_at, not expires_at. Treat it as a 24h cache.
      final savedAt = await _storageService.getInt(key);
      if (savedAt == null || savedAt <= 0) return false;
      final legacyExpiresAt =
          savedAt + VpnService._deviceRegistrationFallbackTtl.inMilliseconds;
      return legacyExpiresAt > nowMs;
    } catch (e) {
      _log('VpnService._hasFreshDeviceRegistrationCache: $e');
      return false;
    }
  }

  DateTime _deviceRegistrationExpiresAt() {
    final now = DateTime.now();
    DateTime? accessExpiresAt;

    final subscriptionExpiresAt = _authService.subscriptionExpiresAt;
    if (_authService.hasActiveSubscription &&
        subscriptionExpiresAt != null &&
        subscriptionExpiresAt.isAfter(now)) {
      accessExpiresAt = subscriptionExpiresAt;
    }

    final trialSecondsLeft = _authService.trialSecondsLeft;
    if (trialSecondsLeft != null && trialSecondsLeft > 0) {
      final trialExpiresAt = now.add(Duration(seconds: trialSecondsLeft));
      if (accessExpiresAt == null || trialExpiresAt.isAfter(accessExpiresAt)) {
        accessExpiresAt = trialExpiresAt;
      }
    }

    final maxExpiresAt = now.add(VpnService._deviceRegistrationMaxTtl);
    if (accessExpiresAt == null || !accessExpiresAt.isAfter(now)) {
      return now.add(VpnService._deviceRegistrationFallbackTtl);
    }
    return accessExpiresAt.isBefore(maxExpiresAt)
        ? accessExpiresAt
        : maxExpiresAt;
  }

  Future<void> _markDeviceRegistrationCached() async {
    try {
      final key = _deviceRegistrationCacheKey();
      if (key == null) return;
      final expiresAt = _deviceRegistrationExpiresAt();
      await _storageService.setInt(
        key,
        DateTime.now().millisecondsSinceEpoch,
      );
      await _storageService.setInt(
        '${key}_expires_at',
        expiresAt.millisecondsSinceEpoch,
      );
    } catch (e) {
      _log('VpnService._markDeviceRegistrationCached: $e');
    }
  }

  /// Сервер для уже известного `device_id` может вернуть 200/409 без `DEVICE_LIMIT_EXCEEDED`,
  /// даже если в аккаунте больше [AuthService.maxDevices] строк (дрейф/старые данные).
  /// Сверяемся с GET `/vpn/devices` (дедуп как в API), чтобы не обходили лимит после перезапуска.
  Future<void> _verifyDeviceSlotQuotaOrThrow(String token) async {
    try {
      final devices = await fetchDevicesWithAuth(forceRefresh: true);
      final limit = _authService.maxDevices;
      if (devices.length <= limit) return;
      _log(
        'VpnService._verifyDeviceSlotQuotaOrThrow: превышение лимита '
        'count=${devices.length} limit=$limit',
      );
      throw DeviceLimitException(
        'Достигнут лимит устройств ($limit)',
        limit: limit,
        currentCount: devices.length,
        devices: devices,
      );
    } on DeviceLimitException {
      rethrow;
    } catch (e) {
      _log(
          'VpnService._verifyDeviceSlotQuotaOrThrow: пропуск (сеть/ответ): $e');
    }
  }

  /// После resume: если на сервере больше устройств, чем лимит — выставить pending для модалки лимита.
  Future<void> revalidateDeviceQuotaFromServer() async {
    if (_authService.hasPendingDeviceLimit) return;
    final token = await _getAuthToken();
    if (token == null || token.isEmpty) return;
    try {
      final devices = await fetchDevicesWithAuth(forceRefresh: true);
      final limit = _authService.maxDevices;
      if (devices.length <= limit) return;
      _authService.setPendingDeviceLimit(
        DeviceLimitException(
          'Достигнут лимит устройств ($limit)',
          limit: limit,
          currentCount: devices.length,
          devices: devices,
        ),
      );
    } catch (e) {
      _log('VpnService.revalidateDeviceQuotaFromServer: $e');
    }
  }

  Future<void> _registerDeviceIfNeeded(
    String token, {
    required bool verifyQuota,
  }) async {
    try {
      _setError(null);
      final deviceInfo = DeviceInfoPlugin();
      String platform = 'unknown';
      String deviceName = 'Unknown Device';

      if (defaultTargetPlatform == TargetPlatform.android) {
        final androidInfo = await deviceInfo.androidInfo;
        platform = 'android';
        deviceName = '${androidInfo.manufacturer} ${androidInfo.model}';
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        final iosInfo = await deviceInfo.iosInfo;
        platform = 'ios';
        deviceName = '${iosInfo.name} (${iosInfo.model})';
      } else if (Platform.isWindows) {
        final winInfo = await deviceInfo.windowsInfo;
        platform = 'windows';
        deviceName = winInfo.computerName;
      } else if (Platform.isMacOS) {
        final macInfo = await deviceInfo.macOsInfo;
        platform = 'macos';
        deviceName = macInfo.computerName;
      }

      _log(
          'VpnService._registerDeviceIfNeeded: Регистрация устройства device_id=$_deviceId, name=$deviceName, platform=$platform');
      final registerData = <String, dynamic>{
        'device_id': _deviceId,
        'name': deviceName,
        'platform': platform,
      };
      final fp = await _getFingerprintForPayload();
      if (fp != null && fp.isNotEmpty) registerData['fingerprint'] = fp;
      final response = await _apiClient.post(
        '/vpn/device/register',
        data: registerData,
        options: await _vpnApiOptions({'Authorization': 'Bearer $token'}),
      );

      _log(
          'VpnService._registerDeviceIfNeeded: ✅ Устройство успешно зарегистрировано, statusCode=${response.statusCode}');
      await _clearConfigCache();
      if (verifyQuota) {
        await _verifyDeviceSlotQuotaOrThrow(token);
      } else {
        unawaited(_verifyDeviceSlotQuotaOrThrow(token));
      }
      _deviceRegistrationDoneThisSession = true;
      await _markDeviceRegistrationCached();
    } on DioException catch (e) {
      // Проверяем статус код для определения типа ошибки
      final statusCode = e.response?.statusCode;
      final responseData = e.response?.data;
      final errorData = responseData is Map ? responseData['error'] : null;
      final errorCode = errorData is Map ? errorData['code'] as String? : null;
      final errorMessage =
          errorData is Map ? errorData['message'] as String? : null;

      if (errorCode == 'DEVICE_LIMIT_EXCEEDED') {
        final message = errorMessage ?? 'Достигнут лимит устройств (5)';
        final details = errorData is Map ? errorData['details'] : null;
        final limit = details is Map ? details['limit'] as int? : null;
        final currentCount =
            details is Map ? details['current_count'] as int? : null;
        final devices = details is Map && details['devices'] is List
            ? details['devices'] as List
            : <dynamic>[];
        _setError(message);
        _notifyListenersFromHelper();
        throw DeviceLimitException(
          message,
          limit: limit,
          currentCount: currentCount,
          devices: devices,
        );
      }

      if (statusCode == 409 || statusCode == 200) {
        // Устройство уже зарегистрировано или успешно зарегистрировано
        _log(
            'VpnService._registerDeviceIfNeeded: ✅ Устройство уже зарегистрировано (statusCode=$statusCode)');
        if (verifyQuota) {
          await _verifyDeviceSlotQuotaOrThrow(token);
        } else {
          unawaited(_verifyDeviceSlotQuotaOrThrow(token));
        }
        _deviceRegistrationDoneThisSession = true;
        await _markDeviceRegistrationCached();
        // НЕ очищаем кэш конфига — reconnect из кэша остаётся возможным
      } else if (statusCode == 401) {
        // Проблема с авторизацией
        _log(
            'VpnService._registerDeviceIfNeeded: ❌ ОШИБКА авторизации при регистрации устройства (statusCode=$statusCode)');
        _log('VpnService._registerDeviceIfNeeded: Токен может быть невалидным');
      } else if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        // Проблемы с сетью
        _log(
            'VpnService._registerDeviceIfNeeded: ⚠️ ОШИБКА сети при регистрации устройства: ${e.type}');
        _log('VpnService._registerDeviceIfNeeded: Сообщение: ${e.message}');
        _log(
            'VpnService._registerDeviceIfNeeded: Продолжаем работу, но устройство может быть не зарегистрировано');
      } else if (statusCode == 400 &&
          (errorMessage?.toLowerCase().contains('лимит устройств') == true ||
              errorMessage?.toLowerCase().contains('device limit') == true ||
              (e.message?.toLowerCase().contains('лимит устройств') ??
                  false))) {
        // Fallback: ловим лимит устройств по тексту, если структура ответа отличается
        final message =
            errorMessage ?? e.message ?? 'Достигнут лимит устройств (5)';
        _setError(message);
        _notifyListenersFromHelper();
        throw DeviceLimitException(message,
            limit: 5, currentCount: 5, devices: const []);
      } else {
        // Другие ошибки
        _log(
            'VpnService._registerDeviceIfNeeded: ❌ ОШИБКА регистрации устройства: ${e.message}');
        _log('VpnService._registerDeviceIfNeeded: Status code: $statusCode');
        _log(
            'VpnService._registerDeviceIfNeeded: Response: ${e.response?.data}');
      }
    } on DeviceLimitException {
      rethrow;
    } catch (e, stackTrace) {
      // Неожиданные ошибки (не лимит устройств)
      _log(
          'VpnService._registerDeviceIfNeeded: ❌ НЕОЖИДАННАЯ ошибка регистрации устройства: $e');
      _log('VpnService._registerDeviceIfNeeded: Stack trace: $stackTrace');
    }
  }

  /// Разбор тела GET `/vpn/devices`. Бэкенд отдаёт JSON-массив; при обёртках — не возвращаем «тихий» [].
  List<dynamic> _parseDevicesListResponse(dynamic data) {
    if (data == null) {
      _log('VpnService.fetchDevices: response.data == null');
      throw VpnException('Пустой ответ при загрузке устройств');
    }
    if (data is List) {
      return List<dynamic>.from(data);
    }
    if (data is Map) {
      for (final key in ['data', 'devices', 'items', 'results']) {
        final v = data[key];
        if (v is List) {
          _log('VpnService.fetchDevices: извлечён список из ключа "$key"');
          return List<dynamic>.from(v);
        }
      }
    }
    _log(
      'VpnService.fetchDevices: неожиданный тип ответа: ${data.runtimeType}',
    );
    throw VpnException('Некорректный формат ответа списка устройств');
  }

  Future<List<dynamic>> fetchDevices(String token) async {
    const maxAttempts = 3;
    final sw = Stopwatch()..start();
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await _apiClient.get(
          '/vpn/devices',
          options: await _vpnApiOptions(
            {'Authorization': 'Bearer $token'},
            readHeavy: true,
          ),
        );
        final parsed = _parseDevicesListResponse(response.data);
        _lastDevicesSnapshot = List<dynamic>.from(parsed);
        _lastDevicesSnapshotAt = DateTime.now();
        final reqId = response.headers.value('x-request-id') ??
            response.requestOptions.headers['X-Request-ID']?.toString();
        sw.stop();
        _log(
          'VpnService.fetchDevices: success attempt=$attempt/$maxAttempts '
          'count=${parsed.length} total_ms=${sw.elapsedMilliseconds} '
          'request_id=${reqId ?? "-"}',
        );
        return parsed;
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        final serverTransient = status == 503 || status == 429;
        final retryable = e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            serverTransient;
        if (!retryable || attempt == maxAttempts) {
          final snap = _lastDevicesSnapshot;
          final snapAt = _lastDevicesSnapshotAt;
          if (snap != null &&
              snapAt != null &&
              DateTime.now().difference(snapAt) <=
                  VpnService._devicesSnapshotTtl) {
            sw.stop();
            _log(
              'VpnService.fetchDevices: fallback stale snapshot '
              'age_ms=${DateTime.now().difference(snapAt).inMilliseconds} '
              'count=${snap.length} total_ms=${sw.elapsedMilliseconds}',
            );
            return List<dynamic>.from(snap);
          }
          rethrow;
        }
        final backoff = Duration(milliseconds: 400 * attempt);
        _log(
          'VpnService.fetchDevices: retry $attempt/$maxAttempts after ${backoff.inMilliseconds}ms (${e.type}${status != null ? ", http=$status" : ""})',
        );
        await Future.delayed(backoff);
      }
    }
    throw VpnException('Не удалось загрузить список устройств');
  }

  Future<List<dynamic>> fetchDevicesWithAuth(
      {bool forceRefresh = false}) async {
    final inFlight = _fetchDevicesInFlight;
    if (inFlight != null) {
      _log('VpnService.fetchDevicesWithAuth: dedupe join in-flight request');
      return inFlight;
    }

    if (!forceRefresh) {
      final snap = _lastDevicesSnapshot;
      final snapAt = _lastDevicesSnapshotAt;
      if (snap != null &&
          snapAt != null &&
          DateTime.now().difference(snapAt) <=
              VpnService._devicesFetchCooldown) {
        _log(
          'VpnService.fetchDevicesWithAuth: cooldown hit '
          'age_ms=${DateTime.now().difference(snapAt).inMilliseconds} count=${snap.length}',
        );
        return List<dynamic>.from(snap);
      }
    }

    final future = () async {
      final token = await _getAuthToken();
      if (token == null || token.isEmpty) {
        throw VpnException('Требуется авторизация');
      }
      return fetchDevices(token);
    }();
    _fetchDevicesInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_fetchDevicesInFlight, future)) {
        _fetchDevicesInFlight = null;
      }
    }
  }

  Future<void> deactivateDevice(String token, String deviceId) async {
    await _apiClient.post(
      '/vpn/device/deactivate',
      data: {
        'device_id': deviceId,
      },
      options: await _vpnApiOptions({'Authorization': 'Bearer $token'}),
    );
  }

  Future<void> deactivateDeviceWithAuth(String deviceId) async {
    final token = await _getAuthToken();
    if (token == null || token.isEmpty) {
      throw VpnException('Требуется авторизация');
    }
    await deactivateDevice(token, deviceId);
  }

  /// Полное удаление устройства из базы (уменьшает счётчик).
  /// Возвращает количество оставшихся устройств.
  Future<int> deleteDevice(String token, String deviceId) async {
    try {
      final response = await _apiClient.post(
        '/vpn/device/delete',
        data: {'device_id': deviceId},
        options: await _vpnApiOptions({'Authorization': 'Bearer $token'}),
      );
      return (response.data?['remaining_devices'] as num?)?.toInt() ?? -1;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final body = e.response?.data;
      _log(
        'VpnService.deleteDevice: [device-delete] target_id=$deviceId '
        'local_device_id=$_deviceId http=$status body=$body',
      );
      rethrow;
    }
  }

  Future<int> deleteDeviceWithAuth(String deviceId) async {
    final token = await _getAuthToken();
    if (token == null || token.isEmpty) {
      throw VpnException('Требуется авторизация');
    }
    final remaining = await deleteDevice(token, deviceId);
    // Поддерживаем консистентный локальный snapshot, чтобы cooldown не возвращал удалённое устройство.
    final snap = _lastDevicesSnapshot;
    if (snap != null) {
      _lastDevicesSnapshot = snap
          .where((d) => (d is Map ? d['device_id'] : null) != deviceId)
          .toList();
      _lastDevicesSnapshotAt = DateTime.now();
    }
    _notifyListenersFromHelper();
    try {
      final refreshed = await fetchDevicesWithAuth(forceRefresh: true);
      if (refreshed.length <= _authService.maxDevices) {
        _authService.clearPendingDeviceLimit();
      }
    } catch (_) {}
    return remaining;
  }
}
