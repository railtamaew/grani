part of '../../services/vpn_service.dart';

/// Server/protocol selection and VPN config cache helpers for [VpnService].
extension VpnServerProtocolCacheHelpers on VpnService {
  Future<void> selectProtocol(VpnProtocol protocol) async {
    if (_minimalVpnMode) {
      _selectedProtocol = _minimalVpnProtocol;
      _log(
          'VpnService.selectProtocol: ignored in minimal mode; forced protocol=${_selectedProtocol.apiValue}');
      _notifyListenersFromHelper();
      return;
    }
    // Если уже выбран тот же протокол, ничего не делаем
    if (_selectedProtocol == protocol && !_isConnected && !_isConnecting) {
      return;
    }

    // Если подключены или идет подключение/отключение, сначала отключаемся
    if (_isConnected || _isConnecting || _isDisconnecting) {
      _log('VpnService.selectProtocol: Отключаемся перед сменой протокола...');
      await disconnect(
        reason: VpnDisconnectReason.protocolSwitch,
        source: 'select_protocol',
      );

      // Ждём завершения отключения (макс. 8 с)
      int attempts = 0;
      while ((_isConnecting || _isConnected || _isDisconnecting) &&
          attempts < AppConfig.disconnectWaitConnectMaxAttempts) {
        await Future.delayed(AppConfig.disconnectWaitConnectStep);
        attempts++;
      }
      if (_isConnecting || _isConnected || _isDisconnecting) {
        _log(
            'VpnService.selectProtocol: ⚠️ Таймаут отключения 8 с — принудительный сброс состояния');
        try {
          await NativeVpnService.disconnect(
            reason: VpnDisconnectReason.protocolSwitch,
            source: 'select_protocol_force',
            connectionSessionId: _connectionSessionId,
          );
        } catch (e) {
          _log(
              'VpnService.selectProtocol: Ошибка принудительного отключения: $e');
        }
        _applyTransition(VpnConnectionState.disconnected);
      }
    }

    // Очищаем кэш конфигурации для старого протокола
    await _clearConfigCache();

    _selectedProtocol = protocol;
    _notifyListenersFromHelper();
    _log('VpnService.selectProtocol: Протокол изменен на ${protocol.name}');
    await _persistUserUiSelectionToStorage(reason: 'select_protocol');
  }

  /// Автоматически выбирает оптимальный сервер и протокол
  Future<void> _autoSelectServerAndProtocol() async {
    _updateProgress(ConnectionProgress.autoSelectingServer);

    if (_minimalVpnMode) {
      if (_servers.isEmpty) {
        await refreshServers();
      }
      _forceMinimalVpnSelection(reason: 'auto_select');
      return;
    }

    // Если сервер не выбран, выбираем оптимальный
    if (_selectedServer == null) {
      if (_servers.isEmpty) {
        await refreshServers();
      }

      if (_servers.isNotEmpty) {
        // Выбираем первый активный сервер (можно улучшить логику выбора)
        _selectedServer = _servers.firstWhere(
          (s) => s.isActive == true,
          orElse: () => _servers.first,
        );
        _logger.debug('Автоматически выбран сервер: ${_selectedServer!.id}');
      }
    }

    // Если протокол не поддерживается сервером, выбираем лучший
    if (_selectedServer != null) {
      final protocolString = _selectedProtocol.apiValue;
      final supportedProtocols = _selectedServer!.supportedProtocols;

      if (supportedProtocols != null &&
          supportedProtocols.isNotEmpty &&
          !supportedProtocols.contains(protocolString)) {
        // Выбираем первый поддерживаемый протокол
        final bestProtocol = _findBestProtocol(_selectedServer!);
        if (bestProtocol != null) {
          _selectedProtocol = bestProtocol;
          _logger.debug(
              'Автоматически выбран протокол: ${_selectedProtocol.name}');
        }
      }
    }
  }

  void _forceMinimalVpnSelection({String reason = 'minimal'}) {
    if (!_minimalVpnMode) return;
    Server? minimalServer;
    for (final server in _servers) {
      if (server.id == _minimalVpnServerId && server.isActive) {
        minimalServer = server;
        break;
      }
    }
    minimalServer ??=
        _servers.where((s) => s.id == _minimalVpnServerId).isNotEmpty
            ? _servers.firstWhere((s) => s.id == _minimalVpnServerId)
            : null;
    if (minimalServer != null) {
      _selectedServer = minimalServer;
    } else if (_selectedServer == null && _servers.isNotEmpty) {
      _selectedServer = _servers.first;
      _log(
          'VpnService.minimal_mode: UK-LON-01 id=$_minimalVpnServerId not found; fallback server=${_selectedServer!.id}');
    }
    _selectedProtocol = _minimalVpnProtocol;
    _log(
        'VpnService.minimal_mode: reason=$reason server=${_selectedServer?.id ?? '-'} protocol=${_selectedProtocol.apiValue}');
  }

