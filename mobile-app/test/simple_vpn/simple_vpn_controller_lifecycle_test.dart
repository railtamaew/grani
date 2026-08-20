import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/cache/cache_service.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_api.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _vpnChannel = MethodChannel('com.granivpn.mobile/vpn');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binding = TestDefaultBinaryMessengerBinding.instance;
  late _FakeSimpleVpnApi api;
  late _FakeSimpleVpnRuntime runtime;
  late SimpleVpnController controller;
  var registerCalls = 0;
  var runtimeDiagnosticsShowActive = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CacheService().initialize(await SharedPreferences.getInstance());
    await CacheService().clear();
    api = _FakeSimpleVpnApi();
    runtime = _FakeSimpleVpnRuntime();
    registerCalls = 0;
    runtimeDiagnosticsShowActive = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_vpnChannel, (
      call,
    ) async {
      switch (call.method) {
        case 'getNetworkDiagnostics':
          return <String, dynamic>{
            'network_type': 'wifi',
            'underlying_network_type': 'wifi',
            'underlying_network_available': true,
            'internet_without_vpn_ok': true,
            'underlying_internet_ok': true,
            'source': 'unit_test',
          };
        case 'getRuntimeDiagnostics':
          return <String, dynamic>{
            'runtime_state': 'test',
            'runtime_session_id': 'session-1',
            'runtime_protocol': 'vless_ws',
            'grani_likely_active': runtimeDiagnosticsShowActive,
          };
      }
      return null;
    });
    controller = SimpleVpnController(
      api: api,
      runtime: runtime,
      deviceIdProvider: () async => 'device-1',
      ensureDeviceRegistered: () async {
        registerCalls++;
      },
    );
  });

  tearDown(() {
    controller.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_vpnChannel, null);
  });

  test('connect starts session runtime and moves to connected', () async {
    await controller.connect(source: 'quick_tile');
    await _waitUntil(() => controller.sessionId == 'session-1');

    expect(controller.state, SimpleVpnState.connected);
    expect(controller.isConnected, isTrue);
    expect(controller.sessionId, 'session-1');
    expect(controller.selectedServer?.id, 101);
    expect(controller.selectedProtocol.id, 'vless_ws');
    expect(registerCalls, 1);

    expect(api.fetchServersCalls, 1);
    expect(api.fetchProtocolsCalls, 1);
    expect(api.fetchConfigCalls, 1);
    expect(api.startSessionCalls.single, <String, Object?>{
      'protocol': 'vless_ws',
      'device_id': 'device-1',
      'server_id': 101,
    });
    expect(
      runtime.startCalls.single.sessionId,
      startsWith('local_runtime_vless_ws_'),
    );
    expect(runtime.startCalls.single.source, 'quick_tile');
    expect(runtime.startCalls.single.config.protocol, 'vless_ws');
    expect(runtime.disconnectCalls, isEmpty);
    expect(
      api.logs.map((item) => item.event),
      containsAll(<String>['connect_tap', 'native_start_ok']),
    );
  });

  test(
    'verified dataplane gate keeps UI connecting until native commit',
    () async {
      controller.dispose();
      controller = SimpleVpnController(
        api: api,
        runtime: runtime,
        deviceIdProvider: () async => 'device-1',
        ensureDeviceRegistered: () async {
          registerCalls++;
        },
        requireVerifiedDataPlane: true,
      );

      final connectFuture = controller.connect(source: 'home_button');
      await _waitUntil(() => runtime.startCalls.isNotEmpty);
      final runtimeSessionId = runtime.startCalls.single.sessionId!;

      controller.handleNativeStateForTesting(<String, dynamic>{
        'emit_type': 'state',
        'service_state': 'local_up',
        'connected': true,
        'runtime_session_id': runtimeSessionId,
      });
      expect(controller.state, SimpleVpnState.connecting);

      controller.handleNativeStateForTesting(<String, dynamic>{
        'emit_type': 'state',
        'service_state': 'committed',
        'connected': true,
        'runtime_session_id': runtimeSessionId,
      });
      await connectFuture;

      expect(controller.state, SimpleVpnState.connected);
      expect(controller.isConnected, isTrue);
    },
  );

  test(
    'verified native start result completes gate if state event is missed',
    () async {
      controller.dispose();
      controller = SimpleVpnController(
        api: api,
        runtime: runtime,
        deviceIdProvider: () async => 'device-1',
        ensureDeviceRegistered: () async {},
        requireVerifiedDataPlane: true,
        nativeStartResultVerifiesDataPlane: true,
      );

      await controller.connect(source: 'home_button');

      expect(controller.state, SimpleVpnState.connected);
      expect(controller.isConnected, isTrue);
      expect(runtime.startCalls, hasLength(1));
    },
  );

  test(
    'native UI polling cannot promote an in-flight connection',
    () async {
      controller.dispose();
      runtime.startCompleter = Completer<bool>();
      controller = SimpleVpnController(
        api: api,
        runtime: runtime,
        deviceIdProvider: () async => 'device-1',
        ensureDeviceRegistered: () async {},
        requireVerifiedDataPlane: true,
      );

      final connectFuture = controller.connect(source: 'home_button');
      await _waitUntil(() => runtime.startCalls.isNotEmpty);
      runtime.nativeConnected = true;

      await controller.syncNativeUiState(source: 'resume_while_connecting');

      expect(controller.state, SimpleVpnState.connecting);
      runtime.startCompleter!.complete(false);
      await connectFuture;
    },
  );

  test(
    'cached native timeout is terminal and does not start a second runtime',
    () async {
      await controller.connect(source: 'first_connect');
      await controller.disconnect(source: 'test', reason: 'prepare_retry');
      expect(api.fetchConfigCalls, 1);
      expect(runtime.startCalls, hasLength(1));

      runtime.startException = PlatformException(
        code: 'VPN_TIMEOUT',
        message: 'VPN не вышел в COMMITTED за отведенное время',
        details: const <String, dynamic>{
          'timeoutMs': 75000,
          'cleanupSucceeded': true,
        },
      );

      await controller.connect(source: 'timeout_test');

      expect(controller.state, SimpleVpnState.error);
      expect(runtime.startCalls, hasLength(2));
      expect(api.fetchConfigCalls, 1);
      expect(
        api.logs.map((item) => item.event),
        contains('connect_failed'),
      );
    },
  );

  test(
    'traffic proof waits for backend id instead of logging local runtime id',
    () async {
      controller.dispose();
      controller = SimpleVpnController(
        api: api,
        runtime: runtime,
        deviceIdProvider: () async => 'device-1',
        ensureDeviceRegistered: () async {},
        requireVerifiedDataPlane: true,
      );

      final connectFuture = controller.connect(source: 'home_button');
      await _waitUntil(() => runtime.startCalls.isNotEmpty);
      final runtimeSessionId = runtime.startCalls.single.sessionId!;
      controller.handleNativeStateForTesting(<String, dynamic>{
        'emit_type': 'traffic',
        'runtime_session_id': runtimeSessionId,
        'rx_bytes': 1024,
        'tx_bytes': 512,
      });
      expect(
        api.logs.where((item) => item.event == 'vpn_data_verified'),
        isEmpty,
      );

      controller.handleNativeStateForTesting(<String, dynamic>{
        'emit_type': 'state',
        'service_state': 'dataplane_verified',
        'connected': true,
        'runtime_session_id': runtimeSessionId,
      });
      await connectFuture;
      await _waitUntil(
        () => api.logs.any((item) => item.event == 'vpn_data_verified'),
      );
      final proofLog = api.logs.firstWhere(
        (item) => item.event == 'vpn_data_verified',
      );
      expect(proofLog.sessionId, 'session-1');
      expect(proofLog.details['runtime_session_id'], runtimeSessionId);
      expect(proofLog.details['backend_session_id'], 'session-1');
    },
  );

  test('native runtime error closes backend session only once', () async {
    await controller.connect(source: 'home_button');
    await _waitUntil(() => controller.sessionId == 'session-1');
    final runtimeSessionId = runtime.startCalls.single.sessionId!;
    final errorEvent = <String, dynamic>{
      'emit_type': 'state',
      'service_state': 'error',
      'runtime_error': 'tun2socks_exited',
      'runtime_session_id': runtimeSessionId,
    };

    controller.handleNativeStateForTesting(errorEvent);
    controller.handleNativeStateForTesting(errorEvent);
    await _waitUntil(() => api.stopSessionCalls.isNotEmpty);

    expect(controller.state, SimpleVpnState.error);
    expect(api.stopSessionCalls, hasLength(1));
    expect(api.stopSessionCalls.single['session_id'], 'session-1');
    expect(api.stopSessionCalls.single['reason'], 'native_runtime_error');
  });

  test(
    'disconnect is routed through runtime and stops the backend session',
    () async {
      await controller.connect(source: 'simple_vpn');
      final runtimeSessionId = runtime.startCalls.single.sessionId;
      await _waitUntil(() => controller.sessionId == 'session-1');

      await controller.disconnect(source: 'quick_tile', reason: 'user_tile');

      expect(controller.state, SimpleVpnState.disconnected);
      expect(controller.sessionId, isNull);
      expect(runtime.disconnectCalls.last.reason, 'user_tile');
      expect(runtime.disconnectCalls.last.source, 'quick_tile');
      expect(runtime.disconnectCalls.last.sessionId, runtimeSessionId);
      expect(runtime.disconnectCalls.last.includeLegacy, isTrue);
      expect(api.stopSessionCalls.last, <String, Object?>{
        'session_id': 'session-1',
        'reason': 'user_tile',
        'device_id': 'device-1',
      });
      expect(api.logs.map((item) => item.event), contains('disconnect_ok'));
    },
  );

  test(
    'cancelConnect immediately returns UI to disconnected and cleans tail',
    () async {
      runtime.startCompleter = Completer<bool>();

      final connectFuture = controller.connect(source: 'quick_tile');
      await _waitUntil(() => runtime.startCalls.isNotEmpty);

      expect(controller.state, SimpleVpnState.connecting);

      await controller.cancelConnect(source: 'quick_tile');

      expect(controller.state, SimpleVpnState.disconnected);
      expect(controller.sessionId, isNull);

      runtime.startCompleter!.complete(true);
      await connectFuture;
      await _waitUntil(
        () => runtime.disconnectCalls.any(
          (call) => call.reason == 'connect_cancelled',
        ),
      );
      await _waitUntil(
        () => api.logs.any((call) => call.event == 'connect_cancelled'),
      );

      expect(controller.state, SimpleVpnState.disconnected);
      expect(
        api.stopSessionCalls.where((call) => call['reason'] == 'user_cancel'),
        isEmpty,
      );
      expect(api.logs.map((item) => item.event), contains('connect_cancelled'));
    },
  );

  test(
    'syncNativeUiState adopts local native state without backend verify',
    () async {
      runtime.nativeConnected = true;

      await controller.syncNativeUiState(source: 'quick_tile_state');

      expect(controller.state, SimpleVpnState.connected);
      expect(api.verifySessionCalls, isEmpty);

      runtime.nativeConnected = false;
      await controller.syncNativeUiState(source: 'quick_tile_state');

      expect(controller.state, SimpleVpnState.disconnected);
      expect(api.verifySessionCalls, isEmpty);
    },
  );

  test(
    'initial restore adopts an existing tunnel without restarting it',
    () async {
      runtime.nativeConnected = true;

      await controller.restoreInitialNativeState(source: 'home_initial');

      expect(controller.state, SimpleVpnState.connected);
      expect(controller.isRestoringNativeState, isFalse);
      expect(runtime.startCalls, isEmpty);
      expect(runtime.disconnectCalls, isEmpty);
      expect(
        api.logs.map((item) => item.event),
        containsAll(<String>[
          'vpn_state_restore_started',
          'vpn_state_restore_completed',
        ]),
      );
    },
  );

  test(
    'tap during initial restore cannot stop or replace a live tunnel',
    () async {
      runtime.awgStatusCompleter = Completer<bool?>();

      final tapFuture = controller.toggle(source: 'home_button');
      await _waitUntil(() => runtime.awgStatusCalls > 0);

      expect(controller.isRestoringNativeState, isTrue);
      expect(runtime.startCalls, isEmpty);
      expect(runtime.disconnectCalls, isEmpty);

      runtime.nativeConnected = true;
      runtime.awgStatusCompleter!.complete(true);
      await tapFuture;

      expect(controller.state, SimpleVpnState.connected);
      expect(runtime.startCalls, isEmpty);
      expect(runtime.disconnectCalls, isEmpty);
      expect(
        api.logs.map((item) => item.event),
        contains('vpn_tap_blocked_while_restoring'),
      );
    },
  );

  test('connect adopts a tunnel that appeared after initial restore', () async {
    await controller.restoreInitialNativeState(source: 'home_initial');
    runtime.nativeConnected = true;

    await controller.connect(source: 'home_button');

    expect(controller.state, SimpleVpnState.connected);
    expect(runtime.startCalls, isEmpty);
    expect(runtime.disconnectCalls, isEmpty);
    expect(
      api.logs.map((item) => item.event),
      contains('vpn_existing_session_adopted'),
    );
  });

  test(
    'one transient negative native read does not drop connected UI',
    () async {
      runtime.nativeConnected = true;
      await controller.restoreInitialNativeState(source: 'home_initial');
      runtime.awgStatusSequence.addAll(<bool?>[false, true]);
      runtime.nativeStatusSequence.addAll(<bool?>[false, true]);

      await controller.syncNativeUiState(source: 'home_resume');

      expect(controller.state, SimpleVpnState.connected);
      expect(runtime.disconnectCalls, isEmpty);
    },
  );

  test('runtime diagnostics protect a live tunnel from false polling',
      () async {
    runtime.nativeConnected = true;
    await controller.restoreInitialNativeState(source: 'home_initial');
    runtime.nativeConnected = false;
    runtimeDiagnosticsShowActive = true;

    await controller.syncNativeUiState(source: 'home_resume');

    expect(controller.state, SimpleVpnState.connected);
    expect(runtime.disconnectCalls, isEmpty);
  });

  test('post-auth prewarm caches every protocol without starting VPN',
      () async {
    await controller.loadOptions();

    await controller.prewarmAvailableConfigsForPostAuth();
    await Future<void>.delayed(Duration.zero);

    expect(api.fetchConfigCalls, 3);
    final hysteriaRequest = api.fetchConfigRequests.singleWhere(
      (item) => item['protocol'] == 'hysteria2',
    );
    expect(
      hysteriaRequest['client_capabilities'],
      SimpleVpnApi.hysteriaNoObfsCapability,
    );
    expect(runtime.startCalls, isEmpty);
    expect(api.startSessionCalls, isEmpty);
    final warmedProtocols = api.logs
        .where((item) => item.event == 'vpn_protocol_prewarm')
        .map((item) => item.details['protocol'])
        .toSet();
    expect(
        warmedProtocols,
        containsAll(<String>{
          'vless_ws',
          'hysteria2',
          'graniwg',
        }));
  });
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out while waiting for test condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _FakeSimpleVpnApi extends SimpleVpnApi {
  _FakeSimpleVpnApi();

  int fetchServersCalls = 0;
  int fetchProtocolsCalls = 0;
  int fetchConfigCalls = 0;
  final fetchConfigRequests = <Map<String, Object?>>[];
  final startSessionCalls = <Map<String, Object?>>[];
  final stopSessionCalls = <Map<String, Object?>>[];
  final verifySessionCalls = <Map<String, Object?>>[];
  final logs = <_LogCall>[];

  final server = SimpleVpnServer(
    id: 101,
    name: 'Warsaw',
    country: 'Poland',
    city: 'Warsaw',
    countryCode: 'PL',
    cityCode: 'warsaw',
    ipAddress: '81.27.101.191',
    wireguardPort: 39060,
    currentUsers: 0,
    maxUsers: 100,
  );

  late final protocols = <SimpleVpnProtocol>[
    SimpleVpnProtocol(
      id: 'vless_ws',
      engine: 'xray',
      status: 'active',
      role: 'fallback',
    ),
    SimpleVpnProtocol(
      id: 'hysteria2',
      engine: 'hysteria2',
      status: 'active',
      role: 'fallback',
    ),
    SimpleVpnProtocol(
      id: 'graniwg',
      engine: 'amneziawg',
      status: 'active',
      role: 'primary',
    ),
  ];

  @override
  Future<List<SimpleVpnServer>> fetchServers() async {
    fetchServersCalls++;
    return <SimpleVpnServer>[server];
  }

  @override
  Future<List<SimpleVpnProtocol>> fetchProtocols() async {
    fetchProtocolsCalls++;
    return protocols;
  }

  @override
  Future<SimpleVpnConfig> fetchConfig({
    int? serverId,
    String? deviceId,
    String? protocol,
    String? clientCapabilities,
  }) async {
    fetchConfigCalls++;
    fetchConfigRequests.add(<String, Object?>{
      'server_id': serverId,
      'device_id': deviceId,
      'protocol': protocol,
      'client_capabilities': clientCapabilities,
    });
    return SimpleVpnConfig(
      protocol: protocol ?? 'vless_ws',
      configType: 'xray',
      engine: 'xray',
      serverName: server.name,
      server: server,
      configRevision: 'test-rev-1',
      config: '{"outbounds":[]}',
      jsonConfig: const <String, dynamic>{'outbounds': <dynamic>[]},
    );
  }

  @override
  Future<SimpleVpnStartResult> startSession({
    String? protocol,
    String? deviceId,
    int? serverId,
  }) async {
    startSessionCalls.add(<String, Object?>{
      'protocol': protocol,
      'device_id': deviceId,
      'server_id': serverId,
    });
    return SimpleVpnStartResult(sessionId: 'session-1', status: 'starting');
  }

  @override
  Future<SimpleVpnVerifyResult> verifySession({
    String? sessionId,
    String? deviceId,
    int? serverId,
    String? protocol,
  }) async {
    verifySessionCalls.add(<String, Object?>{
      'session_id': sessionId,
      'device_id': deviceId,
      'server_id': serverId,
      'protocol': protocol,
    });
    return SimpleVpnVerifyResult(
      verified: true,
      status: 'ok',
      serverId: serverId,
      rxBytes: 1024,
      txBytes: 2048,
    );
  }

  @override
  Future<void> stopSession({
    String? sessionId,
    String? reason,
    String? deviceId,
  }) async {
    stopSessionCalls.add(<String, Object?>{
      'session_id': sessionId,
      'reason': reason,
      'device_id': deviceId,
    });
  }

  @override
  Future<void> log({
    required String event,
    String level = 'info',
    String? sessionId,
    String? deviceId,
    Map<String, dynamic>? details,
  }) async {
    logs.add(
      _LogCall(
        event: event,
        level: level,
        sessionId: sessionId,
        deviceId: deviceId,
        details: details ?? const <String, dynamic>{},
      ),
    );
  }
}

