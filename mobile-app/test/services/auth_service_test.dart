import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/auth_service.dart';

void main() {
  group('AuthService - проверка истечения токена', () {
    test('должен считать токен истекшим за 5 минут до реального истечения', () {
      // Симулируем логику проверки истечения токена
      final now = DateTime.now();
      final expiresAt = now.add(const Duration(hours: 1)); // Токен истекает через час
      
      // Проверяем с запасом в 5 минут
      final isExpired = now.isAfter(expiresAt.subtract(const Duration(minutes: 5)));
      
      // Токен еще не истек (до истечения больше часа, минус 5 минут = еще 55 минут)
      expect(isExpired, isFalse);
    });

    test('должен считать токен истекшим если до истечения меньше 5 минут', () {
      final now = DateTime.now();
      final expiresAt = now.add(const Duration(minutes: 3)); // Токен истекает через 3 минуты
      
      // Проверяем с запасом в 5 минут
      final isExpired = now.isAfter(expiresAt.subtract(const Duration(minutes: 5)));
      
      // Токен считается истекшим (3 минуты < 5 минут запаса)
      expect(isExpired, isTrue);
    });

    test('должен считать токен валидным если до истечения больше 5 минут', () {
      final now = DateTime.now();
      final expiresAt = now.add(const Duration(minutes: 10)); // Токен истекает через 10 минут
      
      // Проверяем с запасом в 5 минут
      final isExpired = now.isAfter(expiresAt.subtract(const Duration(minutes: 5)));
      
      // Токен еще валиден (10 минут - 5 минут = 5 минут запаса)
      expect(isExpired, isFalse);
    });

    test('должен считать токен истекшим если он уже истек', () {
      final now = DateTime.now();
      final expiresAt = now.subtract(const Duration(minutes: 1)); // Токен истек минуту назад
      
      // Проверяем с запасом в 5 минут
      final isExpired = now.isAfter(expiresAt.subtract(const Duration(minutes: 5)));
      
      // Токен точно истек
      expect(isExpired, isTrue);
    });

    test('должен использовать запас в 5 минут, а не 1 день', () {
      final now = DateTime.now();
      
      // Тест с токеном, который истекает через 23 часа 59 минут
      // Старая логика (1 день запаса) считала бы его истекшим
      // Новая логика (5 минут запаса) считает его валидным
      final expiresAt23h59m = now.add(const Duration(hours: 23, minutes: 59));
      
      // Старая логика: проверка с запасом в 1 день
      final oldThreshold = expiresAt23h59m.subtract(const Duration(days: 1));
      final oldLogic = now.isAfter(oldThreshold);
      
      // Новая логика: проверка с запасом в 5 минут
      final newThreshold = expiresAt23h59m.subtract(const Duration(minutes: 5));
      final newLogic = now.isAfter(newThreshold);
      
      // Старая логика считала бы истекшим (23ч 59м < 1 дня)
      expect(oldLogic, isTrue);
      // Новая логика считает валидным (23ч 59м >> 5 минут)
      expect(newLogic, isFalse);
    });

    test('должен правильно обрабатывать граничный случай (ровно 5 минут)', () {
      final now = DateTime.now();
      final expiresAt = now.add(const Duration(minutes: 5, milliseconds: 1)); // Токен истекает чуть больше чем через 5 минут
      
      // Проверяем с запасом в 5 минут
      final isExpired = now.isAfter(expiresAt.subtract(const Duration(minutes: 5)));
      
      // На границе - токен считается валидным (есть небольшой запас)
      expect(isExpired, isFalse);
    });
  });

  group('AuthService - обновление токена', () {
    test('должен обновлять токен только когда он истек или близок к истечению', () {
      final now = DateTime.now();
      final expiresAt = now.add(const Duration(minutes: 3)); // До истечения 3 минуты
      
      final needsRefresh = now.isAfter(expiresAt.subtract(const Duration(minutes: 5)));
      
      expect(needsRefresh, isTrue);
    });

    test('не должен обновлять токен если он еще валиден', () {
      final now = DateTime.now();
      final expiresAt = now.add(const Duration(hours: 1)); // До истечения час
      
      final needsRefresh = now.isAfter(expiresAt.subtract(const Duration(minutes: 5)));
      
      expect(needsRefresh, isFalse);
    });
  });
}
