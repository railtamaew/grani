part of '../../services/vpn_service.dart';

extension VpnServiceSyncControlHelpers on VpnService {
  /// Синхронизация с сервером при старте/resume: если на сервере устройство «подключено», а локально нет
  /// (например, отключились через Quick Tile), отправляем POST disconnect.
  /// Вызывать после syncConnectionStateWithNative() при возврате из фона.
  /// [force]: true — игнорировать throttle (например сразу после resume).
  Future<void> syncConnectionStateWithServer({bool force = false}) async {
    await _syncConnectionState(force: force);
  }

  bool _shouldSkipVpnStatusSync() {
    final next = _nextVpnStatusSyncAllowedAt;
    if (next == null) return false;
    if (DateTime.now().isBefore(next)) {
      _log(
        'VpnService._syncConnectionState: пропуск по throttle до $next '
        '(failures=$_vpnStatusSyncConsecutiveFailures)',
      );
      return true;
    }
    return false;
  }

  void _scheduleNextVpnStatusSync({required bool success}) {
    final now = DateTime.now();
    if (success) {
      _vpnStatusSyncConsecutiveFailures = 0;
      _nextVpnStatusSyncAllowedAt =
          now.add(VpnService._vpnStatusSyncBaseInterval);
      return;
    }
    _vpnStatusSyncConsecutiveFailures =
        (_vpnStatusSyncConsecutiveFailures + 1).clamp(0, 8);
    final exp = _vpnStatusSyncConsecutiveFailures.clamp(1, 4);
    final mult = 1 << (exp - 1);
    var sec = VpnService._vpnStatusSyncBaseInterval.inSeconds * mult;
    if (sec > VpnService._vpnStatusSyncMaxBackoff.inSeconds) {
      sec = VpnService._vpnStatusSyncMaxBackoff.inSeconds;
    }
    _nextVpnStatusSyncAllowedAt = now.add(Duration(seconds: sec));
  }

