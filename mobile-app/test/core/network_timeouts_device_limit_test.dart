import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/api/network_timeouts.dart';

const _connectivityChannel =
    MethodChannel('dev.fluttercommunity.plus/connectivity');

/// Таймауты экрана «лимит устройств» и согласованность с read-heavy VPN API.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_connectivityChannel, null);
  });

  Future<void> setMockConnectivity(List<String> results) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_connectivityChannel, (call) async {
      if (call.method == 'check') {
        return results;
      }
      return null;
    });
  }

  group('NetworkTimeouts.deviceLimitWallOperationTimeout', () {
    test('на Wi‑Fi wall 28 с', () async {
      await setMockConnectivity([ConnectivityResult.wifi.name]);
      final wall = await NetworkTimeouts.deviceLimitWallOperationTimeout();
      expect(wall, const Duration(seconds: 28));
    });

    test('на мобильной сети wall 35 с', () async {
      await setMockConnectivity([ConnectivityResult.mobile.name]);
      final wall = await NetworkTimeouts.deviceLimitWallOperationTimeout();
      expect(wall, const Duration(seconds: 35));
    });
  });

  group('согласованность с vpnApiReadHeavy', () {
    test('wall не короче receive read-heavy + запас (Wi‑Fi)', () async {
      await setMockConnectivity([ConnectivityResult.wifi.name]);
      final wall = await NetworkTimeouts.deviceLimitWallOperationTimeout();
      final heavy = await NetworkTimeouts.vpnApiReadHeavy();
      expect(wall.inMilliseconds,
          greaterThanOrEqualTo(heavy.receive.inMilliseconds + 8000));
    });

    test('wall не короче receive read-heavy + запас (mobile)', () async {
      await setMockConnectivity([ConnectivityResult.mobile.name]);
      final wall = await NetworkTimeouts.deviceLimitWallOperationTimeout();
      final heavy = await NetworkTimeouts.vpnApiReadHeavy();
      expect(wall.inMilliseconds,
          greaterThanOrEqualTo(heavy.receive.inMilliseconds + 8000));
    });
  });

  group('медленная операция укладывается в wall (без реальной задержки сети)', () {
    test('короткий Future не получает TimeoutException под wall Wi‑Fi', () async {
      await setMockConnectivity([ConnectivityResult.wifi.name]);
      final wall = await NetworkTimeouts.deviceLimitWallOperationTimeout();
      final result = await Future<int>.delayed(
        const Duration(milliseconds: 20),
        () => 42,
      ).timeout(wall);
      expect(result, 42);
    });

    test('короткий Future не получает TimeoutException под wall mobile', () async {
      await setMockConnectivity([ConnectivityResult.mobile.name]);
      final wall = await NetworkTimeouts.deviceLimitWallOperationTimeout();
      final result = await Future<int>.delayed(
        const Duration(milliseconds: 50),
        () => 7,
      ).timeout(wall);
      expect(result, 7);
    });

    test('тот же паттерн .timeout(wall) обрывает операцию дольше лимита', () async {
      // Не используем реальные 28 с — проверяем только семантику, как на экране лимита.
      const wall = Duration(milliseconds: 40);
      await expectLater(
        Future<void>.delayed(const Duration(milliseconds: 120)).timeout(wall),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
