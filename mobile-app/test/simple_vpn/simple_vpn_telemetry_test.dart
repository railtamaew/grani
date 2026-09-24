import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_telemetry.dart';
import 'package:mobile_app/core/vpn/network_policy_engine.dart';
import 'package:mobile_app/core/vpn/vpn_orchestration_runtime.dart';
import 'package:mobile_app/core/vpn/vpn_orchestration_spec.dart';
import 'package:mobile_app/core/vpn/control_plane_plane_resolver.dart';
import 'package:mobile_app/core/vpn_state_machine.dart';

void main() {
  String? stored;
  late DateTime now;
  late SimpleVpnTelemetry queue;
  late List<List<Map<String, dynamic>>> requests;
  var allowed = true;
  Future<Set<String>> Function(List<Map<String, dynamic>>)? handler;

  Map<String, dynamic> event(
          {String name = 'connect_tap', String session = 'r1'}) =>
      {
        'event': name,
        'device_id': 'device-1',
        'session_id': session,
        'details': <String, dynamic>{
          'runtime_session_id': session,
          'protocol': 'graniwg',
          'public_probe_route': 'vpn_network',
          'public_ok': true
        },
      };
  List<dynamic> pending() => (jsonDecode(stored!) as Map)['events'] as List;

  setUp(() {
    stored = null;
    now = DateTime.utc(2026, 9, 22);
    requests = [];
    allowed = true;
    handler = null;
    queue = SimpleVpnTelemetry(
      read: () async => stored,
      write: (value) async {
        stored = value;
      },
      now: () => now,
      automaticScheduling: false,
      canSend: () => allowed,
      send: (batch) async {
        requests.add(batch);
        if (handler != null) return handler!(batch);
        return batch.map((e) => e['event_id'] as String).toSet();
      },
    );
  });
  tearDown(() => queue.dispose());

  test('enqueue and VPN work never wait for a blocked HTTP request', () async {
    final blocked = Completer<Set<String>>();
    handler = (_) => blocked.future;
    await queue.enqueue(event());
    final inFlight = queue.flush();
    await Future<void>.delayed(Duration.zero);
    await queue
        .enqueue(event(name: 'disconnect_ok'))
        .timeout(const Duration(seconds: 1));
    expect(pending(), hasLength(2));
    blocked.complete({requests.single.first['event_id'] as String});
    await inFlight;
    expect(pending().single['event'], 'disconnect_ok');
  });

  test('failed or absent durable acknowledgement retains event across restart',
      () async {
    handler = (_) async => <String>{};
    await queue.enqueue(event(name: 'disconnect_ok'));
    final id = pending().single['event_id'];
    await queue.flush();
    expect(pending().single['event_id'], id);
    queue.dispose();
    handler = null;
    queue = SimpleVpnTelemetry(
        read: () async => stored,
        write: (value) async {
          stored = value;
        },
        now: () => now,
        canSend: () => true,
        automaticScheduling: false,
        send: (batch) async =>
            batch.map((e) => e['event_id'] as String).toSet());
    await queue.flush();
    expect(pending(), hasLength(1)); // Restart must respect retry deadline.
    now = now.add(const Duration(minutes: 1));
    await queue.flush();
    expect(pending(), isEmpty);
  });

  test('one bounded batch per minute, preserving nonacknowledged events',
      () async {
    for (var i = 0; i < 12; i++) {
      await queue.enqueue(event(session: 's$i'));
    }
    await queue.flush();
    expect(requests.single, hasLength(8));
    expect(pending(), hasLength(4));
    await queue.flush();
    expect(requests, hasLength(1));
    now = now.add(const Duration(minutes: 1));
    await queue.flush();
    expect(requests, hasLength(2));
    expect(pending(), isEmpty);
  });

  test('transition pauses network delivery; stopped state can deliver terminal',
      () async {
    allowed = false;
    await queue.enqueue(event(name: 'disconnect_ok'));
    await queue.flush();
    expect(requests, isEmpty);
    allowed = true;
    await queue.flush();
    expect(requests, hasLength(1));
    expect(pending(), isEmpty);
  });

  test('dense probes are sampled and secrets/URLs are not persisted', () async {
    final probe = event(name: 'connectivity_probe');
    (probe['details'] as Map<String, dynamic>).addAll({
      'password': 'secret',
      'config': 'private',
      'public_url': 'https://example.test/?token=secret',
      'public_rtt_ms': 100
    });
    for (var i = 0; i < 1000; i++) {
      await queue.enqueue(probe);
    }
    expect(pending(), hasLength(1));
    expect(stored, isNot(contains('secret')));
    expect(stored, isNot(contains('private')));
    expect(pending().single['details']['public_rtt_ms'], 100);
    now = now.add(const Duration(minutes: 1));
    await queue.enqueue(probe);
    expect(pending(), hasLength(2));
    expect(pending()[0]['event_id'], isNot(pending()[1]['event_id']));
  });

  test('bounded queue evicts probes before terminal and expires old records',
      () async {
    await queue.enqueue(event(name: 'disconnect_ok'));
    for (var i = 0; i < 70; i++) {
      await queue.enqueue(event(name: 'connectivity_probe', session: 's$i'));
    }
    expect(pending(), hasLength(64));
    expect(pending().any((e) => e['event'] == 'disconnect_ok'), isTrue);
    expect(utf8.encode(stored!).length, lessThan(256 * 1024));
    now = now.add(const Duration(hours: 25));
    await queue.flush();
    expect(requests, isEmpty);
  });

  test('unknown receipts cannot erase another pending event', () async {
    handler = (_) async => {'not-a-sent-event'};
    await queue.enqueue(event());
    await queue.flush();
    expect(pending(), hasLength(1));
  });

  test('policy denies diagnostic flush during every connect stage', () {
    expect(ControlPlanePlaneResolver.planeForApiPath('/simple-vpn/logs/batch'),
        ControlPlanePlane.logging);
    for (final state in [
      VpnConnectionState.connecting,
      VpnConnectionState.tunnelReady,
      VpnConnectionState.tunnelVerifying,
      VpnConnectionState.disconnecting
    ]) {
      VpnOrchestrationRuntime.instance.setVpnState(state);
      expect(
          NetworkPolicyEngine.instance
              .evaluate(ControlPlanePlane.logging,
                  connectivityDiagnosticsFlush: true)
              .allowed,
          isFalse);
    }
    VpnOrchestrationRuntime.instance
        .setVpnState(VpnConnectionState.disconnected);
    expect(
        NetworkPolicyEngine.instance
            .evaluate(ControlPlanePlane.logging,
                connectivityDiagnosticsFlush: true)
            .allowed,
        isTrue);
    expect(
        NetworkPolicyEngine.instance
            .evaluate(ControlPlanePlane.logging)
            .allowed,
        isFalse);
  });
}