class _FakeSimpleVpnRuntime implements SimpleVpnRuntime {
  bool permissionOk = true;
  bool startResult = true;
  bool nativeConnected = false;
  Completer<bool>? startCompleter;
  Object? startException;
  Completer<bool?>? awgStatusCompleter;
  final awgStatusSequence = <bool?>[];
  final nativeStatusSequence = <bool?>[];
  int awgStatusCalls = 0;
  int nativeStatusCalls = 0;
  final startCalls = <_StartCall>[];
  final disconnectCalls = <_DisconnectCall>[];

  @override
  Future<bool> requestPermission() async => permissionOk;

  @override
  Future<bool> startConfig(
    SimpleVpnConfig config, {
    required String? sessionId,
    required String source,
  }) async {
    startCalls.add(
      _StartCall(config: config, sessionId: sessionId, source: source),
    );
    final error = startException;
    if (error != null) throw error;
    final result =
        startCompleter == null ? startResult : await startCompleter!.future;
    nativeConnected = result;
    return result;
  }

  @override
  Future<bool?> getAmneziaWgStatus() async {
    awgStatusCalls++;
    final completer = awgStatusCompleter;
    if (completer != null) return completer.future;
    if (awgStatusSequence.isNotEmpty) return awgStatusSequence.removeAt(0);
    return nativeConnected;
  }

