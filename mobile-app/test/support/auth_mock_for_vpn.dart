import 'package:mocktail/mocktail.dart';
import 'package:mobile_app/services/auth_service.dart';

/// Мок [AuthService] для юнит-тестов [VpnService] без GetIt.
class MockAuthForVpn extends Mock implements AuthService {}

void stubVpnAuthDefaults(MockAuthForVpn mock, {String? token}) {
  when(() => mock.token).thenReturn(token);
  when(() => mock.waitForTokenLoad()).thenAnswer((_) async {});
  when(() => mock.waitForBootstrapForVpnConnect(maxWait: const Duration(seconds: 6)))
      .thenAnswer((_) async {});
  when(() => mock.hasPendingDeviceLimit).thenReturn(false);
  when(() => mock.ensureNetworkReady()).thenAnswer((_) async {});
}
