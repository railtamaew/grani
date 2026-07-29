part of '../../services/vpn_service.dart';

extension VpnServiceServerCatalogHelpers on VpnService {
  Future<void> refreshServers({bool force = false}) async {
    final perfLogger = PerfLogger();
    final stopwatch = Stopwatch()..start();
    String outcome = 'success';
    int? serverCount;
    const isDebug = kDebugMode;

    // Debounce: предотвращаем дублирующие запросы
    if (_isRefreshing) {
      _log('VpnService.refreshServers: ⏳ Запрос уже выполняется, пропускаем');
      return;
    }

    // Проверяем минимальный интервал между запросами (если не force)
    if (!force && _lastRefreshTime != null) {
      final timeSinceLastRefresh = DateTime.now().difference(_lastRefreshTime!);
      if (timeSinceLastRefresh < VpnService._refreshDebounceInterval) {
        _log(
            'VpnService.refreshServers: ⏳ Слишком частые запросы (${timeSinceLastRefresh.inMilliseconds}ms), пропускаем');
        return;
      }
    }

    _isRefreshing = true;
    _lastRefreshTime = DateTime.now();

    try {
      _log('VpnService.refreshServers: Начало загрузки серверов');

      // Получаем токен авторизации
      final token = await _getAuthToken();

      if (token == null || token.isEmpty) {
        _log(
            'VpnService.refreshServers: ⚠️ Токен отсутствует - загружаем из кэша');
        // Не очищаем список серверов, пытаемся загрузить из кэша
        await _loadServersFromCache();
        _notifyListenersFromHelper();
        return;
      }
      final tokenPreview = token.length > 10 ? token.substring(0, 10) : token;
      _log(
          'VpnService.refreshServers: Токен получен (длина: ${token.length}), первые 10 символов: $tokenPreview...');
      _log('VpnService.refreshServers: API Base URL: ${AppConfig.apiBaseUrl}');
      _log(
          'VpnService.refreshServers: Полный URL: ${AppConfig.apiBaseUrl}/vpn/servers');

      final response = await _apiClient.get(
        '/vpn/servers',
        options: await _vpnApiOptions(
          {'Authorization': 'Bearer $token'},
          readHeavy: true,
        ),
      );

      _log(
          'VpnService.refreshServers: Ответ получен: statusCode=${response.statusCode}');
      if (isDebug) {
        _log(
            'VpnService.refreshServers: Тип данных: ${response.data.runtimeType}');
        _log('VpnService.refreshServers: Полный ответ API: ${response.data}');
      }

      // Дополнительная проверка: если ответ не список, логируем детали
      if (response.statusCode == 200 && response.data is! List) {
        _log(
            'VpnService.refreshServers: ⚠️ ВНИМАНИЕ: API вернул статус 200, но данные не список');
        _log(
            'VpnService.refreshServers: Тип данных: ${response.data.runtimeType}');
        if (response.data is Map) {
          _log(
              'VpnService.refreshServers: Ключи в ответе: ${(response.data as Map).keys.toList()}');
        }
      }

      if (response.statusCode == 200 && response.data is List) {
        final responseList = response.data as List;
        _log(
            'VpnService.refreshServers: Количество серверов в ответе: ${responseList.length}');
        if (responseList.isNotEmpty && isDebug) {
          _log(
            'VpnService.refreshServers: Первый сервер (redacted): ${VpnLogRedaction.redactForLog(responseList.first)}',
          );
        }

        // Обрабатываем каждый сервер отдельно с обработкой ошибок
        final allServers = <Server>[];
        for (var json in responseList) {
          try {
            _log(
                'VpnService.refreshServers: Обрабатываем сервер: id=${json['id']}, name=${json['name']}, protocols=${json['supported_protocols']}');
            if (isDebug) {
              _log(
                'VpnService.refreshServers: Полные данные сервера (redacted): ${VpnLogRedaction.redactForLog(json)}',
              );
            }

            // Проверяем наличие обязательных полей
            if (json['wireguard_public_key'] == null ||
                (json['wireguard_public_key'] as String).isEmpty) {
              _log(
                  'VpnService.refreshServers: ПРЕДУПРЕЖДЕНИЕ - у сервера ${json['id']} отсутствует wireguard_public_key');
            }

            final raw = Map<String, dynamic>.from(json as Map);
            final server = Server.fromJson(raw);
            allServers.add(server);
            _log(
                'VpnService.refreshServers: Сервер ${server.id} успешно загружен: name=${server.name}, country=${server.country}, city=${server.city}, wireguard_public_key=${server.wireguardPublicKey != null ? "установлен" : "отсутствует"}');
          } catch (e, stackTrace) {
            _log(
                'VpnService.refreshServers: ОШИБКА парсинга сервера ${json['id']}: $e');
            _log(
              'VpnService.refreshServers: Данные сервера (redacted): ${VpnLogRedaction.redactForLog(json)}',
            );
            _log('VpnService.refreshServers: Stack trace: $stackTrace');
            // Продолжаем обработку остальных серверов
          }
        }

        // Фильтруем только активные серверы
        // Для WireGuard требуется wireguard_public_key, для Xray нет
        _servers = allServers.where((server) {
          if (!server.isActive) {
            _log(
                'VpnService.refreshServers: Сервер ${server.id} отфильтрован: неактивен');
            return false;
          }

          final protocols = server.supportedProtocols ?? ['xray_reality'];

          final hasWireguard = protocols.contains('wireguard');
          final hasXray = protocols.any((p) => p.startsWith('xray_'));

          if (!hasWireguard && !hasXray) {
            _log(
                'VpnService.refreshServers: Сервер ${server.id} отфильтрован: нет WireGuard/Xray');
            return false;
          }

          if (hasWireguard &&
              (server.wireguardPublicKey == null ||
                  server.wireguardPublicKey!.isEmpty) &&
              !hasXray) {
            _log(
                'VpnService.refreshServers: Сервер ${server.id} отфильтрован: WireGuard без ключа');
            return false;
          }

          return true;
        }).toList();

        _log(
            'VpnService.refreshServers: После фильтрации осталось ${_servers.length} серверов из ${allServers.length}');

        // КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: Если после фильтрации список пуст, но есть активные серверы - используем fallback
        if (_servers.isEmpty && allServers.isNotEmpty) {
          _log(
              'VpnService.refreshServers: ⚠️ КРИТИЧЕСКАЯ ПРОБЛЕМА - все серверы отфильтрованы');
          _log(
              'VpnService.refreshServers: Всего серверов до фильтрации: ${allServers.length}');

          // Логируем детали каждого сервера только в debug режиме
          if (isDebug) {
            _log(
                'VpnService.refreshServers: 📋 Детали серверов до фильтрации:');
            for (var server in allServers) {
              final protocols = server.supportedProtocols ?? ['xray_reality'];
              final hasKey = server.wireguardPublicKey != null &&
                  server.wireguardPublicKey!.isNotEmpty;
              _log(
                  'VpnService.refreshServers:   - Сервер ${server.id} (${server.name}):');
              _log(
                  'VpnService.refreshServers:     isActive=${server.isActive}');
              _log(
                  'VpnService.refreshServers:     supportedProtocols=$protocols');
              _log('VpnService.refreshServers:     hasWireguardKey=$hasKey');
              if (!server.isActive) {
                _log(
                    'VpnService.refreshServers:     ❌ Отфильтрован: неактивен');
              } else if (protocols.contains('wireguard') &&
                  !hasKey &&
                  !protocols.any((p) => p.startsWith('xray_'))) {
                _log(
                    'VpnService.refreshServers:     ❌ Отфильтрован: WireGuard без ключа и нет Xray');
              } else if (!protocols.contains('wireguard') &&
                  !protocols.any((p) => p.startsWith('xray_'))) {
                _log(
                    'VpnService.refreshServers:     ❌ Отфильтрован: нет WireGuard/Xray');
              } else {
                _log(
                    'VpnService.refreshServers:     ✅ Сервер должен быть доступен, но был отфильтрован (неизвестная причина)');
              }
            }
          }

          // FALLBACK: Показываем все активные серверы, даже если у них нет ключа
          // Это позволит пользователю видеть серверы и выбирать протоколы, которые не требуют ключа
          try {
            final activeServers = allServers.where((s) => s.isActive).toList();
            if (activeServers.isNotEmpty) {
              _log(
                  'VpnService.refreshServers: 🔄 FALLBACK: Используем ${activeServers.length} активных серверов');
              for (var server in activeServers) {
                _log(
                    'VpnService.refreshServers:   - Сервер ${server.id} (${server.name}): protocols=${server.supportedProtocols}');
              }
              _log(
                  'VpnService.refreshServers: ⚠️ ВНИМАНИЕ: Некоторые серверы могут не поддерживать все протоколы');
              _servers = activeServers;
            } else {
              // Если нет активных серверов, используем первый неактивный
              _log(
                  'VpnService.refreshServers: 🔄 FALLBACK: Нет активных серверов, используем первый сервер');
              _servers = [allServers.first];
            }
          } catch (e) {
            _log(
                'VpnService.refreshServers: ❌ ОШИБКА: Не удалось найти fallback сервер: $e');
          }
        } else if (_servers.isEmpty && allServers.isEmpty) {
          _log(
              'VpnService.refreshServers: ❌ Серверы не были загружены из API (пустой ответ)');
        } else {
          _log(
              'VpnService.refreshServers: ✅ Успешно загружено ${_servers.length} серверов');
          for (var server in _servers) {
            _log(
                'VpnService.refreshServers:   ✓ Сервер ${server.id} (${server.name}): protocols=${server.supportedProtocols}');
          }
        }

        if (_servers.isNotEmpty) {
          try {
            _servers = await enrichServersWithClientPing(_servers);
            _log(
                'VpnService.refreshServers: клиентский TCP-замер для серверов без ping_ms завершён');
          } catch (e) {
            _log(
                'VpnService.refreshServers: клиентский TCP-замер пропущен: $e');
          }
        }

        // Minimal VPN keeps a fixed server/protocol after auth.
        if (_minimalVpnMode) {
          _forceMinimalVpnSelection(reason: 'refresh_servers');
        } else if (_selectedServer != null) {
          final found = _servers.firstWhere(
            (s) => s.id == _selectedServer!.id,
            orElse: () =>
                _servers.isNotEmpty ? _servers.first : _selectedServer!,
          );
          _selectedServer = found;
          _log(
              'VpnService.refreshServers: Выбранный сервер: ${_selectedServer!.id} (${_selectedServer!.name})');
        } else if (_servers.isNotEmpty) {
          await _restoreLastConnectedSelection();
          if (_selectedServer == null) {
            _selectedServer = _servers.first;
            _log(
                'VpnService.refreshServers: Автоматически выбран первый сервер: ${_selectedServer!.id} (${_selectedServer!.name})');
            final best = _findBestProtocol(_selectedServer!);
            if (best != null) {
              _selectedProtocol = best;
              _log(
                  'VpnService.refreshServers: Протокол синхронизирован с порядком в модалке: ${_selectedProtocol.name}');
            }
          }
        } else {
          _log(
              'VpnService.refreshServers: ПРЕДУПРЕЖДЕНИЕ - список серверов пуст');
        }

        // Сохраняем успешно загруженный список в кэш
        await _saveServersToCache(_servers);
        _log('VpnService.refreshServers: ✅ Список серверов сохранен в кэш');
      } else {
        _log('VpnService.refreshServers: ❌ ОШИБКА - неверный формат ответа');
        _log('VpnService.refreshServers: statusCode=${response.statusCode}');
        _log(
            'VpnService.refreshServers: Тип данных: ${response.data.runtimeType}');
        _log('VpnService.refreshServers: Данные: ${response.data}');

        // Если статус 200, но данные не список - это проблема API
        if (response.statusCode == 200) {
          _log(
              'VpnService.refreshServers: ⚠️ API вернул статус 200, но данные не в формате списка');
          _log(
              'VpnService.refreshServers: Ожидался List, получен: ${response.data.runtimeType}');
        }

        // Не очищаем список, пытаемся загрузить из кэша
        if (_servers.isEmpty) {
          await _loadServersFromCache();
        }
      }
    } catch (e, stackTrace) {
      outcome = 'error';
      _log('VpnService.refreshServers: ❌ ОШИБКА загрузки серверов: $e');
      _log('VpnService.refreshServers: Тип ошибки: ${e.runtimeType}');
      if (e is DioException) {
        _log('VpnService.refreshServers: DioException details:');
        _log(
            'VpnService.refreshServers:   - Response status: ${e.response?.statusCode}');
        _log(
            'VpnService.refreshServers:   - Response data: ${e.response?.data}');
        _log(
            'VpnService.refreshServers:   - Request path: ${e.requestOptions.path}');
        _log(
            'VpnService.refreshServers:   - Request headers: ${e.requestOptions.headers}');
        if (e.response?.statusCode == 401) {
          _log(
              'VpnService.refreshServers: ⚠️ Ошибка авторизации (401) - возможно, токен невалиден или истек');
        } else if (e.response?.statusCode == 403) {
          _log('VpnService.refreshServers: ⚠️ Доступ запрещен (403)');
        }
      }
      _log('VpnService.refreshServers: Stack trace: $stackTrace');

      // Не очищаем список при ошибке, пытаемся загрузить из кэша
      if (_servers.isEmpty) {
        await _loadServersFromCache();
      }
    } finally {
      serverCount ??= _servers.length;
      _isRefreshing = false;
      stopwatch.stop();
      perfLogger
          .record('refresh_servers', stopwatch.elapsedMilliseconds, details: {
        'outcome': outcome,
        'servers': serverCount,
      });
    }

    _notifyListenersFromHelper();
  }

