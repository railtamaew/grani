import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/cache/cache_service.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_api.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_controller.dart';
import 'package:mobile_app/simple_vpn/server_latency_catalog.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_server_preferences.dart';
import 'package:mobile_app/simple_vpn/vpn_network_notice.dart';
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
  var runtimeDiagnosticsClosing = false;
  var runtimeDiagnosticsStatus = '';
  var runtimeDiagnosticsProtocol = 'vless_ws';

  setUp(() async {
    await SimpleVpnServerPreferences.waitForPendingWrites();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CacheService().initialize(await SharedPreferences.getInstance());
    await CacheService().clear();
    api = _FakeSimpleVpnApi();
    runtime = _FakeSimpleVpnRuntime();
    registerCalls = 0;
    runtimeDiagnosticsShowActive = false;
    runtimeDiagnosticsClosing = false;
    runtimeDiagnosticsStatus = '';
    runtimeDiagnosticsProtocol = 'vless_ws';
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
            'runtime_status': runtimeDiagnosticsStatus,
            'runtime_session_id': 'session-1',
            'runtime_protocol': runtimeDiagnosticsProtocol,
            'grani_likely_active': runtimeDiagnosticsShowActive,
            'native_active_or_closing': runtimeDiagnosticsClosing,
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

  Future<void> useRankedController(
      {ServerLatencyCatalog? catalog, bool restore = true}) async {
    controller.dispose();
    controller = SimpleVpnController(
      api: api,
      runtime: runtime,
      latencyCatalog: catalog ?? _rankedLatency(api),
      deviceIdProvider: () async => 'device-1',
      subscribeNativeState: false,
      requireVerifiedDataPlane: true,
      nativeStartResultVerifiesDataPlane: true,
    );
    if (restore) await controller.restoreInitialNativeState();
  }

  test(
      'fresh preparation selects fastest, warms it first, and home connects from its cache',
      () async {
    api.includeSecondServer = true;
    final catalog = _rankedLatency(api);
    await useRankedController(catalog: catalog, restore: false);
    api.configFetchGate = Completer<void>();
    final preparation = controller.prewarmAvailableConfigsForPostAuth();
    await _waitUntil(() => api.fetchConfigRequests.length == 3);
    expect(controller.selectedServer?.id, 102);
    expect(
        api.fetchConfigRequests.map((r) => r['server_id']), everyElement(102));
    expect(runtime.startCalls, isEmpty);
    api.configFetchGate!.complete();
    await preparation;
    expect(api.fetchConfigRequests, hasLength(6));
    expect(controller.lastSuccessfulServerId, isNull);
    await useRankedController(catalog: catalog);
    await controller.loadOptions();
    await controller.refreshServerLatencies();
    expect(controller.selectedServer?.id, 102);
    await controller.connect(source: 'post_auth_home');
    expect(runtime.startCalls.single.config.server?.id, 102);
    expect(api.fetchConfigCalls, 6);
    expect(controller.lastSuccessfulServerId, 102);
  });

  test('retired node rejection is not retried and refreshes the catalog',
      () async {
    await useRankedController();
    await controller.loadOptions();
    controller.selectServer(api.server);
    api.catalogOverride = [api.secondServer];
    api.startSessionError = const SimpleVpnServerUnavailableException();
    await controller.connect();
    await _waitUntil(() =>
        controller.state == SimpleVpnState.error &&
        controller.selectedServer?.id == api.secondServer.id);
    expect(api.startSessionCalls, hasLength(1));
    expect(controller.isConnected, isFalse);
    expect(controller.error, contains('недоступен'));
    expect(api.fetchServersCalls, greaterThanOrEqualTo(2));
  });

  test(
      'manual disconnect keeps its reason when native idle arrives before teardown completes',
      () async {
    await useRankedController();
    await controller.loadOptions();
    await controller.connect();
    await _waitUntil(() => controller.sessionId == 'session-1');
    runtime.disconnectCompleter = Completer<bool>();
    final pending = controller.disconnect(reason: 'user');
    await _waitUntil(() => controller.state == SimpleVpnState.disconnecting);
    runtimeDiagnosticsStatus = 'off';
    await controller.syncNativeUiState(
        source: 'native_event_idle_confirmation');
    final stateDuringTeardown = controller.state;
    runtime.disconnectCompleter!.complete(true);
    await pending;
    expect(stateDuringTeardown, SimpleVpnState.disconnecting);
    expect(api.stopSessionCalls, hasLength(1));
    expect(api.stopSessionCalls.single['reason'], 'user');
    expect(api.stopSessionCalls.single['device_id'], 'device-1');
    expect(api.logs.where((log) => log.event == 'vpn_unexpected_disconnect'),
        isEmpty);
    expect(controller.state, SimpleVpnState.disconnected);
  });

  for (final legacyConnected in <bool>[false, true]) {
    test(
        'cancelled unverified tunnel cannot flash connected while closing (legacy=$legacyConnected)',
        () async {
      await useRankedController();
      runtime.startCompleter = Completer<bool>();
      runtime.disconnectCompleter = Completer<bool>();
      final pendingConnect = controller.connect(source: 'offline_test');
      await _waitUntil(() => runtime.startCalls.isNotEmpty);
      runtimeDiagnosticsStatus = 'local_up';
      await controller.syncNativeUiState(source: 'offline_local_up');
      expect(controller.state, SimpleVpnState.connecting);

      await controller.cancelConnect(source: 'offline_test_cancel');
      await _waitUntil(() => runtime.disconnectCalls.isNotEmpty);
      final states = <SimpleVpnState>[];
      void recordState() => states.add(controller.state);
      controller.addListener(recordState);
      runtimeDiagnosticsStatus = 'disconnecting';
      runtimeDiagnosticsClosing = true;
      runtime.nativeConnected = legacyConnected;
      await controller.syncNativeUiState(
          source: 'timer_during_native_teardown');
      final stateDuringTeardown = controller.state;
      controller.removeListener(recordState);

      runtimeDiagnosticsStatus = 'off';
      runtimeDiagnosticsClosing = false;
      runtime.disconnectCompleter!.complete(true);
      runtime.startCompleter!.complete(false);
      await pendingConnect;

      expect(stateDuringTeardown, SimpleVpnState.disconnected);
      expect(states, isNot(contains(SimpleVpnState.connected)));
      expect(controller.lastSuccessfulServerId, isNull);
    });
  }

  test('cold connect uses ranked server even when preparation was skipped',
      () async {
    api.includeSecondServer = true;
    await useRankedController();
    await controller.connect(source: 'cold_first_connect');
    expect(runtime.startCalls.single.config.server?.id, 102);
    expect(controller.lastSuccessfulServerId, 102);
  });

  test('successful slower node stays first after reconnecting the controller',
      () async {
    api.includeSecondServer = true;
    await useRankedController();
    await controller.loadOptions();
    await controller.refreshServerLatencies();
    controller.selectServer(api.server);
    await controller.connect();
    expect(controller.lastSuccessfulServerId, 101);
    await controller.disconnect();
    await useRankedController();
    await controller.loadOptions();
    await controller.refreshServerLatencies();
    expect(controller.servers.map((s) => s.id), [101, 102]);
    expect(controller.selectedServer?.id, 101);
    expect(controller.serverLatencyMs(101), 200);
    expect(controller.serverLatencyMs(102), 40);
  });

  test(
      'manual selection does not replace last success until a verified connection',
      () async {
    api.includeSecondServer = true;
    await useRankedController();
    await controller.connect();
    expect(controller.lastSuccessfulServerId, 102);
    await controller.disconnect();
    controller.selectServer(api.server);
    await controller.refreshServerLatencies();
    expect(controller.selectedServer?.id, 101);
    expect(controller.servers.first.id, 102);
    runtime.startResult = false;
    await controller.connect();
    expect(controller.state, SimpleVpnState.error);
    expect(controller.lastSuccessfulServerId, 102);
    runtime.startResult = true;
    await controller.connect();
    expect(controller.lastSuccessfulServerId, 101);
    expect(controller.servers.first.id, 101);
  });

  test(
      'manual choice during pending latency probe wins over automatic selection',
      () async {
    api.includeSecondServer = true;
    final gate = Completer<void>();
    await useRankedController(catalog: _rankedLatency(api, gate: gate.future));
    await controller.loadOptions();
    controller.selectServer(api.server);
    gate.complete();
    await controller.refreshServerLatencies();
    expect(controller.selectedServer?.id, 101);
    expect(controller.servers.first.id, 102);
    expect(controller.lastSuccessfulServerId, isNull);
  });

  test('success and selection are isolated between accounts', () async {
    api.includeSecondServer = true;
    await CacheService().setString('user_id', 'account-a');
    await useRankedController();
    await controller.loadOptions();
    controller.selectServer(api.server);
    await controller.connect();
    await controller.disconnect();
    await SimpleVpnServerPreferences.waitForPendingWrites();
    await CacheService().setString('user_id', 'account-b');
    await useRankedController();
    await controller.loadOptions();
    await controller.refreshServerLatencies();
    expect(controller.lastSuccessfulServerId, isNull);
    expect(controller.selectedServer?.id, 102);
    await SimpleVpnServerPreferences.waitForPendingWrites();
    await CacheService().setString('user_id', 'account-a');
    await useRankedController();
    await controller.loadOptions();
    await controller.refreshServerLatencies();
    expect(controller.lastSuccessfulServerId, 101);
    expect(controller.servers.first.id, 101);
    expect(controller.selectedServer?.id, 101);
  });

  test('retired successful node is not brought back by preference storage',
      () async {
    api.includeSecondServer = true;
    await useRankedController();
    await controller.loadOptions();
    controller.selectServer(api.server);
    await controller.connect();
    await controller.disconnect();
    api.catalogOverride = [api.secondServer];
    await controller.refreshOptionsIfStale(minInterval: Duration.zero);
    expect(controller.lastSuccessfulServerId, isNull);
    expect(controller.servers.map((s) => s.id), [102]);
    expect(controller.selectedServer?.id, 102);
  });

  test('upgrade preserves legacy selection without marking it successful',
      () async {
    api.includeSecondServer = true;
    await CacheService().setString('simple_vpn_selected_server_id_v1', '101');
    await useRankedController();
    await controller.prewarmAvailableConfigsForPostAuth();
    expect(controller.selectedServer?.id, 101);
    expect(controller.servers.first.id, 102);
    expect(controller.lastSuccessfulServerId, isNull);
    expect(api.fetchConfigRequests.take(3).map((r) => r['server_id']),
        everyElement(101));
  });

  test('latency ranking changes list order without changing manual selection',
      () async {
    controller.dispose();
    api.includeSecondServer = true;
    final catalog = ServerLatencyCatalog(invoke: (method, args) async {
      if (method == 'getServerLatencyNetwork')
        return {'available': true, 'network_id': 'test-wifi'};
      return {
        'completed': true,
        'network_id': 'test-wifi',
        'results': [
          {
            'id': 101,
            'host': api.server.latencyProbeHost,
            'port': 8080,
            'successes': 3,
            'latency_ms': 200
          },
          {
            'id': 102,
            'host': api.secondServer.latencyProbeHost,
            'port': 8080,
            'successes': 3,
            'latency_ms': 40
          },
        ]
      };
    });
    controller = SimpleVpnController(
        api: api, runtime: runtime, latencyCatalog: catalog);
    await controller.restoreInitialNativeState();
    await controller.loadOptions();
    controller.selectServer(api.server);
    controller.selectProtocol(
        controller.protocols.firstWhere((p) => p.id == 'graniwg'));
    await controller.refreshServerLatencies();
    expect(controller.servers.map((s) => s.id), [102, 101]);
    expect(controller.selectedServer?.id, 101);
    expect(controller.selectedProtocol.id, 'graniwg');
    expect(runtime.startCalls, isEmpty);
    expect(runtime.disconnectCalls, isEmpty);
  });

  test('cold catalog respects saved protocol when options cache is absent',
      () async {
    await CacheService()
        .setString('simple_vpn_selected_protocol_id_v1', 'graniwg');
    await controller.restoreInitialNativeState();
    await controller.loadOptions();
    expect(controller.selectedProtocol.id, 'graniwg');
  });

  test('refresh replaces retired locations without restarting the controller',
      () async {
    await controller.restoreInitialNativeState();
    await controller.loadOptions();
    api.catalogOverride = [api.secondServer];
    await controller.refreshOptionsIfStale(minInterval: Duration.zero);
    expect(controller.servers.map((s) => s.id), [102]);
    expect(controller.selectedServer?.id, 102);
    expect(runtime.startCalls, isEmpty);
  });

  test('selector refresh is bounded and keeps a choice made during the request',
      () async {
    await controller.restoreInitialNativeState();
    await controller.loadOptions();
    await controller.refreshOptionsIfStale();
    expect(api.fetchServersCalls, 1);
    api.catalogGate = Completer<List<SimpleVpnServer>>();
    final pending =
        controller.refreshOptionsIfStale(minInterval: Duration.zero);
    await _waitUntil(() => api.fetchServersCalls == 2);
    await controller.refreshOptionsIfStale(minInterval: Duration.zero);
    controller.selectProtocol(
        controller.protocols.firstWhere((p) => p.id == 'graniwg'));
    api.catalogGate!.complete([api.server, api.secondServer]);
    await pending;
    expect(api.fetchServersCalls, 2);
    expect(controller.selectedProtocol.id, 'graniwg');
  });

  test('unavailable refresh keeps the existing catalog and manual selection',
      () async {
    await controller.restoreInitialNativeState();
    await controller.loadOptions();
    controller.selectProtocol(
        controller.protocols.firstWhere((p) => p.id == 'graniwg'));
    api.catalogGate = Completer<List<SimpleVpnServer>>();
    final pending =
        controller.refreshOptionsIfStale(minInterval: Duration.zero);
    await _waitUntil(() => api.fetchServersCalls == 2);
    api.catalogGate!.completeError(StateError('network unavailable'));
    await pending;
    expect(controller.servers.map((s) => s.id), [101]);
    expect(controller.selectedProtocol.id, 'graniwg');
    expect(controller.optionsLoading, isFalse);
  });

  test('refresh does not touch a working tunnel or its selected server',
      () async {
    await controller.connect(source: 'home_button');
    final calls = api.fetchServersCalls;
    api.catalogOverride = [api.secondServer];
    await controller.refreshOptionsIfStale(minInterval: Duration.zero);
    expect(api.fetchServersCalls, calls);
    expect(controller.selectedServer?.id, 101);
    expect(controller.isConnected, isTrue);
    expect(runtime.disconnectCalls, isEmpty);
  });

  Future<void> useAvailabilityController(Future<bool?> Function() check) async {
    controller.dispose();
    controller = SimpleVpnController(
      api: api,
      runtime: runtime,
      deviceIdProvider: () async => 'device-1',
      ensureDeviceRegistered: () async {},
      subscribeNativeState: false,
      requireVerifiedDataPlane: true,
      nativeStartResultVerifiesDataPlane: true,
      networkAvailabilityCheck: check,
      networkAbsenceConfirmationDelay: Duration.zero,
    );
  }

  test(
      'confirmed physical network absence ends attempt without starting a tunnel',
      () async {
    var checks = 0;
    var available = false;
    await useAvailabilityController(() async {
      checks++;
      return available;
    });
    final states = <SimpleVpnState>[];
    controller.addListener(() => states.add(controller.state));
    await controller.connect();
    expect(checks, 2);
    expect(controller.state, SimpleVpnState.error);
    expect(controller.isBusy, isFalse);
    expect(controller.networkNotice, VpnNetworkNotice.noNetwork);
    expect(controller.connectionProgressText, isNull);
    expect(runtime.startCalls, isEmpty);
    expect(runtime.disconnectCalls, isEmpty);
    expect(api.fetchConfigCalls, 0);
    expect(states, isNot(contains(SimpleVpnState.connected)));
    expect(states, isNot(contains(SimpleVpnState.disconnecting)));
    await controller.syncNativeUiState();
    expect(controller.networkNotice, VpnNetworkNotice.noNetwork);
    expect(controller.state, SimpleVpnState.error);

    available = true;
    await controller.connect(source: 'retry');
    expect(checks, 3);
    expect(controller.state, SimpleVpnState.connected);
    expect(controller.networkNotice, isNull);
    expect(runtime.startCalls, hasLength(1));
  });

  for (final second in <bool?>[true, null]) {
    test(
        'physical network absence requires two known negatives (second=$second)',
        () async {
      final samples = <bool?>[false, second];
      await useAvailabilityController(() async => samples.removeAt(0));
      await controller.connect();
      expect(samples, isEmpty);
      expect(controller.state, SimpleVpnState.connected);
      expect(controller.networkNotice, isNull);
    });
  }

  test('unavailable physical network diagnostics do not block VPN', () async {
    await useAvailabilityController(
        () async => throw StateError('missing channel'));
    await controller.connect();
    expect(controller.state, SimpleVpnState.connected);
    expect(runtime.startCalls, hasLength(1));
  });

  test(
      'network recovery of a working tunnel is not aborted by new-attempt check',
      () async {
    var checks = 0;
    await useAvailabilityController(() async => ++checks == 1);
    await controller.connect();
    runtimeDiagnosticsStatus = 'local_up';
    await controller.syncNativeUiState();
    expect(controller.state, SimpleVpnState.connecting);
    expect(checks, 1);
    expect(runtime.disconnectCalls, isEmpty);
    runtimeDiagnosticsStatus = 'verified';
    await controller.syncNativeUiState();
    expect(controller.state, SimpleVpnState.connected);
    expect(checks, 1);
  });

  test('cancelling during network check cannot later start a tunnel', () async {
    final gate = Completer<bool?>();
    await useAvailabilityController(() => gate.future);
    final connecting = controller.connect();
    await _waitUntil(() => controller.state == SimpleVpnState.connecting);
    await controller.cancelConnect();
    gate.complete(true);
    await connecting;
    expect(controller.state, SimpleVpnState.disconnected);
    expect(runtime.startCalls, isEmpty);
    expect(controller.networkNotice, isNull);
  });

  test(
      'verified network notice does not change the tunnel and clears on success',
      () async {
    controller.dispose();
    var probes = 0;
    runtime.startCompleter = Completer<bool>();
    controller = SimpleVpnController(
      api: api,
      runtime: runtime,
      deviceIdProvider: () async => 'device-1',
      ensureDeviceRegistered: () async {},
      networkNoticeDelay: Duration.zero,
      networkNoticeProbe: () async {
        probes++;
        return {
          'check_completed': true,
          'network_id': 'cell-9',
          'network_available': true,
          'probe_attempts': 2,
          'probe_successes': 0
        };
      },
    );
    final connecting = controller.connect();
    await _waitUntil(() => runtime.startCalls.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 3200));
    expect(controller.networkNotice, VpnNetworkNotice.internetUnconfirmed);
    expect(probes, 2);
    expect(runtime.startCalls, hasLength(1));
    expect(runtime.disconnectCalls, isEmpty);
    expect(controller.selectedProtocol.id, 'vless_ws');
    runtime.startCompleter!.complete(true);
    await connecting;
    expect(controller.state, SimpleVpnState.connected);
    expect(controller.networkNotice, isNull);
    await controller.disconnect();
  });

  test('forwards current probe evidence without changing tunnel or selection',
      () async {
    await controller.connect(source: 'home_button');
    await _waitUntil(() => controller.sessionId == 'session-1');
    final runtimeSid = runtime.startCalls.single.sessionId;
    final protocol = controller.selectedProtocol.id;
    controller.handleNativeStateForTesting(<String, dynamic>{
      'emit_type': 'connectivity_probe',
      'runtime_session_id': 'stale-runtime',
      'public_ok': true,
    });
    expect(api.logs.where((e) => e.event == 'connectivity_probe'), isEmpty);
    controller.handleNativeStateForTesting(<String, dynamic>{
      'emit_type': 'connectivity_probe',
      'runtime_session_id': runtimeSid,
      'public_ok': true,
      'public_rtt_ms': 125,
      'public_probe_route': 'local_tunnel_proxy',
      'public_vpn_proof': true,
      'underlying_network_type': 'wifi',
      'api_ok': false,
    });
    final probe = api.logs.singleWhere((e) => e.event == 'connectivity_probe');
    expect(probe.details['public_probe_route'], 'local_tunnel_proxy');
    expect(probe.details['public_rtt_ms'], 125);
    expect(probe.details['runtime_session_id'], runtimeSid);
    expect(probe.deviceId, 'device-1');
    expect(controller.selectedProtocol.id, protocol);
    expect(controller.state, SimpleVpnState.connected);
    expect(runtime.disconnectCalls, isEmpty);
    await controller.disconnect();
    controller.handleNativeStateForTesting(<String, dynamic>{
      'emit_type': 'connectivity_probe',
      'runtime_session_id': runtimeSid,
      'public_ok': false,
    });
    expect(
        api.logs.where((e) => e.event == 'connectivity_probe'), hasLength(1));
    expect(controller.state, SimpleVpnState.disconnected);
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
      'runtime_session_id': runtime.startCalls.single.sessionId,
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

  test('terminal usage retains latest counters after first traffic proof',
      () async {
    await controller.connect(source: 'home_button');
    await _waitUntil(() => controller.sessionId == 'session-1');
    final runtimeSid = runtime.startCalls.single.sessionId;
    for (final value in [1024, 1048576]) {
      controller.handleNativeStateForTesting(<String, dynamic>{
        'emit_type': 'traffic',
        'runtime_session_id': runtimeSid,
        'rx_bytes': value,
        'tx_bytes': value ~/ 2,
      });
    }
    controller.handleNativeStateForTesting(<String, dynamic>{
      'emit_type': 'traffic',
      'runtime_session_id': 'stale-runtime',
      'rx_bytes': 99999999,
      'tx_bytes': 99999999,
    });
    await controller.disconnect();
    final terminal = api.logs.lastWhere((e) => e.event == 'disconnect_ok');
    expect(terminal.details['rx_bytes'], 1048576);
    expect(terminal.details['tx_bytes'], 524288);
    expect(api.logs.where((e) => e.event == 'vpn_data_verified'), hasLength(1));
  });

  test(
    'rejects a backend config for a different selected server',
    () async {
      api.configServerOverride = SimpleVpnServer(
        id: 202,
        name: 'Unexpected fallback',
        country: 'Sweden',
        city: 'Stockholm',
        countryCode: 'SE',
        cityCode: 'stockholm',
        ipAddress: '203.0.113.202',
        wireguardPort: 39060,
        currentUsers: 0,
        maxUsers: 100,
      );

      await controller.connect(source: 'home_button');

      expect(controller.state, SimpleVpnState.error);
      expect(controller.selectedServer?.id, 101);
      expect(runtime.startCalls, isEmpty);
      expect(
        api.logs.where((item) => item.event == 'connect_failed'),
        isNotEmpty,
      );
    },
  );

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
      expect(controller.lastSuccessfulServerId, isNull);

      controller.handleNativeStateForTesting(<String, dynamic>{
        'emit_type': 'state',
        'service_state': 'committed',
        'connected': true,
        'runtime_session_id': runtimeSessionId,
      });
      await connectFuture;

      expect(controller.state, SimpleVpnState.connected);
      expect(controller.isConnected, isTrue);
      expect(controller.lastSuccessfulServerId, 101);
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
    'late verified event from cancelled runtime session cannot reconnect UI',
    () async {
      runtime.startCompleter = Completer<bool>();

      final connectFuture = controller.connect(source: 'home_button');
      await _waitUntil(() => runtime.startCalls.isNotEmpty);
      final cancelledRuntimeSession = runtime.startCalls.single.sessionId!;

      await controller.cancelConnect(source: 'home_button');
      runtime.startCompleter!.complete(true);
      await connectFuture;

      controller.handleNativeStateForTesting(<String, dynamic>{
        'emit_type': 'state',
        'service_state': 'dataplane_verified',
        'connected': true,
        'runtime_session_id': cancelledRuntimeSession,
      });
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, SimpleVpnState.disconnected);
      expect(controller.sessionId, isNull);
    },
  );

  test(
    'verified tunnel becomes reconnecting on local-up downgrade and recovers',
    () async {
      await controller.connect(source: 'home_button');
      final runtimeSessionId = runtime.startCalls.single.sessionId!;

      controller.handleNativeStateForTesting(<String, dynamic>{
        'emit_type': 'state',
        'service_state': 'local_up',
        'connected': true,
        'runtime_session_id': runtimeSessionId,
      });

      expect(controller.state, SimpleVpnState.connecting);
      expect(controller.connectionProgressText, contains('Восстанавливаем'));

      controller.handleNativeStateForTesting(<String, dynamic>{
        'emit_type': 'state',
        'service_state': 'dataplane_verified',
        'connected': true,
        'runtime_session_id': runtimeSessionId,
      });
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, SimpleVpnState.connected);
      expect(controller.connectionProgressText, isNull);
      expect(runtime.startCalls, hasLength(1));
    },
  );

  test(
    'structured native polling demotes stale verified UI and restores it only after fresh proof',
    () async {
      await controller.connect(source: 'home_button');
      runtimeDiagnosticsStatus = 'local_up';

      await controller.syncNativeUiState(source: 'home_foreground_timer');

      expect(controller.state, SimpleVpnState.connecting);
      expect(controller.connectionProgressText, contains('Восстанавливаем'));

      runtimeDiagnosticsStatus = 'verified';
      await controller.syncNativeUiState(source: 'home_foreground_timer');

      expect(controller.state, SimpleVpnState.connected);
      expect(controller.connectionProgressText, isNull);
      expect(runtime.startCalls, hasLength(1));
    },
  );

  test(
    'tap immediately after polling detects local-up performs a clean disconnect',
    () async {
      await controller.connect(source: 'home_button');
      runtimeDiagnosticsStatus = 'local_up';

      await controller.toggle(source: 'home_button');

      expect(controller.state, SimpleVpnState.disconnected);
      expect(
        runtime.disconnectCalls.map((call) => call.reason),
        contains('user_during_recovery'),
      );
    },
  );

  test(
    'tap during dataplane recovery disconnects instead of cancelling connect',
    () async {
      await controller.connect(source: 'home_button');
      final runtimeSessionId = runtime.startCalls.single.sessionId!;

      controller.handleNativeStateForTesting(<String, dynamic>{
        'emit_type': 'state',
        'service_state': 'local_up',
        'connected': true,
        'runtime_session_id': runtimeSessionId,
      });
      expect(controller.state, SimpleVpnState.connecting);

      await controller.toggle(source: 'home_button');

      expect(controller.state, SimpleVpnState.disconnected);
      expect(
        runtime.disconnectCalls.map((call) => call.reason),
        contains('user_during_recovery'),
      );
      expect(
        runtime.disconnectCalls.map((call) => call.reason),
        isNot(contains('connect_cancelled')),
      );
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
    'initial restore adopts the protocol owned by the native AWG runtime',
    () async {
      runtimeDiagnosticsShowActive = true;
      runtimeDiagnosticsStatus = 'verified';
      runtimeDiagnosticsProtocol = 'graniwg';

      await controller.restoreInitialNativeState(source: 'home_initial');

      expect(controller.state, SimpleVpnState.connected);
      expect(controller.selectedProtocol.id, 'graniwg');
      expect(runtime.startCalls, isEmpty);
    },
  );

  for (final status in ['idle', 'off', 'disconnected', 'error', '']) {
    test('stopped Hysteria polling ($status) preserves selected AWG', () async {
      await controller.restoreInitialNativeState();
      await controller.loadOptions();
      controller.selectProtocol(
        controller.protocols.firstWhere((p) => p.id == 'graniwg'),
      );
      expect(controller.selectedProtocol.id, 'graniwg');
      runtimeDiagnosticsStatus = status;
      runtimeDiagnosticsProtocol = 'hysteria2';

      for (var tick = 0; tick < 3; tick++) {
        await controller.syncNativeUiState(source: 'home_foreground_timer');
        expect(controller.selectedProtocol.id, 'graniwg');
      }
      await controller.loadOptions();
      expect(controller.selectedProtocol.id, 'graniwg');
      expect(controller.state, SimpleVpnState.disconnected);
    });
  }

  for (final status in ['idle', 'off', 'disconnected', 'error']) {
    test('stopped Hysteria event ($status) preserves selected AWG', () async {
      await controller.restoreInitialNativeState();
      await controller.loadOptions();
      controller.selectProtocol(
        controller.protocols.firstWhere((p) => p.id == 'graniwg'),
      );
      expect(controller.selectedProtocol.id, 'graniwg');
      controller.handleNativeStateForTesting(<String, dynamic>{
        'emit_type': 'state',
        'service_state': status,
        'runtime_protocol': 'hysteria2',
        'connected': false,
      });
      await Future<void>.delayed(Duration.zero);
      await controller.loadOptions();
      expect(controller.selectedProtocol.id, 'graniwg');
    });
  }

  test('manual selection clears previous native owner before options reload',
      () async {
    await controller.restoreInitialNativeState();
    await controller.loadOptions();
    controller.handleNativeStateForTesting(<String, dynamic>{
      'emit_type': 'state',
      'service_state': 'disconnecting',
      'runtime_protocol': 'hysteria2',
    });
    expect(controller.selectedProtocol.id, 'hysteria2');
    controller.selectProtocol(
      controller.protocols.firstWhere((p) => p.id == 'graniwg'),
    );
    await controller.loadOptions();
    expect(controller.selectedProtocol.id, 'graniwg');
  });

  test('stale session event cannot replace current native protocol', () async {
    await controller.connect(source: 'home_button');
    controller.handleNativeStateForTesting(<String, dynamic>{
      'emit_type': 'state',
      'service_state': 'committed',
      'runtime_protocol': 'hysteria2',
      'runtime_session_id': 'stale-session',
      'connected': true,
    });
    expect(controller.selectedProtocol.id, 'vless_ws');
    expect(controller.state, SimpleVpnState.connected);
  });

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
    api.includeSecondServer = true;
    await controller.loadOptions();

    await controller.prewarmAvailableConfigsForPostAuth();
    await Future<void>.delayed(Duration.zero);

    expect(api.fetchConfigCalls, 6);
    final hysteriaRequests = api.fetchConfigRequests.where(
      (item) => item['protocol'] == 'hysteria2',
    );
    expect(
      hysteriaRequests.every(
        (item) =>
            item['client_capabilities'] ==
            SimpleVpnApi.hysteriaNoObfsCapability,
      ),
      isTrue,
    );
    final awgRequests = api.fetchConfigRequests.where(
      (item) => item['protocol'] == 'graniwg',
    );
    expect(
      awgRequests.every(
        (item) => item['client_capabilities'] == SimpleVpnApi.awg31Capability,
      ),
      isTrue,
    );
    expect(runtime.startCalls, isEmpty);
    expect(api.startSessionCalls, isEmpty);
    expect(
      api.fetchConfigRequests
          .map((item) => '${item['server_id']}:${item['protocol']}')
          .toSet(),
      <String>{
        '101:vless_ws',
        '101:hysteria2',
        '101:graniwg',
        '102:vless_ws',
        '102:hysteria2',
        '102:graniwg',
      },
    );
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

ServerLatencyCatalog _rankedLatency(_FakeSimpleVpnApi api,
        {Future<void>? gate}) =>
    ServerLatencyCatalog(invoke: (method, args) async {
      if (method == 'getServerLatencyNetwork') {
        return {'available': true, 'network_id': 'ranking-test'};
      }
      if (gate != null) await gate;
      return {
        'completed': true,
        'network_id': 'ranking-test',
        'results': [
          for (final server in [api.server, api.secondServer])
            {
              'id': server.id,
              'host': server.latencyProbeHost,
              'port': server.latencyProbePort,
              'successes': 3,
              'latency_ms': server.id == 101 ? 200 : 40
            },
        ]
      };
    });

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

  List<SimpleVpnServer>? catalogOverride;
  Completer<List<SimpleVpnServer>>? catalogGate;
  int fetchServersCalls = 0;
  int fetchProtocolsCalls = 0;
  int fetchConfigCalls = 0;
  final fetchConfigRequests = <Map<String, Object?>>[];
  final startSessionCalls = <Map<String, Object?>>[];
  final stopSessionCalls = <Map<String, Object?>>[];
  final verifySessionCalls = <Map<String, Object?>>[];
  final logs = <_LogCall>[];
  SimpleVpnServer? configServerOverride;
  bool includeSecondServer = false;
  Object? startSessionError;
  Completer<void>? configFetchGate;

  final server = SimpleVpnServer(
    id: 101,
    name: 'Warsaw',
    country: 'Poland',
    city: 'Warsaw',
    countryCode: 'PL',
    cityCode: 'warsaw',
    ipAddress: '81.27.101.191',
    latencyProbeHost: '81.27.101.191',
    latencyProbePort: 8080,
    wireguardPort: 39060,
    currentUsers: 0,
    maxUsers: 100,
  );

  final secondServer = SimpleVpnServer(
    id: 102,
    name: 'Stockholm',
    country: 'Sweden',
    city: 'Stockholm',
    countryCode: 'SE',
    cityCode: 'stockholm',
    ipAddress: '203.0.113.102',
    latencyProbeHost: '203.0.113.102',
    latencyProbePort: 8080,
    wireguardPort: 443,
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
    if (catalogGate != null) return catalogGate!.future;
    if (catalogOverride != null) return catalogOverride!;
    return <SimpleVpnServer>[
      server,
      if (includeSecondServer) secondServer,
    ];
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
    if (configFetchGate != null) await configFetchGate!.future;
    final requestedServer = serverId == secondServer.id ? secondServer : server;
    return SimpleVpnConfig(
      protocol: protocol ?? 'vless_ws',
      configType: 'xray',
      engine: 'xray',
      serverName: (configServerOverride ?? requestedServer).name,
      server: configServerOverride ?? requestedServer,
      configRevision: 'test-rev-1',
      config: '{"outbounds":[]}',
      jsonConfig: const <String, dynamic>{'outbounds': <dynamic>[]},
      profileVersion:
          protocol == 'graniwg' ? SimpleVpnApi.awg31ProfileVersion : 'legacy',
    );
  }

  @override
  Future<SimpleVpnStartResult> startSession({
    String? protocol,
    String? deviceId,
    int? serverId,
    String? runtimeSessionId,
  }) async {
    startSessionCalls.add(<String, Object?>{
      'protocol': protocol,
      'device_id': deviceId,
      'server_id': serverId,
      'runtime_session_id': runtimeSessionId,
    });
    if (startSessionError != null) throw startSessionError!;
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
  Completer<bool>? disconnectCompleter;
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
    return disconnectCompleter == null
        ? true
        : await disconnectCompleter!.future;
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