  /// Синхронизирует состояние подключения с сервером
  /// Проверяет, не подключено ли устройство на сервере, и синхронизирует локальное состояние
  Future<void> _syncConnectionState({bool force = false}) async {
    if (_isConnectFlowGateActive() || _disconnectInProgress) {
      _log(
        'VpnService._syncConnectionState: пропуск — '
        'идёт transition (connect/disconnect)',
      );
      return;
    }
    if (_deviceId == null) {
      _log('VpnService._syncConnectionState: deviceId отсутствует, пропускаем');
      return;
    }
    if (!force && _shouldSkipVpnStatusSync()) {
      return;
    }
    if (_vpnStatusSyncInFlight) {
      _log(
          'VpnService._syncConnectionState: пропуск — уже выполняется другой /vpn/status');
      return;
    }

    _vpnStatusSyncInFlight = true;
    _vpnStatusSyncFlightStartedAt = DateTime.now();
    try {
      final token = await _getAuthToken();
      if (token == null || token.isEmpty) {
        _log(
            'VpnService._syncConnectionState: Токен отсутствует, пропускаем синхронизацию');
        return;
      }

      _log(
          'VpnService._syncConnectionState: Проверка состояния подключения на сервере...');
      _log(
          'VpnService._syncConnectionState: Текущее состояние: _isConnected=$_isConnected, _isConnecting=$_isConnecting');

      // Проверяем состояние подключения на сервере
      try {
        final statusWall = await NetworkTimeouts.vpnStatusWallTimeout();
        final response = await _apiClient
            .get(
          '/vpn/status',
          queryParameters: {
            'device_id': _deviceId,
          },
          options: await _vpnApiOptions(
            {'Authorization': 'Bearer $token'},
            readHeavy: true,
          ),
        )
            .timeout(
          statusWall,
          onTimeout: () {
            _log(
                'VpnService._syncConnectionState: ⚠️ Таймаут запроса /vpn/status (${statusWall.inSeconds} с)');
            throw TimeoutException('Таймаут проверки состояния');
          },
        );

        if (response.statusCode == 200) {
          final isConnectedOnServer = response.data['connected'] == true;
          _log(
              'VpnService._syncConnectionState: Состояние на сервере: connected=$isConnectedOnServer, локальное: _isConnected=$_isConnected');

          // Если на сервере подключено, а локально нет - отключаем на сервере
          if (isConnectedOnServer && !_isConnected) {
            _log(
                'VpnService._syncConnectionState: ⚠️ Несоответствие состояния - отключаем на сервере');
            final disconnectStartTime = DateTime.now();
            try {
              final disconnectSuccess =
                  await _forceDisconnectOnServer(token).timeout(
                const Duration(seconds: 6),
                onTimeout: () {
                  _log(
                      'VpnService._syncConnectionState: ⚠️ Таймаут _forceDisconnectOnServer (6 секунд)');
                  _applyTransition(VpnConnectionState.idle);
                  return false;
                },
              );
              final disconnectDuration =
                  DateTime.now().difference(disconnectStartTime);
              _log(
                  'VpnService._syncConnectionState: Отключение на сервере завершено за ${disconnectDuration.inMilliseconds}ms, успех: $disconnectSuccess');
            } catch (e) {
              _log(
                  'VpnService._syncConnectionState: Ошибка при отключении на сервере: $e');
              _applyTransition(VpnConnectionState.idle);
            }
          } else {
            _log(
                'VpnService._syncConnectionState: ✅ Состояние синхронизировано (сервер: $isConnectedOnServer, локально: $_isConnected)');
          }
          _scheduleNextVpnStatusSync(success: true);
        } else {
          _scheduleNextVpnStatusSync(success: false);
        }
      } on DioException catch (e) {
        // Если эндпоинт не существует (404) или неверный запрос (422/400) - игнорируем
        if (e.response?.statusCode == 404 || e.response?.statusCode == 422) {
          _log(
              'VpnService._syncConnectionState: Эндпоинт /vpn/status не найден или неверный запрос (${e.response?.statusCode}), пропускаем');
          _scheduleNextVpnStatusSync(success: true);
        } else {
          _log(
              'VpnService._syncConnectionState: Ошибка проверки состояния (игнорируем): ${e.response?.statusCode}');
          if (e.response?.statusCode == 400) {
            _log(
                'VpnService._syncConnectionState: тело ответа 400: ${e.response?.data}');
          }
          _scheduleNextVpnStatusSync(success: false);
        }
      } on TimeoutException catch (e) {
        _log('VpnService._syncConnectionState: Таймаут проверки состояния: $e');
        _scheduleNextVpnStatusSync(success: false);
        // Не блокируем подключение при таймауте
      }
    } catch (e) {
      _log(
          'VpnService._syncConnectionState: Ошибка синхронизации состояния (игнорируем): $e');
      _scheduleNextVpnStatusSync(success: false);
      _applyTransition(VpnConnectionState.idle);
    } finally {
      final started = _vpnStatusSyncFlightStartedAt;
      final wallMs = started != null
          ? DateTime.now().difference(started).inMilliseconds
          : -1;
      if (wallMs >= 0) {
        _lastConnectionTimingMs['vpn_status_sync_wall_ms'] = wallMs;
      }
      _log(
        'VpnService._syncConnectionState: sync flight end path_free_for_connect '
        'duration_ms=$wallMs',
      );
      _vpnStatusSyncFlightStartedAt = null;
      _vpnStatusSyncInFlight = false;
    }
  }

