part of '../../services/vpn_service.dart';

/// Network type, MTU selection, and network-change handover helpers for [VpnService].
extension VpnNetworkMtuHelpers on VpnService {
  Future<String> _getNetworkTypeLabel() async {
    try {
      final dynamic result = await Connectivity().checkConnectivity();
      final List<ConnectivityResult> types = result is List
          ? List<ConnectivityResult>.from(result)
          : [result as ConnectivityResult];

      if (types.contains(ConnectivityResult.wifi)) return 'wifi';
      if (types.contains(ConnectivityResult.mobile)) return 'mobile';
      if (types.contains(ConnectivityResult.ethernet)) return 'ethernet';
      if (types.contains(ConnectivityResult.none)) return 'none';
      if (types.isNotEmpty) return types.first.name;
      return 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  int _selectMtu(String? networkType) {
    switch (networkType) {
      case 'wifi':
      case 'ethernet':
        return VpnService._mtuWifi;
      case 'mobile':
        return VpnService._mtuMobile;
      case 'none':
      case 'unknown':
      default:
        return VpnService._mtuDefault;
    }
  }

  List<int> _mtuProfileForNetwork(String? networkType) {
    switch (networkType) {
      case 'mobile':
        return VpnService._mobileMtuFallbackProfile;
      case 'wifi':
      case 'ethernet':
        return VpnService._wifiMtuFallbackProfile;
      default:
        return <int>[VpnService._mtuDefault];
    }
  }

  int? _nextFallbackMtu(String? networkType, int? currentMtu) {
    final profile = _mtuProfileForNetwork(networkType);
    if (profile.isEmpty) return null;
    final currentIndex = currentMtu == null ? -1 : profile.indexOf(currentMtu);
    if (currentIndex < 0) return profile.first;
    if (currentIndex + 1 < profile.length) return profile[currentIndex + 1];
    return null;
  }

  /// Запуск слушателя смены сети: при Wi‑Fi ↔ mobile отключаемся и переподключаемся с правильным MTU.
  void _startNetworkChangeListener() {
    _stopNetworkChangeListener();
    _connectivitySubscription = Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> results) {
      if (!_isConnected || _isDisconnecting || _isConnecting) return;
      _networkChangeDebounce?.cancel();
      _networkChangeDebounce =
          Timer(AppConfig.networkChangeDebounceDuration, () async {
        _networkChangeDebounce = null;
        if (!_isConnected || _isDisconnecting || _isConnecting) return;
        final current = await _getNetworkTypeLabel();
        final atConnect = _lastNetworkType;
        if (atConnect == null || current == atConnect) return;
        const meaningful = ['wifi', 'mobile', 'ethernet'];
        if (!meaningful.contains(current) || !meaningful.contains(atConnect)) {
          return;
        }
        if (_lastReconnectConnectStartedAt != null) {
          final elapsed =
              DateTime.now().difference(_lastReconnectConnectStartedAt!);
          if (elapsed < AppConfig.reconnectMinIntervalAfterNetworkChange) {
            _log(
                'VpnService: [reconnect] смена сети пропущена (cooldown ${elapsed.inMilliseconds}ms < ${AppConfig.reconnectMinIntervalAfterNetworkChange.inMilliseconds}ms)');
            return;
          }
        }
        if (_ignoreNetworkChangeUntil != null &&
            DateTime.now().isBefore(_ignoreNetworkChangeUntil!)) {
          _log(
              'VpnService: [reconnect] смена сети пропущена (grace period после resume, как при закрытии приложения)');
          return;
        }
        _log('VpnService: [MONITOR] network_change $atConnect → $current');
        if (_deviceId != null) {
          _connectionLogger.logNetworkChange(
            deviceId: _deviceId!,
            networkFrom: atConnect,
            networkTo: current,
            protocol: _selectedProtocol.apiValue,
            clientId: _clientId,
            serverId: _selectedServer != null
                ? int.tryParse(_selectedServer!.id)
                : null,
            connectionSessionId: _connectionSessionId,
          );
        }
        if (Platform.isAndroid) {
          // На Android handover обрабатывается в GraniVpnService через native NetworkCallback.
          // Из Flutter логируем событие и обновляем lastNetworkType, чтобы не запускать
          // второй параллельный disconnect/connect цикл.
          _lastNetworkType = current;
          _log(
              'VpnService: [reconnect] Android native handover active, Flutter reconnect skipped');
          return;
        }
        _reconnectAfterNetworkChange = true;
        _log(
            'VpnService: [reconnect] disconnect() начат (reconnectAfterNetworkChange=true)');
        await disconnect(
          reason: VpnDisconnectReason.networkChangeReconnect,
          source: 'network_change_reconnect',
        );
      });
    });
  }

  void _stopNetworkChangeListener() {
    _networkChangeDebounce?.cancel();
    _networkChangeDebounce = null;
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }
}
