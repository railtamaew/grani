part of '../../services/vpn_service.dart';

/// Device identity, fingerprint, and VPN API request helpers for [VpnService].
extension VpnDeviceIdentityHelpers on VpnService {
  Future<void> _loadDeviceId() async {
    try {
      final secureId = await _storageService.getSecureString('device_id');
      final cachedId = secureId ?? await _storageService.getString('device_id');

      if (cachedId != null && cachedId.isNotEmpty) {
        _deviceId = cachedId;
        if (secureId == null) {
          await _storageService.setSecureString('device_id', cachedId);
        }
        return;
      }

      // Нет локального device_id (переустановка/очистка): пробуем resolve по fingerprint
      final fingerprint = await _getDeviceFingerprint();
      if (fingerprint != null && fingerprint.isNotEmpty) {
        final token = await _storageService.getSecureString('auth_token') ??
            await _storageService.getString('auth_token');
        if (token != null && token.isNotEmpty) {
          final resolvedId =
              await _resolveDeviceIdFromServer(fingerprint, token);
          if (resolvedId != null && resolvedId.isNotEmpty) {
            _deviceId = resolvedId;
            await _storageService.setSecureString('device_id', _deviceId!);
            await _storageService.setString('device_id', _deviceId!);
            _logger.info('device_id восстановлен через resolve по fingerprint');
            return;
          }
        }
      }

      _deviceId = _generateDeviceId();
      await _storageService.setSecureString('device_id', _deviceId!);
      await _storageService.setString('device_id', _deviceId!);
    } catch (e) {
      _logger.error('Ошибка получения device_id', 'VpnService', e);
      _deviceId = 'unknown_${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  /// Стабильный отпечаток устройства для resolve после переустановки (SHA-256 от id + bundle).
  Future<String?> _getDeviceFingerprint() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      final packageInfo = await PackageInfo.fromPlatform();
      final bundleId = packageInfo.packageName;
      String? rawId;
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        rawId =
            androidInfo.id; // Android ID, стабилен при переустановке приложения
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        rawId = iosInfo.identifierForVendor; // может быть null
      } else if (Platform.isWindows) {
        final winInfo = await deviceInfo.windowsInfo;
        rawId = winInfo.deviceId;
      } else if (Platform.isMacOS) {
        final macInfo = await deviceInfo.macOsInfo;
        rawId = macInfo.systemGUID;
      }
      if (rawId == null || rawId.isEmpty) return null;
      final combined = '$rawId#$bundleId';
      final bytes = utf8.encode(combined);
      final digest = sha256.convert(bytes);
      return digest.toString();
    } catch (e) {
      _logger.debug('Ошибка получения fingerprint устройства: $e');
      return null;
    }
  }

  /// Возвращает fingerprint устройства (кеширует после первого получения). Для register/connect.
  Future<String?> _getFingerprintForPayload() async {
    if (_cachedFingerprint != null && _cachedFingerprint!.isNotEmpty) {
      return _cachedFingerprint;
    }
    final fp = await _getDeviceFingerprint();
    if (fp != null && fp.isNotEmpty) {
      _cachedFingerprint = fp;
    }
    return fp;
  }

  /// Данные для POST /vpn/connect (server_id, protocol; device_id и fingerprint опциональны).
  /// Без device_id бэкенд использует единый алгоритм (один коннект на user+server+protocol).
  Future<Map<String, dynamic>> _connectPayload(String protocolValue) async {
    final data = <String, dynamic>{
      'server_id': int.parse(_selectedServer!.id),
      'protocol': protocolValue,
    };
    if (_deviceId != null && _deviceId!.isNotEmpty) {
      data['device_id'] = _deviceId;
    }
    final fp = await _getFingerprintForPayload();
    if (fp != null && fp.isNotEmpty) data['fingerprint'] = fp;
    return data;
  }

  Future<Options> _vpnApiOptions(
    Map<String, dynamic> headers, {
    bool readHeavy = false,
  }) async {
    final t = readHeavy
        ? await NetworkTimeouts.vpnApiReadHeavy()
        : await NetworkTimeouts.vpnApi();
    final extra = <String, dynamic>{
      'grani_connect_timeout': t.connect,
      'grani_send_timeout': t.send,
      'grani_receive_timeout': t.receive,
    };
    return Options(
      sendTimeout: t.send,
      receiveTimeout: t.receive,
      extra: extra,
      headers: headers,
    );
  }

  /// Запрос device_id по fingerprint (POST /api/vpn/device/resolve).
  Future<String?> _resolveDeviceIdFromServer(
      String fingerprint, String token) async {
    try {
      final response = await _apiClient.post(
        '/vpn/device/resolve',
        data: {'fingerprint': fingerprint},
        options: await _vpnApiOptions({
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        }),
      );
      if (response.statusCode == 200 && response.data != null) {
        final deviceId = response.data!['device_id']?.toString();
        return deviceId;
      }
      return null;
    } catch (e) {
      _logger.debug('Resolve device_id не удался: $e');
      return null;
    }
  }

  /// Вызывается ConnectionLogger, когда device_id разрешён по fingerprint.
  /// Обновляет локальный _deviceId и сохраняет в хранилище.
  void _onDeviceIdResolvedByLogger(String newDeviceId) {
    _log(
        'VpnService: device_id обновлён через fingerprint resolve: $newDeviceId (был: $_deviceId)');
    _deviceId = newDeviceId;
    _storageService.setSecureString('device_id', newDeviceId);
    _storageService.setString('device_id', newDeviceId);
  }

  String _generateDeviceId() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant RFC 4122

    String toHex(int value) => value.toRadixString(16).padLeft(2, '0');
    final hex = bytes.map(toHex).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }
}
