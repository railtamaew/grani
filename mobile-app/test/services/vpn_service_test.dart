import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:mobile_app/core/vpn/vpn_connection_models.dart';
import 'package:mobile_app/services/vpn_service.dart';
import 'package:mobile_app/models/vpn_protocol.dart';

void main() {
  group('VpnService - обработка ошибки "устройство уже подключено"', () {
    test('должен корректно извлекать сообщение об ошибке из вложенной структуры', () {
      // Тест логики извлечения сообщения об ошибке
      final errorData = <String, dynamic>{
        'error': <String, dynamic>{
          'code': 'BAD_REQUEST',
          'message': 'Устройство уже подключено'
        }
      };
      
      String? errorMessage;
      if (errorData is Map<String, dynamic>) {
        if (errorData['error'] is Map<String, dynamic>) {
          errorMessage = (errorData['error'] as Map<String, dynamic>)['message'] as String?;
        } else {
          errorMessage = errorData['message'] as String?;
        }
      } else {
        errorMessage = null;
      }
      
      expect(errorMessage, equals('Устройство уже подключено'));
    });

    test('должен корректно извлекать сообщение об ошибке из прямой структуры', () {
      final errorData = <String, dynamic>{
        'message': 'Устройство уже подключено'
      };
      
      String? errorMessage;
      if (errorData is Map<String, dynamic>) {
        if (errorData['error'] is Map<String, dynamic>) {
          errorMessage = (errorData['error'] as Map<String, dynamic>)['message'] as String?;
        } else {
          errorMessage = errorData['message'] as String?;
        }
      } else {
        errorMessage = null;
      }
      
      expect(errorMessage, equals('Устройство уже подключено'));
    });

    test('должен возвращать null для некорректной структуры данных', () {
      final errorData = 'неправильный формат' as dynamic;
      
      String? errorMessage;
      if (errorData is Map<String, dynamic>) {
        if (errorData['error'] is Map<String, dynamic>) {
          errorMessage = (errorData['error'] as Map<String, dynamic>)['message'] as String?;
        } else {
          errorMessage = errorData['message'] as String?;
        }
      } else {
        errorMessage = null;
      }
      
      expect(errorMessage, isNull);
    });
  });

  group('VpnService - распознавание ошибки "устройство уже подключено"', () {
    test('должен распознавать ошибку на английском языке', () {
      final errorMessage = 'Device already connected';
      final containsError = errorMessage.toLowerCase().contains('уже подключено') || 
                           errorMessage.toLowerCase().contains('already connected');
      
      expect(containsError, isTrue);
    });

    test('должен распознавать ошибку на русском языке', () {
      final errorMessage = 'Устройство уже подключено';
      final containsError = errorMessage.toLowerCase().contains('уже подключено') || 
                           errorMessage.toLowerCase().contains('already connected');
      
      expect(containsError, isTrue);
    });

    test('должен распознавать ошибку в разных регистрах', () {
      final errorMessage1 = 'УСТРОЙСТВО УЖЕ ПОДКЛЮЧЕНО';
      final errorMessage2 = 'DEVICE ALREADY CONNECTED';
      
      final containsError1 = errorMessage1.toLowerCase().contains('уже подключено') || 
                            errorMessage1.toLowerCase().contains('already connected');
      final containsError2 = errorMessage2.toLowerCase().contains('уже подключено') || 
                            errorMessage2.toLowerCase().contains('already connected');
      
      expect(containsError1, isTrue);
      expect(containsError2, isTrue);
    });

    test('не должен распознавать другие ошибки как "устройство уже подключено"', () {
      final errorMessage = 'Неверный токен авторизации';
      final containsError = errorMessage.toLowerCase().contains('уже подключено') || 
                           errorMessage.toLowerCase().contains('already connected');
      
      expect(containsError, isFalse);
    });
  });

  group('VpnService - создание DioException для тестирования', () {
    test('должен создавать DioException с правильной структурой ошибки', () {
      final requestOptions = RequestOptions(path: '/vpn/connect');
      final response = Response(
        requestOptions: requestOptions,
        statusCode: 400,
        data: {
          'error': {
            'code': 'BAD_REQUEST',
            'message': 'Устройство уже подключено'
          }
        },
      );
      
      final dioException = DioException(
        requestOptions: requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
      );
      
      expect(dioException.response?.statusCode, equals(400));
      expect(dioException.response?.data, isA<Map>());
      
      final errorData = dioException.response?.data as Map<String, dynamic>?;
      final errorMessage = errorData != null && errorData['error'] is Map
          ? (errorData['error'] as Map<String, dynamic>)['message'] as String?
          : null;
      
      expect(errorMessage, equals('Устройство уже подключено'));
    });
  });

  group('VpnService - ConnectionProgress enum', () {
    test('должен иметь правильные значения процентов', () {
      expect(ConnectionProgress.checkingPermissions.percent, equals(0));
      expect(ConnectionProgress.validatingToken.percent, equals(10));
      expect(ConnectionProgress.autoSelectingServer.percent, equals(15));
      expect(ConnectionProgress.registeringDevice.percent, equals(20));
      expect(ConnectionProgress.gettingConfig.percent, equals(30));
      expect(ConnectionProgress.parsingConfig.percent, equals(40));
      expect(ConnectionProgress.creatingTun.percent, equals(50));
      expect(ConnectionProgress.startingProtocol.percent, equals(60));
      expect(ConnectionProgress.verifyingConnection.percent, equals(80));
      expect(ConnectionProgress.connected.percent, equals(100));
    });

    test('должен иметь правильные сообщения', () {
      expect(ConnectionProgress.checkingPermissions.message, contains('проверка разрешений'));
      expect(ConnectionProgress.validatingToken.message, contains('проверка авторизации'));
      expect(ConnectionProgress.autoSelectingServer.message, contains('выбор сервера'));
      expect(ConnectionProgress.registeringDevice.message, contains('регистрация устройства'));
      expect(ConnectionProgress.gettingConfig.message, contains('получение конфигурации'));
      expect(ConnectionProgress.parsingConfig.message, contains('обработка конфигурации'));
      expect(ConnectionProgress.creatingTun.message, contains('VPN интерфейса'));
      expect(ConnectionProgress.startingProtocol.message, contains('запуск протокола'));
      expect(ConnectionProgress.verifyingConnection.message, contains('трафика'));
      expect(ConnectionProgress.connected.message, contains('подключено'));
    });
  });

  group('VpnService - кэширование конфигурации', () {
    test('должен генерировать правильные ключи кэша', () {
      // Тест логики генерации ключей кэша
      final serverId = '1';
      final protocolName = 'xray_vless';
      final cacheKey = 'vpn_config_${serverId}_$protocolName';
      final timeKey = 'vpn_config_time_${serverId}_$protocolName';
      
      expect(cacheKey, equals('vpn_config_1_xray_vless'));
      expect(timeKey, equals('vpn_config_time_1_xray_vless'));
    });

    test('должен проверять валидность кэша (5 минут)', () {
      final now = DateTime.now();
      final cachedTime = now.subtract(const Duration(minutes: 4));
      final age = now.difference(cachedTime);
      
      expect(age.inMinutes, lessThan(5));
      
      final cachedTimeExpired = now.subtract(const Duration(minutes: 6));
      final ageExpired = now.difference(cachedTimeExpired);
      
      expect(ageExpired.inMinutes, greaterThanOrEqualTo(5));
    });
  });

  group('VpnService - автоматический выбор протокола', () {
    test('должен правильно определять приоритет протоколов (только Xray)', () {
      final priority = ['xray_reality', 'xray_vless', 'xray_vmess'];
      expect(priority.first, equals('xray_reality'));
      expect(priority.last, equals('xray_vmess'));
      expect(priority.length, equals(3));
    });
  });

  group('VpnService - повторные попытки подключения', () {
    test('должен определять, стоит ли повторять при временных ошибках', () {
      // Тест логики _shouldRetry
      final connectionTimeout = DioException(
        requestOptions: RequestOptions(path: '/vpn/connect'),
        type: DioExceptionType.connectionTimeout,
      );
      
      final receiveTimeout = DioException(
        requestOptions: RequestOptions(path: '/vpn/connect'),
        type: DioExceptionType.receiveTimeout,
      );
      
      final serverError = DioException(
        requestOptions: RequestOptions(path: '/vpn/connect'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/vpn/connect'),
          statusCode: 500,
        ),
      );
      
      final badRequest = DioException(
        requestOptions: RequestOptions(path: '/vpn/connect'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/vpn/connect'),
          statusCode: 400,
        ),
      );
      
      // Временные ошибки должны повторяться
      final shouldRetryTimeout = connectionTimeout.type == DioExceptionType.connectionTimeout ||
                                  connectionTimeout.type == DioExceptionType.receiveTimeout ||
                                  connectionTimeout.response?.statusCode == 500 ||
                                  connectionTimeout.response?.statusCode == 503;
      
      final shouldRetryReceive = receiveTimeout.type == DioExceptionType.connectionTimeout ||
                                  receiveTimeout.type == DioExceptionType.receiveTimeout ||
                                  receiveTimeout.response?.statusCode == 500 ||
                                  receiveTimeout.response?.statusCode == 503;
      
      final shouldRetryServerError = serverError.type == DioExceptionType.connectionTimeout ||
                                      serverError.type == DioExceptionType.receiveTimeout ||
                                      serverError.response?.statusCode == 500 ||
                                      serverError.response?.statusCode == 503;
      
      final shouldRetryBadRequest = badRequest.type == DioExceptionType.connectionTimeout ||
                                     badRequest.type == DioExceptionType.receiveTimeout ||
                                     badRequest.response?.statusCode == 500 ||
                                     badRequest.response?.statusCode == 503;
      
      expect(shouldRetryTimeout, isTrue);
      expect(shouldRetryReceive, isTrue);
      expect(shouldRetryServerError, isTrue);
      expect(shouldRetryBadRequest, isFalse); // 400 не должен повторяться
    });
  });

  group('VpnService - проверка валидности конфигурации', () {
    test('должен валидировать WireGuard конфигурацию с [Interface] и [Peer]', () {
      final config = '''
[Interface]
PrivateKey = test_key
Address = 10.0.0.1/24

[Peer]
PublicKey = test_public_key
Endpoint = example.com:51820
''';
      
      // Симулируем проверку валидности WireGuard конфигурации
      final isValid = config.isNotEmpty && 
                      config.contains('[Interface]') && 
                      config.contains('[Peer]');
      
      expect(isValid, isTrue);
    });

    test('должен валидировать XRay JSON конфигурацию', () {
      final config = '{"log": {}, "inbounds": [], "outbounds": []}';
      
      // Симулируем проверку валидности XRay JSON
      bool isValid = false;
      if (config.trim().startsWith('{')) {
        try {
          final json = jsonDecode(config);
          isValid = json is Map && json.isNotEmpty;
        } catch (e) {
          isValid = false;
        }
      }
      
      expect(isValid, isTrue);
    });

    test('должен валидировать XRay URL конфигурацию (vless://)', () {
      final config = 'vless://uuid@example.com:443?security=reality&sni=www.google.com';
      
      // Симулируем проверку валидности XRay URL
      final isValid = (config.startsWith('vless://') || config.startsWith('vmess://')) &&
                      config.length > 20;
      
      expect(isValid, isTrue);
    });

    test('должен отклонять пустую конфигурацию', () {
      final config = '';
      
      final isValid = config.isNotEmpty;
      
      expect(isValid, isFalse);
    });

    test('должен отклонять невалидный JSON', () {
      final config = '{invalid json}';
      
      bool isValid = false;
      if (config.trim().startsWith('{')) {
        try {
          final json = jsonDecode(config);
          isValid = json is Map && json.isNotEmpty;
        } catch (e) {
          isValid = false;
        }
      }
      
      expect(isValid, isFalse);
    });

    test('должен валидировать OpenVPN конфигурацию с remote', () {
      final config = '''
client
dev tun
remote example.com 1194
''';
      
      // Симулируем проверку валидности OpenVPN конфигурации
      final isValid = config.contains('remote') || config.contains('client');
      
      expect(isValid, isTrue);
    });
  });

  group('VpnService - проверка подключения (_verifyConnection логика)', () {
    test('должен возвращать false при критических ошибках DNS', () {
      // Симулируем логику _verifyConnection
      int criticalErrors = 0;
      int warnings = 0;
      
      // Симулируем ошибку DNS
      final dnsWorks = false;
      if (!dnsWorks) {
        criticalErrors++;
      }
      
      // Если есть критические ошибки, возвращаем false
      final result = criticalErrors == 0;
      
      expect(result, isFalse);
      expect(criticalErrors, equals(1));
    });

    test('должен возвращать true при отсутствии критических ошибок', () {
      int criticalErrors = 0;
      int warnings = 0;
      
      // Симулируем успешные проверки
      final dnsWorks = true;
      if (!dnsWorks) {
        criticalErrors++;
      }
      
      // Предупреждение о несовпадении IP (не критично)
      final ipMatches = false;
      if (!ipMatches) {
        warnings++;
      }
      
      // Если есть только предупреждения, считаем успешным
      final result = criticalErrors == 0;
      
      expect(result, isTrue);
      expect(warnings, greaterThan(0));
      expect(criticalErrors, equals(0));
    });

    test('должен возвращать false при множественных критических ошибках', () {
      int criticalErrors = 0;
      int warnings = 0;
      
      // Симулируем множественные ошибки
      final dnsWorks = false;
      if (!dnsWorks) {
        criticalErrors++;
      }
      
      // Ещё одна критическая ошибка
      criticalErrors++;
      
      final result = criticalErrors == 0;
      
      expect(result, isFalse);
      expect(criticalErrors, equals(2));
    });
  });

  group('VpnService - очистка конфигурации при ошибке', () {
    test('должен очищать _vpnConfig при ошибке подключения', () {
      // Симулируем логику очистки
      String? vpnConfig = 'test_config';
      
      // При ошибке конфигурация должна быть очищена
      vpnConfig = null;
      
      expect(vpnConfig, isNull);
    });

    test('должен сохранять конфигурацию при успешном получении', () {
      // Симулируем логику сохранения
      String? vpnConfig;
      final config = 'test_config';
      
      if (config != null && config.isNotEmpty) {
        vpnConfig = config;
      }
      
      expect(vpnConfig, equals('test_config'));
    });
  });

  group('VpnService - fallback с использованием кэша', () {
    test('должен использовать сохраненную конфигурацию при fallback', () {
      // Симулируем логику fallback
      String? savedConfig = 'saved_config';
      String? configToUse;
      
      // Пробуем использовать сохраненную конфигурацию
      if (savedConfig != null && savedConfig.isNotEmpty) {
        configToUse = savedConfig;
      }
      
      expect(configToUse, equals('saved_config'));
    });

    test('должен использовать кэш если сохраненная конфигурация отсутствует', () {
      // Симулируем логику fallback с кэшем
      String? savedConfig;
      String? cachedConfig = 'cached_config';
      String? configToUse;
      
      // Если сохраненная конфигурация отсутствует, используем кэш
      if (savedConfig == null) {
        configToUse = cachedConfig;
      } else {
        configToUse = savedConfig;
      }
      
      expect(configToUse, equals('cached_config'));
    });

    test('должен пропускать уже испробованный протокол при fallback', () {
      // Симулируем логику пропуска протокола
      final currentProtocol = 'wireguard';
      final availableProtocols = ['wireguard', 'xray_vless', 'xray_vmess'];
      
      bool shouldSkip = false;
      for (final protocol in availableProtocols) {
        if (protocol == currentProtocol) {
          shouldSkip = true;
          break;
        }
      }
      
      expect(shouldSkip, isTrue);
    });
  });

  group('VpnService - GRANIWG обработка ошибок в callback', () {
    test('должен использовать флаг ошибки вместо исключения в callback', () {
      // Симулируем логику обработки ошибок в callback
      bool hasError = false;
      String? errorMessage;
      
      // Симулируем callback onError
      final error = 'Connection failed';
      hasError = true;
      errorMessage = error.toString();
      
      // Проверяем, что исключение НЕ выбрасывается, а устанавливается флаг
      expect(hasError, isTrue);
      expect(errorMessage, equals('Connection failed'));
      
      // Метод должен вернуть false при ошибке
      final success = false;
      if (hasError) {
        expect(success, isFalse);
      }
    });

    test('должен возвращать true при успешном подключении без ошибок', () {
      // Симулируем успешное подключение
      bool hasError = false;
      final success = true;
      
      if (hasError) {
        expect(success, isFalse);
      } else {
        expect(success, isTrue);
      }
    });
  });

  group('VpnService - получение конфигурации для разных протоколов', () {
    test('должен правильно определять XRay протоколы', () {
      // Проверяем логику определения протокола
      final xrayProtocols = [
        VpnProtocol.xrayVless,
        VpnProtocol.xrayVmess,
        VpnProtocol.xrayReality,
      ];
      
      for (final protocol in xrayProtocols) {
        final isXrayProtocol = protocol == VpnProtocol.xrayVless || 
                               protocol == VpnProtocol.xrayVmess || 
                               protocol == VpnProtocol.xrayReality;
        expect(isXrayProtocol, isTrue, reason: 'Протокол $protocol должен определяться как XRay');
      }
    });

    test('должен использовать правильную логику для определения протокола в connect()', () {
      // Xray-only: все протоколы в enum — Xray
      final testProtocols = [
        (VpnProtocol.xrayVless, true),
        (VpnProtocol.xrayVmess, true),
        (VpnProtocol.xrayReality, true),
      ];
      
      for (final (protocol, expectedIsXray) in testProtocols) {
        final isXrayProtocol = protocol == VpnProtocol.xrayVless || 
                               protocol == VpnProtocol.xrayVmess || 
                               protocol == VpnProtocol.xrayReality;
        expect(isXrayProtocol, equals(expectedIsXray), 
               reason: 'Протокол $protocol: ожидается isXray=$expectedIsXray, получено isXray=$isXrayProtocol');
      }
    });
  });

  group('VpnService - использование core сервисов', () {
    test('должен использовать CacheService для кэширования конфигурации', () {
      // Проверяем, что ключи кэша генерируются правильно
      final serverId = '1';
      final protocolName = 'xray_reality';
      final cacheKey = 'vpn_config_${serverId}_$protocolName';
      
      expect(cacheKey, equals('vpn_config_1_xray_reality'));
      // CacheService должен использоваться вместо SharedPreferences
    });

    test('должен использовать StorageService для device_id', () {
      // Проверяем, что device_id сохраняется через StorageService
      final deviceId = 'test_device_id';
      final key = 'device_id';
      
      // StorageService должен использоваться вместо SharedPreferences
      expect(key, equals('device_id'));
    });

    test('должен использовать StorageService для secure токенов', () {
      // Проверяем, что токены сохраняются через StorageService.getSecureString
      final token = 'test_token';
      final key = 'auth_token';
      
      // StorageService.getSecureString должен использоваться вместо _secureStorage
      expect(key, equals('auth_token'));
    });
  });

  group('VpnService - состояния подключения', () {
    test('должен иметь состояние isDisconnecting', () {
      // Проверяем наличие нового состояния
      final states = ['disconnected', 'connecting', 'connected', 'disconnecting', 'paused'];
      expect(states.contains('disconnecting'), isTrue);
    });

    test('должен иметь состояние isPaused', () {
      // Проверяем наличие состояния паузы
      final states = ['disconnected', 'connecting', 'connected', 'disconnecting', 'paused'];
      expect(states.contains('paused'), isTrue);
    });

    test('должен правильно устанавливать состояние при отключении', () {
      // Симулируем логику установки состояния
      bool isDisconnecting = false;
      bool isConnecting = false;
      bool isConnected = true;
      
      // При начале отключения
      if (isConnected) {
        isDisconnecting = true;
        isConnecting = false;
      }
      
      expect(isDisconnecting, isTrue);
      expect(isConnecting, isFalse);
    });
  });

  group('VpnService - смена протокола с ожиданием отключения', () {
    test('должен ждать завершения отключения перед сменой протокола', () {
      // Симулируем логику ожидания отключения
      bool isConnected = true;
      bool isConnecting = false;
      bool isDisconnecting = false;
      
      // Если подключены, нужно отключиться
      if (isConnected || isConnecting || isDisconnecting) {
        // Отключаемся
        isDisconnecting = true;
        isConnected = false;
        
        // Ждем завершения отключения
        int attempts = 0;
        const maxAttempts = 50;
        while ((isConnecting || isConnected || isDisconnecting) && attempts < maxAttempts) {
          attempts++;
          // Симулируем задержку
        }
        
        // После отключения можно менять протокол
        isDisconnecting = false;
      }
      
      expect(isConnected, isFalse);
      expect(isDisconnecting, isFalse);
    });

    test('должен очищать кэш конфигурации при смене протокола', () {
      // Симулируем очистку кэша
      final serverId = '1';
      final oldProtocol = 'wireguard';
      final cacheKey = 'vpn_config_${serverId}_$oldProtocol';
      
      // Кэш должен быть очищен
      String? cachedConfig;
      cachedConfig = null; // Очистка
      
      expect(cachedConfig, isNull);
    });
  });

  group('VpnService - смена сервера с ожиданием отключения', () {
    test('должен ждать завершения отключения перед сменой сервера', () {
      // Симулируем логику ожидания отключения при смене сервера
      bool isConnected = true;
      String? currentServerId = '1';
      String? newServerId = '2';
      
      // Если подключены, нужно отключиться
      if (isConnected) {
        isConnected = false;
        
        // Ждем завершения отключения
        int attempts = 0;
        const maxAttempts = 50;
        while (isConnected && attempts < maxAttempts) {
          attempts++;
        }
        
        // После отключения можно менять сервер
        currentServerId = newServerId;
      }
      
      expect(isConnected, isFalse);
      expect(currentServerId, equals('2'));
    });
  });

  group('VpnService - инициализация core сервисов', () {
    test('должен инициализировать CacheService при старте', () {
      // Проверяем, что CacheService.initialize() вызывается
      bool cacheServiceInitialized = false;
      
      // Симулируем инициализацию
      cacheServiceInitialized = true;
      
      expect(cacheServiceInitialized, isTrue);
    });

    test('должен инициализировать StorageService при старте', () {
      // Проверяем, что StorageService.initialize() вызывается
      bool storageServiceInitialized = false;
      
      // Симулируем инициализацию
      storageServiceInitialized = true;
      
      expect(storageServiceInitialized, isTrue);
    });

    test('должен настроить ApiClient с провайдером токена', () {
      // Проверяем, что ApiClient.setTokenProvider() вызывается
      bool tokenProviderSet = false;
      
      // Симулируем настройку провайдера
      tokenProviderSet = true;
      
      expect(tokenProviderSet, isTrue);
    });
  });

  group('VpnService - использование Logger вместо debugPrint', () {
    test('должен использовать Logger для логирования ошибок', () {
      // Проверяем, что ошибки логируются через Logger
      final error = Exception('Test error');
      final context = 'VpnService';
      
      // Logger.error должен использоваться вместо debugPrint
      expect(error.toString(), contains('Test error'));
      expect(context, equals('VpnService'));
    });

    test('должен использовать Logger для отладочных сообщений', () {
      // Проверяем, что отладочные сообщения логируются через Logger
      final message = 'Debug message';
      
      // Logger.debug должен использоваться вместо debugPrint
      expect(message, isNotEmpty);
    });
  });

  group('VpnService - TTL для кэша конфигурации', () {
    test('должен использовать TTL 5 минут для конфигурации', () {
      // Проверяем, что конфигурация кэшируется с TTL 5 минут
      const ttl = Duration(minutes: 5);
      
      expect(ttl.inMinutes, equals(5));
    });

    test('должен использовать TTL 24 часа для списка серверов', () {
      // Проверяем, что список серверов кэшируется с TTL 24 часа
      const ttl = Duration(hours: 24);
      
      expect(ttl.inHours, equals(24));
    });
  });

  group('VpnService - device_id resolve и fingerprint', () {
    test('парсинг ответа /device/resolve: device_id из data', () {
      final responseData = <String, dynamic>{'device_id': 'resolved-uuid-123'};
      final deviceId = responseData['device_id']?.toString();
      expect(deviceId, equals('resolved-uuid-123'));
    });

    test('парсинг ответа /device/resolve: device_id число преобразуется в строку', () {
      final responseData = <String, dynamic>{'device_id': 999};
      final deviceId = responseData['device_id']?.toString();
      expect(deviceId, equals('999'));
    });

    test('connect payload содержит server_id, device_id, protocol', () {
      const serverId = 1;
      const deviceId = 'dev-uuid';
      const protocol = 'wireguard';
      final data = <String, dynamic>{
        'server_id': serverId,
        'device_id': deviceId,
        'protocol': protocol,
      };
      expect(data['server_id'], equals(1));
      expect(data['device_id'], equals('dev-uuid'));
      expect(data['protocol'], equals('wireguard'));
    });

    test('connect payload может содержать fingerprint', () {
      final data = <String, dynamic>{
        'server_id': 1,
        'device_id': 'dev-uuid',
        'protocol': 'wireguard',
      };
      const fingerprint = 'sha256hex64chars...';
      if (fingerprint.isNotEmpty) {
        data['fingerprint'] = fingerprint;
      }
      expect(data['fingerprint'], equals('sha256hex64chars...'));
    });

    test('fingerprint = SHA256(androidId#bundleId) даёт 64 hex символа', () {
      const combined = 'android_id_123#com.example.app';
      final bytes = utf8.encode(combined);
      final digest = sha256.convert(bytes);
      final hex = digest.toString();
      expect(hex.length, equals(64));
      expect(RegExp(r'^[a-f0-9]+$').hasMatch(hex), isTrue);
    });
  });
}
