import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_api.dart';
import 'package:mobile_app/simple_vpn/server_latency_catalog.dart';

SimpleVpnServer server(int id, {String? host}) => SimpleVpnServer(
      id: id,
      name: 'node$id',
      country: 'Test',
      city: 'Test',
      ipAddress: host ?? '198.51.100.$id',
      wireguardPort: 24444,
      currentUsers: 0,
      maxUsers: 100,
      pingMs: 1,
      latencyProbeHost: host ?? '198.51.100.$id',
      latencyProbePort: 8080,
    );

Map<String, dynamic> response(String network, List<SimpleVpnServer> servers,
        {double value = 50}) =>
    {
      'completed': true,
      'network_id': network,
      'results': servers
          .map((s) => {
                'id': s.id,
                'host': s.latencyProbeHost,
                'port': s.latencyProbePort,
                'latency_ms': value,
                'successes': 3
              })
          .toList(),
    };

void main() {
  test(
      'an early empty reading during Wi-Fi setup is retried after three seconds',
      () async {
    var now = DateTime(2026, 9, 23), calls = 0;
    final servers = [server(1)];
    final catalog = ServerLatencyCatalog(
        now: () => now,
        invoke: (method, args) async {
          if (method == 'getServerLatencyNetwork')
            return {'available': true, 'network_id': 'new-wifi'};
          calls++;
          if (calls == 1)
            return {'completed': true, 'network_id': 'new-wifi', 'results': []};
          return response('new-wifi', servers, value: 75);
        });
    Future<Map<int, double>> read() =>
        catalog.refresh(servers, onInvalidated: () {});
    expect(await read(), isEmpty);
    now = now.add(const Duration(seconds: 2));
    expect(await read(), isEmpty);
    expect(calls, 1);
    now = now.add(const Duration(seconds: 1));
    expect(await read(), {1: 75});
    expect(await read(), {1: 75});
    expect(calls, 2);
  });
  test(
      'device latency sorts ascending, unknown and invalid follow, ties stay stable',
      () {
    final servers = [
      server(1),
      server(2),
      server(3),
      server(4),
      server(5),
      server(6)
    ];
    final ordered = sortServersByLatency(
        servers, {1: 200, 2: 40, 3: 40, 4: double.nan, 5: -1});
    expect(ordered.map((s) => s.id), [2, 3, 1, 4, 5, 6]);
    expect(servers.map((s) => s.id), [1, 2, 3, 4, 5, 6]);
    // API/control-plane ping=1 is deliberately not used as phone latency.
    expect(
        sortServersByLatency(servers, {}).map((s) => s.id), [1, 2, 3, 4, 5, 6]);
  });

  test('probe endpoint survives catalog cache serialization', () {
    final value = SimpleVpnServer.fromJson(server(1).toJson());
    expect(value.latencyProbeHost, '198.51.100.1');
    expect(value.latencyProbePort, 8080);
    final old = SimpleVpnServer.fromJson({'id': 1, 'ip': '198.51.100.1'});
    expect(old.latencyProbePort, isNull);
    expect(old.latencyProbeHost, isEmpty);
  });

  test('preparation and selector share fresh readings but expiry probes again',
      () async {
    var now = DateTime(2026, 9, 23), calls = 0, invalidated = 0;
    final servers = [server(1)];
    final catalog = ServerLatencyCatalog(
        now: () => now,
        invoke: (method, args) async {
          if (method == 'getServerLatencyNetwork')
            return {'available': true, 'network_id': 'wifi-1'};
          calls++;
          return response('wifi-1', servers);
        });
    Future<Map<int, double>> read() =>
        catalog.refresh(servers, onInvalidated: () => invalidated++);
    expect(await read(), {1: 50});
    expect(await read(), {1: 50});
    expect(calls, 1);
    now = now.add(const Duration(seconds: 61));
    expect(await read(), {1: 50});
    expect(calls, 2);
    expect(invalidated, 2);
  });

  test('network and endpoint changes invalidate values even within the TTL',
      () async {
    var network = 'wifi-1', calls = 0, invalidated = 0;
    var servers = [server(1)];
    final catalog = ServerLatencyCatalog(invoke: (method, args) async {
      if (method == 'getServerLatencyNetwork')
        return {'available': true, 'network_id': network};
      calls++;
      return response(network, servers, value: calls * 100.0);
    });
    Future<Map<int, double>> read() =>
        catalog.refresh(servers, onInvalidated: () => invalidated++);
    expect(await read(), {1: 100});
    network = 'lte-2';
    expect(await read(), {1: 200});
    servers = [server(1, host: '203.0.113.17')];
    expect(await read(), {1: 300});
    expect(calls, 3);
    expect(invalidated, 3);
  });

  test(
      'concurrent refreshes coalesce and an old network cannot overwrite a newer result',
      () async {
    var network = 'wifi-1', calls = 0;
    final servers = [server(1)];
    final old = Completer<Map<String, dynamic>>();
    final catalog = ServerLatencyCatalog(invoke: (method, args) async {
      if (method == 'getServerLatencyNetwork')
        return {'available': true, 'network_id': network};
      calls++;
      if (args!['network_id'] == 'wifi-1') return old.future;
      return response('lte-2', servers, value: 90);
    });
    final a = catalog.refresh(servers, onInvalidated: () {});
    await Future<void>.delayed(Duration.zero);
    final same = catalog.refresh(servers, onInvalidated: () {});
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    network = 'lte-2';
    expect(await catalog.refresh(servers, onInvalidated: () {}), {1: 90});
    old.complete(response('wifi-1', servers, value: 10));
    expect(await a, isEmpty);
    expect(await same, isEmpty);
    expect(await catalog.refresh(servers, onInvalidated: () {}), {1: 90});
    expect(calls, 2);
  });

  test(
      'missing network, incomplete probes and mismatched endpoints are never low ping',
      () async {
    final servers = [server(1)];
    var mode = 0;
    final catalog = ServerLatencyCatalog(invoke: (method, args) async {
      if (method == 'getServerLatencyNetwork')
        return mode == 0
            ? {'available': false}
            : {'available': true, 'network_id': 'n$mode'};
      if (mode == 1) return {'completed': false};
      return {
        'completed': true,
        'network_id': 'n$mode',
        'results': [
          {
            'id': 1,
            'host': '203.0.113.8',
            'port': 8080,
            'latency_ms': 1,
            'successes': 3
          },
          {
            'id': 1,
            'host': '198.51.100.1',
            'port': 8080,
            'latency_ms': 2,
            'successes': 1
          },
        ]
      };
    });
    for (mode = 0; mode < 3; mode++) {
      expect(await catalog.refresh(servers, onInvalidated: () {}), isEmpty);
    }
  });
}