  @override
  Future<bool?> getNativeConnectionStatus() async {
    nativeStatusCalls++;
    if (nativeStatusSequence.isNotEmpty) {
      return nativeStatusSequence.removeAt(0);
    }
    return nativeConnected;
  }

  @override
  Future<bool> disconnect({
    required String reason,
    required String source,
    required String? sessionId,
    bool includeLegacy = false,
  }) async {
    disconnectCalls.add(
      _DisconnectCall(
        reason: reason,
        source: source,
        sessionId: sessionId,
        includeLegacy: includeLegacy,
      ),
    );
    nativeConnected = false;
    return true;
  }
}

class _StartCall {
  const _StartCall({
    required this.config,
    required this.sessionId,
    required this.source,
  });

  final SimpleVpnConfig config;
  final String? sessionId;
  final String source;
}

class _DisconnectCall {
  const _DisconnectCall({
    required this.reason,
    required this.source,
    required this.sessionId,
    required this.includeLegacy,
  });

  final String reason;
  final String source;
  final String? sessionId;
  final bool includeLegacy;
}

class _LogCall {
  const _LogCall({
    required this.event,
    required this.level,
    required this.sessionId,
    required this.deviceId,
    required this.details,
  });

  final String event;
  final String level;
  final String? sessionId;
  final String? deviceId;
  final Map<String, dynamic> details;
}