  /// Принудительное отключение устройства на сервере
  /// Возвращает true если отключение успешно, false в случае ошибки
  Future<bool> _forceDisconnectOnServer(String token,
      {bool force = false}) async {
    if (_deviceId == null) {
      _log('VpnService._forceDisconnectOnServer: ❌ device_id отсутствует');
      _logger.warning('device_id отсутствует');
      return false;
    }

    final startTime = DateTime.now();
    try {
      _log(
          'VpnService._forceDisconnectOnServer: Начало отключения на сервере (device_id: $_deviceId, force: $force)');
      _logger.debug(
          'Принудительное отключение устройства на сервере (device_id: $_deviceId, force: $force)');
      final response = await _apiClient.post(
        '/vpn/disconnect',
        data: {
          'device_id': _deviceId,
          'force': force, // Используем force для принудительного отключения
        },
        options: await _vpnApiOptions({'Authorization': 'Bearer $token'}),
      );

      final duration = DateTime.now().difference(startTime);
      if (response.statusCode == 200 || response.statusCode == 204) {
        _log(
            'VpnService._forceDisconnectOnServer: ✅ Устройство успешно отключено на сервере за ${duration.inMilliseconds}ms');
        _logger.debug('Устройство успешно отключено на сервере');
        return true;
      } else {
        _log(
            'VpnService._forceDisconnectOnServer: ⚠️ Неожиданный статус код: ${response.statusCode} (время: ${duration.inMilliseconds}ms)');
        _logger.warning('Неожиданный статус код: ${response.statusCode}');
        return false;
      }
    } on DioException catch (e) {
      final duration = DateTime.now().difference(startTime);
      // Если устройство уже отключено (404) или нет доступа (403) - считаем успехом
      if (e.response?.statusCode == 404 || e.response?.statusCode == 403) {
        _log(
            'VpnService._forceDisconnectOnServer: ✅ Устройство уже отключено или нет доступа (status: ${e.response?.statusCode}, время: ${duration.inMilliseconds}ms)');
        _logger.debug(
            'Устройство уже отключено или нет доступа (status: ${e.response?.statusCode})');
        return true;
      }

      // Для ошибки 500 - пробуем принудительное отключение
      if (e.response?.statusCode == 500 && !force) {
        _log(
            'VpnService._forceDisconnectOnServer: ⚠️ Сервер вернул ошибку 500 при отключении, пробуем force=true (время: ${duration.inMilliseconds}ms)');
        _logger.warning(
            'Сервер вернул ошибку 500 при отключении, пробуем принудительное отключение');
        // Пробуем принудительное отключение
        return await _forceDisconnectOnServer(token, force: true);
      }

      // Если force=true и все равно ошибка - считаем частичным успехом
      // (состояние в БД должно быть очищено)
      if (e.response?.statusCode == 500 && force) {
        _log(
            'VpnService._forceDisconnectOnServer: ⚠️ Сервер вернул ошибку 500 даже при force=true (время: ${duration.inMilliseconds}ms)');
        _log(
            'VpnService._forceDisconnectOnServer: Считаем частичным успехом - состояние в БД должно быть очищено');
        _logger.warning(
            'Сервер вернул ошибку 500 даже при force=true, но состояние в БД должно быть очищено');
        return true; // Возвращаем true, чтобы попробовать подключиться снова
      }

      // Для других ошибок логируем детали
      _log(
          'VpnService._forceDisconnectOnServer: ❌ Ошибка принудительного отключения: ${e.message} (status: ${e.response?.statusCode}, время: ${duration.inMilliseconds}ms)');
      _logger.error('Ошибка принудительного отключения', 'VpnService', e);
      if (e.response != null) {
        _log(
            'VpnService._forceDisconnectOnServer: Response data: ${e.response?.data}');
        _logger.debug('Response data: ${e.response?.data}');
      }
      return false;
    } catch (e) {
      final duration = DateTime.now().difference(startTime);
      _log(
          'VpnService._forceDisconnectOnServer: ❌ Неожиданная ошибка: $e (время: ${duration.inMilliseconds}ms)');
      _logger.error(
          'Неожиданная ошибка принудительного отключения', 'VpnService', e);
      return false;
    }
  }

  // Kill Switch функции
  Future<void> enableKillSwitch(bool enable) async {
    _killSwitchEnabled = enable;
    await _enableKillSwitch(enable);
    _notifyListenersFromHelper();
  }

  bool get killSwitchEnabled => _killSwitchEnabled;

  Future<void> _enableKillSwitch(bool enable) async {
    try {
      // В реальной реализации здесь будет блокировка интернета через нативный VPN сервис
      // или системные настройки
      if (enable) {
        _log(
            'Kill Switch включен: интернет будет заблокирован при отключении VPN');
        // Реализация блокировки интернета
        // await NativeVpnService.enableKillSwitch(true);
      } else {
        _log('Kill Switch выключен');
        // await NativeVpnService.enableKillSwitch(false);
      }
    } catch (e) {
      _log('Ошибка управления Kill Switch: $e');
    }
  }

  // Split Tunneling функции
  void setSplitTunnelingApps(List<String> appPackageNames) {
    _splitTunnelingApps = appPackageNames;
    _notifyListenersFromHelper();
  }

  List<String> get splitTunnelingApps => _splitTunnelingApps;

  Future<void> applySplitTunneling() async {
    try {
      if (_splitTunnelingApps.isEmpty) {
        // Если список пуст, все приложения идут через VPN
        _log('Split Tunneling: все приложения используют VPN');
        return;
      }

      _log(
          'Split Tunneling: ${_splitTunnelingApps.length} приложений исключены из VPN');
      // В реальной реализации здесь будет применение настроек Split Tunneling
      // через нативный VPN сервис
      // await NativeVpnService.setSplitTunnelingApps(_splitTunnelingApps);
    } catch (e) {
      _log('Ошибка применения Split Tunneling: $e');
    }
  }
}
