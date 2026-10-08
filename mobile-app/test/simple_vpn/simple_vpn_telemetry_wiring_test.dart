import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_app/core/api/endpoint_router.dart';
import 'package:mobile_app/core/vpn/control_plane_plane_resolver.dart';
import 'package:mobile_app/core/vpn/network_policy_engine.dart';
import 'package:mobile_app/core/vpn/vpn_orchestration_runtime.dart';
import 'package:mobile_app/core/vpn/vpn_orchestration_spec.dart';
import 'package:mobile_app/core/vpn_state_machine.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_api.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_telemetry.dart';

import '../support/fake_api_client.dart';

class RecordingClient extends FakeApiClient {
  final requests = <Map<String, dynamic>>[];
  bool acknowledge = true;

  @override
  Future<Response> post(String path, {
    dynamic data, Map<String, dynamic>? queryParameters, Options? options,
    CancelToken? cancelToken, RequestKind? requestKind,
    BootstrapWave? bootstrapWave,
  }) async {
    requests.add({'path': path, 'data': data, 'kind': requestKind});
    return Response(requestOptions: RequestOptions(path: path), statusCode: 200,
      data: {'success': true, 'receipts': acknowledge
        ? (data['events'] as List).map((e) => {
            'event_id': e['event_id'], 'status': 'stored'}).toList()
        : []});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RecordingClient client;
  late SimpleVpnApi api;

  Future<List<dynamic>> pending() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(SimpleVpnTelemetry.storageKey);
    return raw == null ? [] : (jsonDecode(raw) as Map)['events'] as List;
  }

  setUp(() {
    SimpleVpnApi.resetTelemetryForTesting();
    SharedPreferences.setMockInitialValues({'user_id': '998'});
    VpnOrchestrationRuntime.instance.setVpnState(VpnConnectionState.disconnected);
    client = RecordingClient();
    api = SimpleVpnApi(apiClient: client);
  });
  tearDown(() => SimpleVpnApi.resetTelemetryForTesting());

  test('real API log persists pre-device intent and removes only durable receipt', () async {
    await api.log(event: 'connect_intent', sessionId: 'intent-qa',
      details: {'intent_id': 'intent-qa', 'protocol': 'vless_ws'});
    final entries = await pending();
    expect(entries, hasLength(1));
    expect(entries.single['owner_id'], 998);
    expect(entries.single['device_id'], isNull);
    expect(entries.single['installation_id'], isNotEmpty);
    await SimpleVpnApi.flushTelemetryForTesting();
    expect(client.requests.single['path'], '/simple-vpn/product-telemetry');
    expect(client.requests.single['kind'], RequestKind.logging);
    expect(await pending(), isEmpty);
  });

  test('real API log keeps unsaved server receipt and original account', () async {
    client.acknowledge = false;
    await api.log(event: 'connect_failed', details: {'reason_code': 'no_underlying_network'});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_id', '999');
    await SimpleVpnApi.flushTelemetryForTesting();
    expect((client.requests.single['data']['events'] as List).single['owner_id'], 998);
    expect((await pending()).single['owner_id'], 998);
  });

  test('missing account never sends diagnostics as another user', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user_id');
    await api.log(event: 'connect_intent');
    await SimpleVpnApi.flushTelemetryForTesting();
    expect(await pending(), isEmpty);
    expect(client.requests, isEmpty);
  });

  test('terminal diagnostics route is allowed disconnected but defers during connect', () {
    const path = '/simple-vpn/product-telemetry';
    final plane = ControlPlanePlaneResolver.planeForApiPath(path);
    final durable = ControlPlanePlaneResolver.isDurableDiagnosticsPath(path);
    expect(plane, ControlPlanePlane.logging);
    expect(durable, isTrue);
    expect(NetworkPolicyEngine.instance.evaluate(plane,
      connectivityDiagnosticsFlush: durable).allowed, isTrue);
    expect(ControlPlanePlaneResolver.isDurableDiagnosticsPath('/vpn/logs/send'), isFalse);
    expect(ControlPlanePlaneResolver.isDurableDiagnosticsPath('/simple-vpn/product-telemetry/other'), isFalse);
    VpnOrchestrationRuntime.instance.setVpnState(VpnConnectionState.connecting);
    expect(NetworkPolicyEngine.instance.evaluate(plane,
      connectivityDiagnosticsFlush: durable).allowed, isFalse);
  });
}
