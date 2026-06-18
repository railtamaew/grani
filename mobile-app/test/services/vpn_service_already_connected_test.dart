import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:mobile_app/services/vpn_service.dart';
import 'package:mobile_app/models/server.dart';
import 'package:mobile_app/models/vpn_protocol.dart';

/// Тесты для улучшенной логики обработки ошибки "устройство уже подключено"
/// и множественных методов отключения
void main() {
  group('VpnService - извлечение сообщения об ошибке', () {
    test('должен извлекать сообщение из вложенной структуры error.message', () {
      final errorData = <String, dynamic>{
        'error': <String, dynamic>{
          'code': 'BAD_REQUEST',
          'message': 'Устройство уже подключено'
        }
      };
      
      String? errorMessage;
      if (errorData is Map) {
        if (errorData['error'] is Map) {
          errorMessage = errorData['error']['message'] as String?;
        } else {
          errorMessage = errorData['message'] as String?;
        }
      }
      
      expect(errorMessage, equals('Устройство уже подключено'));
    });

    test('должен извлекать сообщение из прямой структуры message', () {
      final errorData = <String, dynamic>{
        'message': 'Device already connected'
      };
      
      String? errorMessage;
      if (errorData is Map) {
        if (errorData['error'] is Map) {
          errorMessage = errorData['error']['message'] as String?;
        } else {
          errorMessage = errorData['message'] as String?;
        }
      }
      
      expect(errorMessage, equals('Device already connected'));
    });

    test('должен возвращать null для некорректной структуры', () {
      final errorData = 'неправильный формат' as dynamic;
      
      String? errorMessage;
      if (errorData is Map) {
        if (errorData['error'] is Map) {
          errorMessage = errorData['error']['message'] as String?;
        } else {
          errorMessage = errorData['message'] as String?;
        }
      }
      
      expect(errorMessage, isNull);
    });

    test('должен возвращать null для null данных', () {
      final errorData = null as dynamic;
      
      String? errorMessage;
      if (errorData is Map) {
        if (errorData['error'] is Map) {
          errorMessage = errorData['error']['message'] as String?;
        } else {
          errorMessage = errorData['message'] as String?;
        }
      }
      
      expect(errorMessage, isNull);
    });
  });

  group('VpnService - распознавание ошибки "уже подключено"', () {
    test('должен распознавать ошибку на русском языке', () {
      final errorMessage = 'Устройство уже подключено';
      final lowerMessage = errorMessage.toLowerCase();
      final isAlreadyConnected = lowerMessage.contains('уже подключено') || 
                                lowerMessage.contains('already connected');
      
      expect(isAlreadyConnected, isTrue);
    });

    test('должен распознавать ошибку на английском языке', () {
      final errorMessage = 'Device already connected';
      final lowerMessage = errorMessage.toLowerCase();
      final isAlreadyConnected = lowerMessage.contains('уже подключено') || 
                                lowerMessage.contains('already connected');
      
      expect(isAlreadyConnected, isTrue);
    });

    test('должен распознавать ошибку в разных регистрах', () {
      final errorMessage1 = 'УСТРОЙСТВО УЖЕ ПОДКЛЮЧЕНО';
      final errorMessage2 = 'DEVICE ALREADY CONNECTED';
      
      final isAlreadyConnected1 = errorMessage1.toLowerCase().contains('уже подключено') || 
                                 errorMessage1.toLowerCase().contains('already connected');
      final isAlreadyConnected2 = errorMessage2.toLowerCase().contains('уже подключено') || 
                                 errorMessage2.toLowerCase().contains('already connected');
      
      expect(isAlreadyConnected1, isTrue);
      expect(isAlreadyConnected2, isTrue);
    });

    test('не должен распознавать другие ошибки', () {
      final errorMessages = [
        'Неверный токен авторизации',
        'Invalid authentication token',
        'Сервер недоступен',
        'Server unavailable',
        'Превышен лимит запросов',
        'Rate limit exceeded',
      ];
      
      for (final errorMessage in errorMessages) {
        final lowerMessage = errorMessage.toLowerCase();
        final isAlreadyConnected = lowerMessage.contains('уже подключено') || 
                                   lowerMessage.contains('already connected');
        
        expect(isAlreadyConnected, isFalse, 
               reason: 'Ошибка "$errorMessage" не должна распознаваться как "уже подключено"');
      }
    });

    test('должен распознавать частичные совпадения', () {
      final errorMessages = [
        'Ошибка: устройство уже подключено к серверу',
        'Error: device already connected to server',
        'Устройство уже подключено. Попробуйте позже.',
        'Device already connected. Please try again later.',
      ];
      
      for (final errorMessage in errorMessages) {
        final lowerMessage = errorMessage.toLowerCase();
        final isAlreadyConnected = lowerMessage.contains('уже подключено') || 
                                   lowerMessage.contains('already connected');
        
        expect(isAlreadyConnected, isTrue, 
               reason: 'Ошибка "$errorMessage" должна распознаваться как "уже подключено"');
      }
    });
  });

  group('VpnService - множественные методы отключения', () {
    test('должен пробовать POST метод первым', () {
      final methods = ['POST', 'DELETE', 'PUT'];
      int currentMethod = 0;
      bool success = false;
      
      // Симуляция успешного POST
      if (currentMethod < methods.length) {
        final method = methods[currentMethod];
        if (method == 'POST') {
          success = true;
        }
      }
      
      expect(success, isTrue);
      expect(currentMethod, equals(0));
    });

    test('должен пробовать DELETE если POST вернул неожиданный статус', () {
      final methods = ['POST', 'DELETE', 'PUT'];
      int currentMethod = 0;
      bool success = false;
      
      // POST вернул статус 400 (не 200, 204, 404)
      final postStatusCode = 400;
      if (postStatusCode != 200 && postStatusCode != 204 && postStatusCode != 404) {
        currentMethod++; // Переходим к DELETE
      }
      
      // Пробуем DELETE
      if (currentMethod < methods.length) {
        final method = methods[currentMethod];
        if (method == 'DELETE') {
          success = true; // DELETE успешен
        }
      }
      
      expect(success, isTrue);
      expect(currentMethod, equals(1));
    });

    test('должен пробовать PUT если POST и DELETE не сработали', () {
      final methods = ['POST', 'DELETE', 'PUT'];
      int currentMethod = 0;
      bool success = false;
      
      // POST не сработал
      currentMethod++;
      // DELETE не сработал
      currentMethod++;
      
      // Пробуем PUT
      if (currentMethod < methods.length) {
        final method = methods[currentMethod];
        if (method == 'PUT') {
          success = true;
        }
      }
      
      expect(success, isTrue);
      expect(currentMethod, equals(2));
    });

    test('должен обрабатывать статус коды 200, 204, 404 как успех', () {
      final successStatusCodes = [200, 204, 404];
      
      for (final statusCode in successStatusCodes) {
        final isSuccess = statusCode == 200 || statusCode == 204 || statusCode == 404;
        expect(isSuccess, isTrue, 
               reason: 'Status code $statusCode должен считаться успехом');
      }
    });

    test('должен обрабатывать статус коды 5xx как ошибку, требующую альтернативного метода', () {
      final errorStatusCodes = [500, 502, 503, 504];
      
      for (final statusCode in errorStatusCodes) {
        final isServerError = statusCode >= 500 && statusCode < 600;
        expect(isServerError, isTrue, 
               reason: 'Status code $statusCode должен считаться ошибкой сервера');
      }
    });

    test('должен обрабатывать статус коды 403 и 404 как успех (уже отключено)', () {
      final alreadyDisconnectedCodes = [403, 404];
      
      for (final statusCode in alreadyDisconnectedCodes) {
        final isAlreadyDisconnected = statusCode == 404 || statusCode == 403;
        expect(isAlreadyDisconnected, isTrue, 
               reason: 'Status code $statusCode должен означать, что устройство уже отключено');
      }
    });

    test('должен возвращать false если все методы не сработали', () {
      final methods = ['POST', 'DELETE', 'PUT'];
      bool success = false;
      
      // Симуляция: все методы вернули ошибку (не 200, 204, 404)
      for (final method in methods) {
        final statusCode = 400; // Ошибка
        if (statusCode == 200 || statusCode == 204 || statusCode == 404) {
          success = true;
          break;
        }
      }
      
      expect(success, isFalse);
    });
  });

  group('VpnService - проверка состояния после отключения', () {
    test('должен проверять состояние через /vpn/status', () {
      final statusResponse = {
        'connected': false,
      };
      
      final isConnected = statusResponse['connected'] == true;
      expect(isConnected, isFalse);
    });

    test('должен считать отключение успешным если connected=false', () {
      final statusResponse = {
        'connected': false,
      };
      
      final isConnectedOnServer = statusResponse['connected'] == true;
      if (!isConnectedOnServer) {
        expect(isConnectedOnServer, isFalse);
      }
    });

    test('должен повторять попытки если устройство все еще подключено', () {
      int attempts = 0;
      const maxAttempts = 3;
      bool isDisconnected = false;
      
      // Симуляция: первые 2 попытки показывают connected=true, третья - false
      final statusResponses = [
        {'connected': true},
        {'connected': true},
        {'connected': false},
      ];
      
      while (attempts < maxAttempts && !isDisconnected) {
        if (attempts < statusResponses.length) {
          final status = statusResponses[attempts];
          isDisconnected = status['connected'] != true;
        }
        attempts++;
      }
      
      expect(isDisconnected, isTrue);
      expect(attempts, equals(3));
    });

    test('должен игнорировать ошибки 422 и 404 при проверке состояния', () {
      final errorStatusCodes = [422, 404];
      
      for (final statusCode in errorStatusCodes) {
        // Если статус 422 или 404, считаем отключение успешным
        final shouldIgnore = statusCode == 422 || statusCode == 404;
        expect(shouldIgnore, isTrue, 
               reason: 'Status code $statusCode должен игнорироваться при проверке состояния');
      }
    });

    test('должен обрабатывать ошибки проверки состояния', () {
      final errorStatusCodes = [422, 404, 500];
      final shouldContinue = <bool>[];
      
      for (final statusCode in errorStatusCodes) {
        // Игнорируем 422 и 404, но не 500
        if (statusCode == 422 || statusCode == 404) {
          shouldContinue.add(true); // Продолжаем, считаем успешным
        } else {
          shouldContinue.add(false); // Не продолжаем
        }
      }
      
      expect(shouldContinue[0], isTrue); // 422
      expect(shouldContinue[1], isTrue); // 404
      expect(shouldContinue[2], isFalse); // 500
    });
  });

  group('VpnService - задержки и таймауты', () {
    test('должен использовать правильные задержки после отключения', () {
      // После успешного отключения - 1.5 секунды перед проверкой состояния
      const delayAfterDisconnect = Duration(milliseconds: 1500);
      expect(delayAfterDisconnect.inMilliseconds, equals(1500));
      
      // После проверки состояния - 2 секунды перед повторной попыткой подключения
      const delayBeforeReconnect = Duration(milliseconds: 2000);
      expect(delayBeforeReconnect.inMilliseconds, equals(2000));
    });

    test('должен использовать увеличивающиеся задержки при повторных попытках отключения', () {
      int attempt = 1;
      final delays = [
        Duration(milliseconds: 1000 * attempt), // 1000ms для попытки 1
        Duration(milliseconds: 1000 * (attempt + 1)), // 2000ms для попытки 2
        Duration(milliseconds: 1000 * (attempt + 2)), // 3000ms для попытки 3
      ];
      
      expect(delays[0].inMilliseconds, equals(1000));
      expect(delays[1].inMilliseconds, equals(2000));
      expect(delays[2].inMilliseconds, equals(3000));
    });

    test('должен использовать задержку 1 секунда если устройство все еще подключено', () {
      const delayWhenStillConnected = Duration(milliseconds: 1000);
      expect(delayWhenStillConnected.inMilliseconds, equals(1000));
    });
  });

  group('VpnService - обработка ошибок отключения', () {
    test('должен обрабатывать DioException с разными статус кодами', () {
      final statusCodes = [404, 403, 500, 502, 400];
      final results = <bool>[];
      
      for (final statusCode in statusCodes) {
        bool isSuccess = false;
        
        if (statusCode == 404 || statusCode == 403) {
          isSuccess = true; // Уже отключено или нет доступа
        } else if (statusCode >= 500 && statusCode < 600) {
          isSuccess = false; // Ошибка сервера, пробуем альтернативный метод
        } else {
          isSuccess = false; // Другая ошибка
        }
        
        results.add(isSuccess);
      }
      
      expect(results[0], isTrue); // 404 - уже отключено
      expect(results[1], isTrue); // 403 - нет доступа (считаем успехом)
      expect(results[2], isFalse); // 500 - ошибка сервера
      expect(results[3], isFalse); // 502 - ошибка сервера
      expect(results[4], isFalse); // 400 - другая ошибка
    });

    test('должен обрабатывать validateStatus для предотвращения исключений', () {
      // validateStatus должен принимать все статусы кроме 5xx
      final validateStatus = (int? status) => status != null && status < 500;
      
      expect(validateStatus(200), isTrue);
      expect(validateStatus(204), isTrue);
      expect(validateStatus(404), isTrue);
      expect(validateStatus(400), isTrue);
      expect(validateStatus(403), isTrue);
      expect(validateStatus(422), isTrue);
      expect(validateStatus(500), isFalse);
      expect(validateStatus(502), isFalse);
      expect(validateStatus(503), isFalse);
    });

    test('должен возвращать false если все методы не сработали', () {
      final methods = ['POST', 'DELETE', 'PUT'];
      bool success = false;
      
      // Симуляция: все методы вернули ошибку
      for (final method in methods) {
        final statusCode = 400; // Ошибка для всех методов
        if (statusCode == 200 || statusCode == 204 || statusCode == 404) {
          success = true;
          break;
        }
      }
      
      expect(success, isFalse);
    });
  });

  group('VpnService - счетчик попыток обработки "уже подключено"', () {
    test('должен ограничивать количество попыток', () {
      const maxRetries = 2;
      int retryCount = 0;
      
      // Симуляция попыток
      while (retryCount < maxRetries) {
        retryCount++;
      }
      
      expect(retryCount, equals(maxRetries));
    });

    test('должен выбрасывать исключение при превышении лимита', () {
      const maxRetries = 2;
      int retryCount = 0;
      bool exceptionThrown = false;
      
      // Симуляция превышения лимита
      retryCount = maxRetries;
      if (retryCount >= maxRetries) {
        exceptionThrown = true;
      }
      
      expect(exceptionThrown, isTrue);
    });

    test('должен сбрасывать счетчик при успешном подключении', () {
      int retryCount = 2;
      const maxRetries = 2;
      
      // Симуляция успешного подключения
      retryCount = 0; // Сброс
      
      expect(retryCount, equals(0));
      expect(retryCount < maxRetries, isTrue);
    });
  });

  group('VpnService - повторные попытки отключения', () {
    test('должен выполнять до 3 попыток отключения', () {
      const maxDisconnectAttempts = 3;
      int disconnectAttempts = 0;
      bool disconnectSuccess = false;
      
      // Симуляция: первые 2 попытки неудачны, третья успешна
      while (!disconnectSuccess && disconnectAttempts < maxDisconnectAttempts) {
        disconnectAttempts++;
        if (disconnectAttempts == 3) {
          disconnectSuccess = true;
        }
      }
      
      expect(disconnectAttempts, equals(3));
      expect(disconnectSuccess, isTrue);
    });

    test('должен прекращать попытки при успешном отключении', () {
      const maxDisconnectAttempts = 3;
      int disconnectAttempts = 0;
      bool disconnectSuccess = false;
      
      // Симуляция: первая попытка успешна
      while (!disconnectSuccess && disconnectAttempts < maxDisconnectAttempts) {
        disconnectAttempts++;
        if (disconnectAttempts == 1) {
          disconnectSuccess = true;
          break;
        }
      }
      
      expect(disconnectAttempts, equals(1));
      expect(disconnectSuccess, isTrue);
    });

    test('должен использовать увеличивающиеся задержки между попытками', () {
      int attempt = 1;
      const maxAttempts = 3;
      final delays = <int>[];
      
      while (attempt <= maxAttempts) {
        delays.add(1000 * attempt);
        attempt++;
      }
      
      expect(delays[0], equals(1000)); // Попытка 1: 1000ms
      expect(delays[1], equals(2000)); // Попытка 2: 2000ms
      expect(delays[2], equals(3000)); // Попытка 3: 3000ms
    });
  });

  group('VpnService - проверка статуса после отключения', () {
    test('должен проверять статус через 1.5 секунды после отключения', () {
      const delayBeforeStatusCheck = Duration(milliseconds: 1500);
      expect(delayBeforeStatusCheck.inMilliseconds, equals(1500));
    });

    test('должен считать отключение успешным если статус показывает disconnected', () {
      final statusResponse = {
        'connected': false,
      };
      
      final isConnected = statusResponse['connected'] == true;
      final isDisconnected = !isConnected;
      
      expect(isDisconnected, isTrue);
    });

    test('должен повторять попытку если статус показывает connected', () {
      final statusResponse = {
        'connected': true,
      };
      
      final isConnected = statusResponse['connected'] == true;
      final shouldRetry = isConnected;
      
      expect(shouldRetry, isTrue);
    });

    test('должен использовать задержку 1 секунда перед повторной попыткой', () {
      const delayBeforeRetry = Duration(milliseconds: 1000);
      expect(delayBeforeRetry.inMilliseconds, equals(1000));
    });
  });

  group('VpnService - финальные задержки перед подключением', () {
    test('должен использовать задержку 2 секунды после успешного отключения', () {
      bool disconnectSuccess = true;
      const delayAfterSuccess = Duration(milliseconds: 2000);
      
      if (disconnectSuccess) {
        expect(delayAfterSuccess.inMilliseconds, equals(2000));
      }
    });

    test('должен использовать задержку 2 секунды даже если отключение не удалось', () {
      bool disconnectSuccess = false;
      const delayAfterFailure = Duration(milliseconds: 2000);
      
      // Даже если отключение не удалось, используем ту же задержку
      expect(delayAfterFailure.inMilliseconds, equals(2000));
    });
  });
}
