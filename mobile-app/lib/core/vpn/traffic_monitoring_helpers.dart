part of '../../services/vpn_service.dart';

extension VpnServiceTrafficMonitoringHelpers on VpnService {
  Duration get connectionDuration {
    if (_connectionStartTime == null) return Duration.zero;
    return DateTime.now().difference(_connectionStartTime!);
  }

  /// Запрос разрешения VPN у пользователя
  /// Возвращает true если разрешение уже есть или получено, false если отклонено
  /// Android: интервал нативных тиков трафика (1 с / 4 с). Вызывать из [WidgetsBindingObserver] (paused vs resumed).
  Future<void> setNativeTrafficTelemetryForAppLifecycle(
      {required bool inBackground}) async {
    await NativeVpnService.setVpnTrafficTelemetryBackgroundMode(inBackground);
  }

  Future<bool> requestVpnPermission() async {
    try {
      _log('VpnService: Запрос разрешения VPN');
      final result = await NativeVpnService.requestVpnPermission();
      _log('VpnService: Результат запроса разрешения: $result');
      return result;
    } catch (e) {
      _log('VpnService: Ошибка запроса разрешения VPN: $e');
      if (e is VpnPermissionException) {
        rethrow;
      }
      return false;
    }
  }

  /// Начинает мониторинг статистики трафика
  void _startTrafficStatsMonitoring() {
    _stopTrafficStatsMonitoring(); // Останавливаем предыдущий таймер, если есть
    _trafficMonitorChannelStatsStart =
        Map<String, int>.from(NativeVpnService.channelCallSnapshot());
    _totalBytesReceived = 0;
    _totalBytesSent = 0;
    _prevTotalBytesForSpeed = 0;
    _prevTrafficStatsTime = null;
    _currentSpeedMbps = null;
    _hasEverSeenTraffic = false;

    // Android: трафик приходит с нативного слоя (emit_type=traffic) раз в 1 с, без Dart-polling getTrafficStats.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _log(
        'VpnService: Мониторинг трафика — нативные события (EventChannel); '
        'safety: sync после 60 с тишины (таймер сбрасывается на каждое нативное событие)',
      );
    } else {
      _trafficStatsTimer =
          Timer.periodic(const Duration(seconds: 1), (timer) async {
        if (!_isConnected) {
          _stopTrafficStatsMonitoring();
          return;
        }

        try {
          final stats = await NativeVpnService.getTrafficStats();
          _applyTrafficSnapshotFromNative(<dynamic, dynamic>{
            'rx_bytes': stats['rx_bytes'] ?? 0,
            'tx_bytes': stats['tx_bytes'] ?? 0,
          });
        } catch (e) {
          _log('VpnService: Ошибка получения статистики трафика: $e');
        }
      });
      _log(
          'VpnService: Мониторинг статистики трафика (1s Dart timer, non-Android)');
    }

    _startNativeConnectedSafetyPoll();
  }

  void _startNativeConnectedSafetyPoll() {
    _touchNativeConnectedSafetyPoll();
  }

  /// Однократный таймер: если за [VpnService._nativeConnectedSafetyInterval] не было ни одного нативного события — [syncConnectionStateWithNative].
  void _touchNativeConnectedSafetyPoll() {
    _nativeConnectedSafetyTimer?.cancel();
    if (!_isConnected) {
      _nativeConnectedSafetyTimer = null;
      return;
    }
    _nativeConnectedSafetyTimer =
        Timer(VpnService._nativeConnectedSafetyInterval, () {
      _nativeConnectedSafetyTimer = null;
      if (!_isConnected) return;
      unawaited(
        syncConnectionStateWithNative().whenComplete(() {
          if (_isConnected) {
            _touchNativeConnectedSafetyPoll();
          }
        }),
      );
    });
  }

  void _stopNativeConnectedSafetyPoll() {
    _nativeConnectedSafetyTimer?.cancel();
    _nativeConnectedSafetyTimer = null;
  }

  /// Останавливает мониторинг статистики трафика
  void _stopTrafficStatsMonitoring() {
    final start = _trafficMonitorChannelStatsStart;
    if (start != null) {
      final end = NativeVpnService.channelCallSnapshot();
      final ds = (end['getStatus'] ?? 0) - (start['getStatus'] ?? 0);
      final dt =
          (end['getTrafficStats'] ?? 0) - (start['getTrafficStats'] ?? 0);
      if (ds > 0 || dt > 0) {
        _log(
          '[vpn-native-channels] за интервал мониторинга трафика: getStatus+$ds getTrafficStats+$dt (MethodChannel)',
        );
      }
    }
    _trafficMonitorChannelStatsStart = null;
    _trafficStatsTimer?.cancel();
    _trafficStatsTimer = null;
    _stopNativeConnectedSafetyPoll();
    _resetPostConnectCommitState();
    _currentSpeedMbps = null;
    _hasEverSeenTraffic = false;
    _log('VpnService: Мониторинг статистики трафика остановлен');
  }

  /// Начинает мониторинг для автопереподключения: без polling — только события [NativeVpnService.nativeVpnStateEvents].
  void _startConnectionMonitoring() {
    _stopConnectionMonitoring();
    _autoReconnectEnabled = true;
    _reconnectionAttempts = 0;
    _log('VpnService: Мониторинг подключения (event-driven) включён');
  }

  /// Останавливает мониторинг подключения
  void _stopConnectionMonitoring() {
    _autoReconnectEnabled = false;
    _log('VpnService: Мониторинг подключения остановлен');
  }

  /// Включает/выключает автоматическое переподключение
  void setAutoReconnect(bool enabled) {
    _autoReconnectEnabled = enabled;
    if (enabled && _isConnected) {
      _startConnectionMonitoring();
    } else {
      _stopConnectionMonitoring();
    }
  }

  /// Получает состояние автоматического переподключения
  bool get autoReconnectEnabled => _autoReconnectEnabled;

  /// Возвращает встроенный обработчик для протокола (делегат к _connectXray/_connectWireGuard и т.д.) или null.
  /// Используется в _connectInternal когда _handlerFactory не задана.
}