  Future<void> loadServers() async {
    await refreshServers();
  }

  /// Сохраняет список серверов в кэш (SharedPreferences)
  Future<void> _saveServersToCache(List<Server> servers) async {
    try {
      final serversJson = servers.map((server) => server.toJson()).toList();
      final serversJsonString = jsonEncode(serversJson);
      // Кэш серверов валиден 24 часа
      await _cacheService.setString('cached_servers', serversJsonString,
          ttl: const Duration(hours: 24));
      _logger.debug('Сохранено ${servers.length} серверов в кэш');
    } catch (e) {
      _logger.error('Ошибка сохранения в кэш', 'VpnService', e);
    }
  }

  /// Загружает список серверов из кэша
  Future<void> _loadServersFromCache() async {
    try {
      final serversJsonString = await _cacheService.getString('cached_servers');

      if (serversJsonString == null || serversJsonString.isEmpty) {
        _logger.debug('Кэш серверов пуст');
        return;
      }

      // Проверяем валидность кэша (TTL 24 часа)
      final isValid = await _cacheService.isValid('cached_servers');
      if (!isValid) {
        _logger.debug('Кэш серверов истек, игнорируем');
        await _cacheService.remove('cached_servers');
        return;
      }

      final age = await _cacheService.getAge('cached_servers');
      if (age != null) {
        final cacheAgeHours = age / 3600;
        _logger
            .debug('Возраст кэша: ${cacheAgeHours.toStringAsFixed(2)} часов');
      }

      final serversJson = jsonDecode(serversJsonString) as List;
      final cachedServers = serversJson
          .map((json) => Server.fromJson(json as Map<String, dynamic>))
          .toList();

      if (cachedServers.isNotEmpty) {
        _servers = cachedServers;
        _logger.debug('Загружено ${_servers.length} серверов из кэша');

        // Восстанавливаем выбранный сервер: сначала из памяти, иначе из последнего подключения, иначе первый
        if (_selectedServer != null) {
          final found = _servers.firstWhere(
            (s) => s.id == _selectedServer!.id,
            orElse: () =>
                _servers.isNotEmpty ? _servers.first : _selectedServer!,
          );
          _selectedServer = found;
        } else if (_servers.isNotEmpty) {
          await _restoreLastConnectedSelection();
          if (_selectedServer == null) {
            _selectedServer = _servers.first;
            final best = _findBestProtocol(_servers.first);
            if (best != null) _selectedProtocol = best;
          }
        }
      } else {
        _logger.debug('Кэш пуст после парсинга');
      }
    } catch (e, stackTrace) {
      _logger.error('Ошибка загрузки из кэша', 'VpnService', e, stackTrace);
    }
  }
}
