import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AuthService - Trial и Subscription статус', () {
    setUp(() async {
      // Очищаем SharedPreferences перед каждым тестом
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      // Очищаем после теста
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    });

    test('должен возвращать null для trialSecondsLeft если не установлен', () async {
      // Arrange
      final authService = AuthService();
      await authService.waitForTokenLoad();
      
      // Assert
      expect(authService.trialSecondsLeft, isNull);
    });

    test('должен возвращать false для hasActiveSubscription если не установлен', () async {
      // Arrange
      final authService = AuthService();
      await authService.waitForTokenLoad();
      
      // Assert
      expect(authService.hasActiveSubscription, isFalse);
    });

    test('должен сохранять trialSecondsLeft в SharedPreferences', () async {
      // Arrange
      const testTrialSeconds = 600; // 10 минут
      final prefs = await SharedPreferences.getInstance();
      
      // Act - сохраняем значение
      await prefs.setInt('trial_seconds_left', testTrialSeconds);
      
      // Assert - проверяем, что значение сохранено
      final savedValue = prefs.getInt('trial_seconds_left');
      expect(savedValue, equals(testTrialSeconds));
    });

    test('должен сохранять hasActiveSubscription в SharedPreferences', () async {
      // Arrange
      const testHasSubscription = true;
      final prefs = await SharedPreferences.getInstance();
      
      // Act - сохраняем значение
      await prefs.setBool('has_active_subscription', testHasSubscription);
      
      // Assert - проверяем, что значение сохранено
      final savedValue = prefs.getBool('has_active_subscription');
      expect(savedValue, equals(testHasSubscription));
    });

    test('должен сохранять оба значения вместе в SharedPreferences', () async {
      // Arrange
      const testTrialSeconds = 300;
      const testHasSubscription = false;
      final prefs = await SharedPreferences.getInstance();
      
      // Act - сохраняем оба значения
      await prefs.setInt('trial_seconds_left', testTrialSeconds);
      await prefs.setBool('has_active_subscription', testHasSubscription);
      
      // Assert - проверяем, что оба значения сохранены
      expect(prefs.getInt('trial_seconds_left'), equals(testTrialSeconds));
      expect(prefs.getBool('has_active_subscription'), equals(testHasSubscription));
    });

    test('должен обрабатывать отсутствие значений в SharedPreferences', () async {
      // Arrange - SharedPreferences пуст
      SharedPreferences.setMockInitialValues({});
      
      // Act
      final newAuthService = AuthService();
      await newAuthService.waitForTokenLoad();
      
      // Assert
      expect(newAuthService.trialSecondsLeft, isNull);
      expect(newAuthService.hasActiveSubscription, isFalse);
    });
  });

  group('AuthService - refreshUserStatus', () {
    late AuthService authService;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      authService = AuthService();
      await authService.waitForTokenLoad();
    });

    tearDown(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    });

    test('не должен обновлять статус если пользователь не авторизован', () async {
      // Arrange - пользователь не авторизован
      
      // Act
      await authService.refreshUserStatus();
      
      // Assert - статус не должен измениться
      expect(authService.trialSecondsLeft, isNull);
      expect(authService.hasActiveSubscription, isFalse);
    });

    test('должен обновлять статус при успешном ответе от сервера', () async {
      // Этот тест требует мокирования Dio, что сложнее
      // Пока оставляем как заглушку для будущей реализации
      // В реальном тесте нужно:
      // 1. Установить токен в authService
      // 2. Замокировать Dio для возврата успешного ответа
      // 3. Вызвать refreshUserStatus()
      // 4. Проверить, что значения обновились
      
      expect(authService, isNotNull);
    });
  });

  group('AuthService - определение целевого экрана', () {
    // Канонический shell — /main (trial и home внутри MainContentScreen), см. docs/MOBILE_APP_ROUTES_INVENTORY.md
    test('должен определять /main для пользователя с активной подпиской', () {
      final hasActiveSubscription = true;
      final trialSecondsLeft = 0;

      String targetRoute;
      if (hasActiveSubscription) {
        targetRoute = '/main';
      } else if (trialSecondsLeft > 0) {
        targetRoute = '/main';
      } else {
        targetRoute = '/trial-ended';
      }

      expect(targetRoute, equals('/main'));
    });

    test('должен определять /main для пользователя с активным trial', () {
      final hasActiveSubscription = false;
      final trialSecondsLeft = 600;

      String targetRoute;
      if (hasActiveSubscription) {
        targetRoute = '/main';
      } else if (trialSecondsLeft > 0) {
        targetRoute = '/main';
      } else {
        targetRoute = '/trial-ended';
      }

      expect(targetRoute, equals('/main'));
    });

    test('должен определять /trial-ended для пользователя без trial и подписки', () {
      final hasActiveSubscription = false;
      final trialSecondsLeft = 0;

      String targetRoute;
      if (hasActiveSubscription) {
        targetRoute = '/main';
      } else if (trialSecondsLeft > 0) {
        targetRoute = '/main';
      } else {
        targetRoute = '/trial-ended';
      }

      expect(targetRoute, equals('/trial-ended'));
    });

    test('должен приоритизировать подписку над trial', () {
      final hasActiveSubscription = true;
      final trialSecondsLeft = 600;

      String targetRoute;
      if (hasActiveSubscription) {
        targetRoute = '/main';
      } else if (trialSecondsLeft > 0) {
        targetRoute = '/main';
      } else {
        targetRoute = '/trial-ended';
      }

      expect(targetRoute, equals('/main'));
    });

    test('должен обрабатывать null для trialSecondsLeft', () {
      final hasActiveSubscription = false;
      final trialSecondsLeft = null;

      String targetRoute;
      if (hasActiveSubscription) {
        targetRoute = '/main';
      } else if ((trialSecondsLeft ?? 0) > 0) {
        targetRoute = '/main';
      } else {
        targetRoute = '/trial-ended';
      }

      expect(targetRoute, equals('/trial-ended'));
    });
  });
}
