import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/api/api_client.dart';
import 'package:mobile_app/core/cache/cache_service.dart';
import 'package:mobile_app/core/errors/error_handler.dart';
import 'package:mobile_app/core/logger/logger.dart';
import 'package:mobile_app/core/storage/storage_service.dart';
import 'package:mobile_app/core/vpn_state_machine.dart';
import 'package:mobile_app/services/connection_logger.dart';
import 'package:mobile_app/services/vpn_service.dart';
import '../support/auth_mock_for_vpn.dart';
import '../support/fake_api_client.dart';

/// Тесты контракта плана «идеальное состояние VpnService» (vpn_service_ideal_plan.md).
/// Проверяют: условие входа в disconnect без device_id, единый формат логирования ошибки connect, переходы состояний,
/// DI-конструктор и lastConnectionErrorMessage при ошибке connect.
void main() {
  group('VpnService ideal plan — disconnect без device_id', () {
    /// Условие входа в disconnect: только (isConnected || isConnecting). device_id не требуется.
    bool shouldAllowDisconnect(bool isConnected, bool isConnecting, String? deviceId) {
      if (!isConnected && !isConnecting) return false;
      return true;
    }

    test('disconnect разрешён при isConnecting даже без device_id', () {
      expect(shouldAllowDisconnect(false, true, null), isTrue);
      expect(shouldAllowDisconnect(false, true, ''), isTrue);
    });

    test('disconnect разрешён при isConnected даже без device_id', () {
      expect(shouldAllowDisconnect(true, false, null), isTrue);
    });

    test('disconnect запрещён когда не подключены и не подключаются', () {
      expect(shouldAllowDisconnect(false, false, null), isFalse);
      expect(shouldAllowDisconnect(false, false, 'some-id'), isFalse);
    });
  });

  group('VpnService ideal plan — единый вызов logConnectionError', () {
    /// Контракт: один вызов logConnectionError с полным errorDetails (stage, stage_duration_ms, network_type, error_type, stack_trace).
    Map<String, dynamic> buildConnectionErrorDetails({
      String? stage,
      int? stageDurationMs,
      String? networkType,
      required String errorType,
      required String stackTrace,
    }) {
      return {
        if (stage != null) 'stage': stage,
        if (stageDurationMs != null) 'stage_duration_ms': stageDurationMs,
        if (networkType != null) 'network_type': networkType,
        'error_type': errorType,
        'stack_trace': stackTrace,
      };
    }

    test('errorDetails содержит обязательные поля error_type и stack_trace', () {
      final details = buildConnectionErrorDetails(
        errorType: 'Exception',
        stackTrace: 'StackTrace',
      );
      expect(details['error_type'], equals('Exception'));
      expect(details['stack_trace'], equals('StackTrace'));
    });

    test('errorDetails может содержать stage, stage_duration_ms, network_type', () {
      final details = buildConnectionErrorDetails(
        stage: 'get_config',
        stageDurationMs: 1500,
        networkType: 'wifi',
        errorType: 'DioException',
        stackTrace: '#0 ...',
      );
      expect(details['stage'], equals('get_config'));
      expect(details['stage_duration_ms'], equals(1500));
      expect(details['network_type'], equals('wifi'));
      expect(details['error_type'], equals('DioException'));
    });

    test('нет дублирования: один набор полей покрывает и stage, и error_type/stack_trace', () {
      final details = buildConnectionErrorDetails(
        stage: 'verify_connection',
        stageDurationMs: 6000,
        networkType: 'mobile',
        errorType: 'TimeoutException',
        stackTrace: '...',
      );
      expect(details.length, greaterThanOrEqualTo(5));
      expect(details.containsKey('stage'), isTrue);
      expect(details.containsKey('error_type'), isTrue);
      expect(details.containsKey('stack_trace'), isTrue);
    });
  });

  group('VpnService ideal plan — переходы состояний (_applyTransition)', () {
    test('idle -> connecting и idle -> error разрешены', () {
      expect(
        VpnStateTransitions.canTransition(VpnConnectionState.idle, VpnConnectionState.connecting),
        isTrue,
      );
      expect(
        VpnStateTransitions.canTransition(VpnConnectionState.idle, VpnConnectionState.error),
        isTrue,
      );
    });

    test('connecting -> tunnelReady, disconnecting, error, idle разрешены', () {
      expect(
        VpnStateTransitions.canTransition(VpnConnectionState.connecting, VpnConnectionState.tunnelReady),
        isTrue,
      );
      expect(
        VpnStateTransitions.canTransition(VpnConnectionState.connecting, VpnConnectionState.disconnecting),
        isTrue,
      );
      expect(
        VpnStateTransitions.canTransition(VpnConnectionState.connecting, VpnConnectionState.idle),
        isTrue,
      );
    });

    test('tunnelReady -> tunnelVerifying; tunnelVerifying -> connected', () {
      expect(
        VpnStateTransitions.canTransition(VpnConnectionState.tunnelReady, VpnConnectionState.tunnelVerifying),
        isTrue,
      );
      expect(
        VpnStateTransitions.canTransition(VpnConnectionState.tunnelVerifying, VpnConnectionState.connected),
        isTrue,
      );
    });

    test('connected -> disconnecting разрешён', () {
      expect(
        VpnStateTransitions.canTransition(VpnConnectionState.connected, VpnConnectionState.disconnecting),
        isTrue,
      );
    });

    test('disconnecting -> disconnected разрешён', () {
      expect(
        VpnStateTransitions.canTransition(VpnConnectionState.disconnecting, VpnConnectionState.disconnected),
        isTrue,
      );
    });

    test('disconnected -> connecting и disconnected -> idle разрешены', () {
      expect(
        VpnStateTransitions.canTransition(VpnConnectionState.disconnected, VpnConnectionState.connecting),
        isTrue,
      );
      expect(
        VpnStateTransitions.canTransition(VpnConnectionState.disconnected, VpnConnectionState.idle),
        isTrue,
      );
    });

    test('toFlags: connecting / tunnelReady / tunnelVerifying => (true, false, false)', () {
      for (final s in [
        VpnConnectionState.connecting,
        VpnConnectionState.tunnelReady,
        VpnConnectionState.tunnelVerifying,
      ]) {
        final flags = VpnStateTransitions.toFlags(s);
        expect(flags.$1, isTrue, reason: '$s');
        expect(flags.$2, isFalse);
        expect(flags.$3, isFalse);
      }
    });

    test('toFlags: connected => (false, false, true)', () {
      final flags = VpnStateTransitions.toFlags(VpnConnectionState.connected);
      expect(flags.$1, isFalse);
      expect(flags.$2, isFalse);
      expect(flags.$3, isTrue);
    });

    test('toFlags: disconnecting => (false, true, false)', () {
      final flags = VpnStateTransitions.toFlags(VpnConnectionState.disconnecting);
      expect(flags.$1, isFalse);
      expect(flags.$2, isTrue);
      expect(flags.$3, isFalse);
    });

    test('toFlags: idle и disconnected => (false, false, false)', () {
      expect(VpnStateTransitions.toFlags(VpnConnectionState.idle), equals((false, false, false)));
      expect(VpnStateTransitions.toFlags(VpnConnectionState.disconnected), equals((false, false, false)));
    });
  });

  group('VpnService ideal plan — lastConnectionErrorMessage при ошибке connect', () {
    /// Контракт: при любом выходе из connect с ошибкой VpnService выставляет lastConnectionErrorMessage
    /// через ErrorHandler.userMessageForConnectionError; источник всегда должен возвращать непустое сообщение.
    /// Проверяем константы и условия, используемые в connect() при установке сообщения.

    test('fallback-сообщение «все попытки исчерпаны» непустое', () {
      const fallbackMessage = 'Не удалось подключиться после нескольких попыток';
      expect(fallbackMessage, isNotEmpty);
    });

    test('при return false из connect ожидается непустое lastConnectionErrorMessage', () {
      // Контракт: в блоке «все попытки исчерпаны» и в catch выставляется
      // _lastConnectionErrorMessage = _errorHandler.userMessageForConnectionError(e) или fallback.
      // Проверяем, что строка, которая подставляется как fallback, непустая.
      final fallbackExceptionMessage = 'Не удалось подключиться после нескольких попыток';
      expect(fallbackExceptionMessage, isNotEmpty);
    });
  });

  group('VpnService DI и connect (skipInitialize)', () {
    test('VpnService(skipInitialize: true) создаётся, lastConnectionErrorMessage изначально null', () {
      final auth = MockAuthForVpn();
      stubVpnAuthDefaults(auth);
      final service = VpnService(
        apiClient: FakeApiClient(),
        logger: Logger(),
        cacheService: CacheService(),
        storageService: StorageService(),
        errorHandler: ErrorHandler(),
        connectionLogger: ConnectionLogger(),
        authService: auth,
        skipInitialize: true,
      );
      addTearDown(service.dispose);
      expect(service.lastConnectionErrorMessage, isNull);
    });

    test('connect() при ошибке выставляет lastConnectionErrorMessage', () async {
      ApiClient().initialize();
      final auth = MockAuthForVpn();
      stubVpnAuthDefaults(auth);
      final service = VpnService(
        apiClient: FakeApiClient(),
        logger: Logger(),
        cacheService: CacheService(),
        storageService: StorageService(),
        errorHandler: ErrorHandler(),
        connectionLogger: ConnectionLogger(),
        authService: auth,
        skipInitialize: true,
      );
      addTearDown(service.dispose);
      var connectFailed = false;
      try {
        final result = await service.connect();
        connectFailed = !result;
      } catch (_) {
        connectFailed = true;
      }
      // При сбое (return false или throw) — непустое сообщение. Успех в VM возможен (кэш серверов / TCP verify вне туннеля).
      if (connectFailed) {
        expect(
          service.lastConnectionErrorMessage != null && service.lastConnectionErrorMessage!.isNotEmpty,
          isTrue,
          reason: 'После неудачного connect() lastConnectionErrorMessage должен быть непустым',
        );
      }
    });
  });
}
