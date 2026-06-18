part of '../../services/vpn_service.dart';

class _DisconnectPipelineExecutor {
  _DisconnectPipelineExecutor(this._s);

  final VpnService _s;

  Future<bool> run({
    required String reason,
    required String source,
  }) async {
    try {
      final disconnectStopwatch = Stopwatch()..start();
      final protocolString = _s._selectedProtocol.apiValue;
      // В disconnect избегаем лишних сетевых/платформенных операций до локального стопа VPN,
      // чтобы анимация «Отключение…» не “замирала”.
      _s._logConnectionStage(
        stage: 'disconnect_start',
        stopwatch: disconnectStopwatch,
        protocol: protocolString,
        disconnectReason: reason,
      );

      // Получаем токен авторизации
      final token = await _s._getAuthToken();

      if (token != null && token.isNotEmpty && _s._deviceId != null) {
        // Отключаемся через API (только при наличии device_id)
        _s._apiClient
            .post(
              '/vpn/disconnect',
              data: {
                'device_id': _s._deviceId,
              },
              options: await _s._vpnApiOptions({'Authorization': 'Bearer $token'}),
            )
            .timeout(AppConfig.disconnectApiTimeout)
            .then((_) {
          _s._log('VpnService.disconnect: ✅ Отключение через API завершено');
        }).catchError((e) {
          _s._log('Ошибка отключения через API: $e');
        });
      }

      if (_s._isXrayProtocol) {
        await _s._disconnectXray(reason: reason, source: source);
      } else if (_s._selectedProtocol == VpnProtocol.graniwg &&
          (Platform.isWindows || Platform.isMacOS)) {
        await _s._disconnectGraniWG();
      } else {
        await NativeVpnService.disconnect(
          reason: reason,
          source: source,
          connectionSessionId: _s._connectionSessionId,
        );
      }

      _s._logConnectionStage(
        stage: 'local_disconnect',
        stopwatch: disconnectStopwatch,
        protocol: protocolString,
        disconnectReason: reason,
      );

      // disconnect_done — полное завершение отключения (для таймингов мониторинга)
      _s._logConnectionStage(
        stage: 'disconnect_done',
        stopwatch: disconnectStopwatch,
        protocol: protocolString,
        disconnectReason: reason,
      );

      await _s._finalizeDisconnectSuccess();
      return true;
    } catch (e) {
      _s._finalizeDisconnectError(e);
      return false;
    }
  }
}
