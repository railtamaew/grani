import 'package:flutter_test/flutter_test.dart';

/// Тесты для логики определения initialRoute в main.dart
/// 
/// Тестирует логику выбора начального экрана на основе статуса пользователя
/// 
/// ВАЖНО: Эти тесты проверяют логику определения маршрута, а не сам AuthService
void main() {
  group('Определение initialRoute на основе статуса пользователя', () {
    /// Симулирует логику _getTargetRoute из main.dart (актуально: /main, /trial-ended)
    String getTargetRoute({
      required bool hasActiveSubscription,
      int? trialSecondsLeft,
    }) {
      if (hasActiveSubscription) return '/main';
      final trialLeft = trialSecondsLeft ?? 0;
      if (trialLeft > 0) return '/main';
      return '/trial-ended';
    }

    test('должен возвращать /main для пользователя с активной подпиской', () {
      const hasActiveSubscription = true;
      const trialSecondsLeft = null;
      final route = getTargetRoute(
        hasActiveSubscription: hasActiveSubscription,
        trialSecondsLeft: trialSecondsLeft,
      );
      expect(route, equals('/main'));
    });

    test('должен возвращать /main для пользователя с активным trial', () {
      const hasActiveSubscription = false;
      const trialSecondsLeft = 600;
      final route = getTargetRoute(
        hasActiveSubscription: hasActiveSubscription,
        trialSecondsLeft: trialSecondsLeft,
      );
      expect(route, equals('/main'));
    });

    test('должен возвращать /trial-ended для пользователя без trial и подписки', () {
      // Arrange
      const hasActiveSubscription = false;
      const trialSecondsLeft = 0;
      
      // Act
      final route = getTargetRoute(
        hasActiveSubscription: hasActiveSubscription,
        trialSecondsLeft: trialSecondsLeft,
      );
      
      // Assert
      expect(route, equals('/trial-ended'));
    });

    test('должен возвращать /trial-ended для пользователя с null trialSecondsLeft', () {
      // Arrange
      const hasActiveSubscription = false;
      const trialSecondsLeft = null;
      
      // Act
      final route = getTargetRoute(
        hasActiveSubscription: hasActiveSubscription,
        trialSecondsLeft: trialSecondsLeft,
      );
      
      // Assert
      expect(route, equals('/trial-ended'));
    });

    test('должен приоритизировать подписку над trial', () {
      // Arrange - у пользователя есть и подписка, и активный trial
      const hasActiveSubscription = true;
      const trialSecondsLeft = 600; // 10 минут
      
      // Act
      final route = getTargetRoute(
        hasActiveSubscription: hasActiveSubscription,
        trialSecondsLeft: trialSecondsLeft,
      );
      
      expect(route, equals('/main'));
    });

    test('должен обрабатывать граничное значение trialSecondsLeft = 0', () {
      // Arrange
      const hasActiveSubscription = false;
      const trialSecondsLeft = 0; // Ровно 0 секунд
      
      // Act
      final route = getTargetRoute(
        hasActiveSubscription: hasActiveSubscription,
        trialSecondsLeft: trialSecondsLeft,
      );
      
      // Assert - 0 секунд означает, что trial закончился
      expect(route, equals('/trial-ended'));
    });

    test('должен обрабатывать граничное значение trialSecondsLeft = 1', () {
      // Arrange
      const hasActiveSubscription = false;
      const trialSecondsLeft = 1; // Осталась 1 секунда
      
      // Act
      final route = getTargetRoute(
        hasActiveSubscription: hasActiveSubscription,
        trialSecondsLeft: trialSecondsLeft,
      );
      
      // Assert - даже 1 секунда означает активный trial
      expect(route, equals('/main'));
    });

    test('должен обрабатывать большое значение trialSecondsLeft', () {
      // Arrange
      const hasActiveSubscription = false;
      const trialSecondsLeft = 86400; // 24 часа
      
      // Act
      final route = getTargetRoute(
        hasActiveSubscription: hasActiveSubscription,
        trialSecondsLeft: trialSecondsLeft,
      );
      
      expect(route, equals('/main'));
    });
  });

  group('Определение initialRoute для неавторизованного пользователя', () {
    test('должен возвращать / для неавторизованного пользователя', () {
      // Arrange - пользователь не авторизован
      const isAuthenticated = false;
      const hasActiveSubscription = false;
      const trialSecondsLeft = null;
      
      // Act - симулируем логику из main.dart (по кэшу: /main или /trial-ended)
      String initialRoute;
      if (isAuthenticated) {
        if (hasActiveSubscription) {
          initialRoute = '/main';
        } else {
          final trialLeft = trialSecondsLeft ?? 0;
          initialRoute = trialLeft > 0 ? '/main' : '/trial-ended';
        }
      } else {
        initialRoute = '/';
      }
      
      // Assert
      expect(initialRoute, equals('/'));
    });

    test('должен возвращать / если token равен null', () {
      // Arrange
      const isAuthenticated = true; // Но token = null
      const token = null;
      
      // Act
      String initialRoute;
      if (isAuthenticated && token != null) {
        initialRoute = '/main';
      } else {
        initialRoute = '/';
      }
      
      // Assert
      expect(initialRoute, equals('/'));
    });
  });
}
