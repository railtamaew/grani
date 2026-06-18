import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('AuthService - error message parsing', () {
    test('returns detail string from map', () {
      final result = AuthService.extractErrorMessageForTest({
        'detail': 'Ошибка сервера',
      });
      expect(result, 'Ошибка сервера');
    });

    test('returns error.message from nested map', () {
      final result = AuthService.extractErrorMessageForTest({
        'error': {'message': 'Доступ запрещен'},
      });
      expect(result, 'Доступ запрещен');
    });

    test('returns message from map when detail missing', () {
      final result = AuthService.extractErrorMessageForTest({
        'message': 'Неверный формат',
      });
      expect(result, 'Неверный формат');
    });

    test('returns generic message for non-empty string', () {
      final result = AuthService.extractErrorMessageForTest('<html>502</html>');
      expect(result, 'Ошибка сервера. Повторите позже.');
    });

    test('returns null for empty data', () {
      expect(AuthService.extractErrorMessageForTest(null), isNull);
    });
  });
}
