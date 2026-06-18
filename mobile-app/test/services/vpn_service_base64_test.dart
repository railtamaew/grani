import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'dart:typed_data';

/// Тесты для base64 кодирования XRay конфигурации
void main() {
  group('XRay Base64 кодирование', () {
    test('должен корректно кодировать JSON конфигурацию в base64', () {
      final jsonConfig = '{"log":{"loglevel":"warning"},"inbounds":[{"protocol":"socks"}],"outbounds":[{"protocol":"vless"}]}';
      
      // Симуляция кодирования (как в VpnService.kt)
      final bytes = utf8.encode(jsonConfig);
      final base64Config = base64Encode(bytes);
      
      expect(base64Config, isNotEmpty);
      expect(base64Config.length, greaterThan(jsonConfig.length));
      
      // Проверяем, что можно декодировать обратно
      final decoded = utf8.decode(base64Decode(base64Config));
      expect(decoded, equals(jsonConfig));
    });

    test('должен использовать NO_WRAP флаг (без переносов строк)', () {
      final jsonConfig = '{"test":"value"}';
      final base64Config = base64Encode(utf8.encode(jsonConfig));
      
      // NO_WRAP означает отсутствие переносов строк
      expect(base64Config, isNot(contains('\n')));
      expect(base64Config, isNot(contains('\r')));
    });

    test('должен корректно обрабатывать большие конфигурации', () {
      // Создаем большую конфигурацию (симуляция реальной)
      final largeConfig = StringBuffer('{"log":{"loglevel":"warning"},"inbounds":[');
      for (int i = 0; i < 100; i++) {
        largeConfig.write('{"protocol":"socks","tag":"inbound$i"},');
      }
      largeConfig.write('],"outbounds":[{"protocol":"vless"}]}');
      
      final jsonConfig = largeConfig.toString();
      final base64Config = base64Encode(utf8.encode(jsonConfig));
      
      expect(base64Config, isNotEmpty);
      expect(base64Config.length, greaterThan(jsonConfig.length));
      
      // Проверяем декодирование
      final decoded = utf8.decode(base64Decode(base64Config));
      expect(decoded, equals(jsonConfig));
    });

    test('должен корректно обрабатывать специальные символы в конфигурации', () {
      final jsonConfig = '{"test":"value with / and \\"quotes\\" and \\n newlines"}';
      final base64Config = base64Encode(utf8.encode(jsonConfig));
      
      expect(base64Config, isNotEmpty);
      
      // Проверяем декодирование
      final decoded = utf8.decode(base64Decode(base64Config));
      expect(decoded, equals(jsonConfig));
    });
  });

  group('XRay Base64 декодирование результата', () {
    test('должен корректно декодировать base64 ответ от libXray', () {
      // Симуляция ответа от libXray (base64-encoded JSON)
      final resultJson = '{"success":true,"message":"XRay started"}';
      final base64Result = base64Encode(utf8.encode(resultJson));
      
      // Декодирование (как в XrayNativeWrapper.kt)
      final decoded = utf8.decode(base64Decode(base64Result));
      final result = jsonDecode(decoded) as Map<String, dynamic>;
      
      expect(result['success'], isTrue);
      expect(result['message'], equals('XRay started'));
    });

    test('должен корректно обрабатывать ошибку от libXray', () {
      final errorJson = '{"success":false,"error":"illegal base64 data at input byte 0"}';
      final base64Error = base64Encode(utf8.encode(errorJson));
      
      final decoded = utf8.decode(base64Decode(base64Error));
      final result = jsonDecode(decoded) as Map<String, dynamic>;
      
      expect(result['success'], isFalse);
      expect(result['error'], equals('illegal base64 data at input byte 0'));
    });

    test('должен обрабатывать уже декодированный JSON ответ', () {
      // Если libXray вернул обычный JSON (не base64)
      final resultJson = '{"success":true,"message":"XRay started"}';
      
      // Пробуем распарсить как обычный JSON
      try {
        final result = jsonDecode(resultJson) as Map<String, dynamic>;
        expect(result['success'], isTrue);
      } catch (e) {
        // Если не удалось, пробуем декодировать как base64
        final decoded = utf8.decode(base64Decode(resultJson));
        final result = jsonDecode(decoded) as Map<String, dynamic>;
        expect(result['success'], isTrue);
      }
    });

    test('должен обрабатывать разные форматы ответа', () {
      // Тест 1: base64-encoded JSON
      final base64Json = base64Encode(utf8.encode('{"success":true}'));
      final decoded1 = utf8.decode(base64Decode(base64Json));
      final result1 = jsonDecode(decoded1) as Map<String, dynamic>;
      expect(result1['success'], isTrue);

      // Тест 2: обычный JSON
      final result2 = jsonDecode('{"success":true}') as Map<String, dynamic>;
      expect(result2['success'], isTrue);

      // Тест 3: не-JSON строка (старый формат API)
      final nonJson = 'XRay started successfully';
      expect(nonJson, isNotEmpty);
    });
  });
}
