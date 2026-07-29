part of '../../services/vpn_service.dart';

extension VpnServiceServerSelectionAuthHelpers on VpnService {
  Future<void> selectServer(Server server) async {
    if (_minimalVpnMode) {
      _forceMinimalVpnSelection(reason: 'select_server_ignored');
      _notifyListenersFromHelper();
      return;
    }
    // Если подключены или идет подключение/отключение, сначала отключаемся
    if (_isConnected || _isConnecting || _isDisconnecting) {
      _log('VpnService.selectServer: Отключаемся перед сменой сервера...');
      await disconnect(
        reason: VpnDisconnectReason.serverSwitch,
        source: 'select_server',
      );

      // Дополнительная проверка - ждем завершения отключения
      int attempts = 0;
      while ((_isConnecting || _isConnected || _isDisconnecting) &&
          attempts < AppConfig.selectServerWaitDisconnectMaxAttempts) {
        await Future.delayed(AppConfig.selectServerWaitDisconnectStep);
        attempts++;
      }

      // При истечении таймаута локальное состояние принудительно считаем отключённым; смена сервера выполняется.
      // API/сервер при необходимости остаётся в старом состоянии до следующего connect/disconnect.
      if (_isConnecting || _isConnected || _isDisconnecting) {
        _log(
            'VpnService.selectServer: ⚠️ Отключение не завершилось, но продолжаем смену сервера');
        if (_currentState == VpnConnectionState.disconnecting) {
          _applyTransition(VpnConnectionState.disconnected);
        }
      }
    }

    _selectedServer = server;
    _vpnConfig = null;
    _clientId = null;
    _currentIpAddress = null;
    await _clearConfigCache();
    // Синхрон с модалкой протоколов: при смене сервера ставим первый в списке (Xray → … → WireGuard)
    final best = _findBestProtocol(server);
    if (best != null) {
      _selectedProtocol = best;
      _log(
          'VpnService.selectServer: Протокол синхронизирован с порядком в модалке: ${_selectedProtocol.name}');
    }
    _notifyListenersFromHelper();
    _log('VpnService.selectServer: Сервер изменен на ${server.id}');
    await _persistUserUiSelectionToStorage(reason: 'select_server');
  }

  /// Получает токен авторизации из AuthService. Не вызывает ensureValidToken —
  /// ApiClient при 401 сам обновит токен и повторит запрос.
  Future<String?> _getAuthToken() async {
    try {
      final token = _authService.token;
      if (token != null && token.isNotEmpty) return token;
    } catch (e) {
      _logger.error(
          'Ошибка получения токена через AuthService', 'VpnService', e);
    }
    try {
      String? token = await _storageService.getSecureString('auth_token');
      if (token == null) {
        token = await _storageService.getString('auth_token');
        if (token != null) {
          _logger.debug(
              'Токен найден в обычном хранилище (legacy), мигрируем в SecureStorage');
          await _storageService.setSecureString('auth_token', token);
          await _storageService.remove('auth_token');
        }
      }
      return token;
    } catch (e) {
      _logger.error('Ошибка чтения токена из хранилища', 'VpnService', e);
      return null;
    }
  }
}