  /// Находит лучший протокол для сервера из его supportedProtocols
  VpnProtocol? _findBestProtocol(Server server) {
    final supported = server.supportedProtocols;
    if (supported == null || supported.isEmpty) {
      return VpnProtocol.graniwg;
    }
    if (supported.contains('graniwg')) {
      const p = VpnProtocol.graniwg;
      if (p.isImplemented) return p;
    }
    for (final proto in _xrayProtocolPriority) {
      if (supported.contains(proto)) {
        final protocol = _parseProtocolString(proto);
        if (protocol != null && protocol.isImplemented) {
          return protocol;
        }
      }
    }
    return VpnProtocol.graniwg;
  }

  /// Получает кэшированную конфигурацию.
  /// Xray — единый слой Storage (бессрочно), остальные — CacheService (5 мин).
  Future<String?> _getCachedConfig() async {
    if (_selectedServer == null) return null;

    try {
      if (_isXrayProtocol) {
        if (!VpnService._diagnosticAllowReconnectFromCache) {
          return null;
        }
        final cached = await _xrayConnectionHandler.getCachedConfig(
          _selectedServer!,
          _selectedProtocol,
        );
        if (cached != null) {
          _logger.debug('Используем кэшированную Xray конфигурацию из Storage');
          return cached.jsonConfig;
        }
        return null;
      }

      final cacheKey =
          'vpn_config_${_selectedServer!.id}_${_selectedProtocol.name}';
      final cached = await _cacheService.getString(cacheKey);
      if (cached != null && cached.isNotEmpty) {
        final isValid = await _cacheService.isValid(cacheKey);
        if (isValid && _isConfigValid(cached, _selectedProtocol)) {
          _logger.debug(
              'Используем кэшированную конфигурацию (возраст: ${await _cacheService.getAge(cacheKey) ?? 0} сек)');
          return cached;
        }
        if (!_isConfigValid(cached, _selectedProtocol)) {
          await _cacheService.remove(cacheKey);
        }
      }
    } catch (e) {
      _logger.error('Ошибка получения кэша конфигурации', 'VpnService', e);
    }
    return null;
  }

  /// Проверяет валидность конфигурации для указанного протокола
  bool _isConfigValid(String config, VpnProtocol protocol) {
    if (config.isEmpty) return false;

    if (protocol == VpnProtocol.graniwg) {
      final t = config.trim();
      return t.contains('[Interface]') && t.contains('[Peer]');
    }

    // Для XRay: проверяем JSON формат
    if (protocol == VpnProtocol.xrayVless ||
        protocol == VpnProtocol.xrayVmess ||
        protocol == VpnProtocol.xrayReality) {
      if (config.trim().startsWith('{')) {
        try {
          final json = jsonDecode(config);
          return json is Map && json.isNotEmpty;
        } catch (e) {
          return false;
        }
      }
      if (config.startsWith('vless://') || config.startsWith('vmess://')) {
        return config.length > 20;
      }
      return false;
    }

    return true;
  }

  /// Сохраняет конфигурацию в кэш. Xray — единый слой (Storage), остальные — CacheService.
  Future<void> _cacheConfig(String config, [String? clientId]) async {
    if (_selectedServer == null) return;
    try {
      if (_isXrayProtocol) {
        await _saveXrayConfigToStorage(config, clientId);
        _logger.debug('Xray конфиг сохранён в Storage (единый кэш)');
      } else {
        await _cacheService.setString(
          'vpn_config_${_selectedServer!.id}_${_selectedProtocol.name}',
          config,
          ttl: const Duration(minutes: 5),
        );
      }
    } catch (e) {
      _logger.error('Ошибка сохранения кэша конфигурации', 'VpnService', e);
    }
  }

  /// Сохраняет Xray-конфиг в SecureStorage (полный JSON + client_id, persistent).
  Future<void> _saveXrayConfigToStorage(String config,
      [String? clientId]) async {
    if (_selectedServer == null || !_isXrayProtocol) return;
    try {
      final key =
          'xray_config_${_selectedServer!.id}_${_selectedProtocol.apiValue}';
      final value = clientId != null && clientId.isNotEmpty
          ? jsonEncode({'config': config, 'client_id': clientId})
          : config;
      await _storageService.setSecureString(key, value);
    } catch (e) {
      _logger.error(
          'Ошибка сохранения Xray конфига в SecureStorage', 'VpnService', e);
    }
  }

  /// Очищает кэш конфигурации для текущего сервера и протокола.
  Future<void> _clearConfigCache() async {
    if (_selectedServer == null) return;
    try {
      if (_isXrayProtocol) {
        await _storageService.removeSecureString(
          'xray_config_${_selectedServer!.id}_${_selectedProtocol.apiValue}',
        );
      } else {
        await _cacheService.remove(
            'vpn_config_${_selectedServer!.id}_${_selectedProtocol.name}');
      }
      _logger.debug(
          'Кэш конфигурации очищен для протокола ${_selectedProtocol.name}');
    } catch (e) {
      _logger.error('Ошибка очистки кэша конфигурации', 'VpnService', e);
    }
  }

  /// Публичный метод для сброса кэша Xray-конфига. Вызывать после снятия лимита устройств,
  /// чтобы при следующем подключении запросить свежий конфиг с новым client UUID.
  Future<void> clearXrayConfigCache() async {
    await _clearConfigCache();
  }
}
