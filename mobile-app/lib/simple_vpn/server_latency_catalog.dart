import 'dart:async';
import 'package:flutter/services.dart';
import 'simple_vpn_api.dart';

typedef LatencyNativeCall = Future<Map<String, dynamic>?> Function(
    String method, Map<String, dynamic>? arguments);

/// Short-lived, device/network-specific readings shared by preparation and home.
class ServerLatencyCatalog {
  ServerLatencyCatalog({LatencyNativeCall? invoke, DateTime Function()? now})
      : _invoke = invoke ?? _nativeCall,
        _now = now ?? DateTime.now;

  static final shared = ServerLatencyCatalog();
  static const ttl = Duration(seconds: 60);
  static const unavailableTtl = Duration(seconds: 3);
  static const _channel = MethodChannel('com.granivpn.mobile/vpn');
  final LatencyNativeCall _invoke;
  final DateTime Function() _now;
  String? _key;
  DateTime? _measuredAt;
  Map<int, double> _readings = {};
  Future<Map<int, double>>? _pending;
  String? _pendingKey;

  static Future<Map<String, dynamic>?> _nativeCall(
      String method, Map<String, dynamic>? args) async {
    try {
      final value = await _channel
          .invokeMapMethod<String, dynamic>(method, args)
          .timeout(const Duration(seconds: 16));
      return value;
    } catch (_) {
      return null;
    }
  }

  static String signature(List<SimpleVpnServer> servers) {
    final parts = servers
        .map((s) => '${s.id}:${s.latencyProbeHost}:${s.latencyProbePort}')
        .toList()
      ..sort();
    return parts.join('|');
  }

  Future<Map<int, double>> refresh(List<SimpleVpnServer> servers,
      {required void Function() onInvalidated}) async {
    Map<String, dynamic>? network;
    try {
      network = await _invoke('getServerLatencyNetwork', null);
    } catch (_) {}
    final networkId = network?['network_id']?.toString();
    if (network?['available'] != true ||
        networkId == null ||
        networkId.isEmpty) {
      _key = null;
      _measuredAt = null;
      _readings = {};
      onInvalidated();
      return {};
    }
    final key = '$networkId/${signature(servers)}';
    if (_key == key &&
        _measuredAt != null &&
        _now().difference(_measuredAt!) <
            (_readings.isEmpty ? unavailableTtl : ttl)) {
      return Map.of(_readings);
    }
    // Expired readings and readings from another network must not remain visible.
    onInvalidated();
    if (_pendingKey == key && _pending != null) return _pending!;
    _key = key;
    _readings = {};
    _measuredAt = null;
    final endpoints = servers
        .where(
            (s) => s.latencyProbeHost.isNotEmpty && s.latencyProbePort != null)
        .map((s) => <String, dynamic>{
              'id': s.id,
              'host': s.latencyProbeHost,
              'port': s.latencyProbePort
            })
        .toList();
    final operation = () async {
      Map<String, dynamic>? response;
      try {
        response = await _invoke('probeServerLatencies',
            {'network_id': networkId, 'endpoints': endpoints});
      } catch (_) {}
      if (_key != key ||
          response?['completed'] != true ||
          response?['network_id']?.toString() != networkId)
        return <int, double>{};
      final measured = <int, double>{};
      final results = response?['results'];
      if (results is List) {
        for (final raw in results.whereType<Map>()) {
          final id = (raw['id'] as num?)?.toInt();
          final ms = raw['latency_ms'];
          final successes = (raw['successes'] as num?)?.toInt() ?? 0;
          if (id == null ||
              ms is! num ||
              !ms.isFinite ||
              ms <= 0 ||
              successes < 2) continue;
          if (!servers.any((s) =>
              s.id == id &&
              s.latencyProbeHost == raw['host'] &&
              s.latencyProbePort == raw['port'])) continue;
          measured[id] = ms.toDouble();
        }
      }
      _readings = measured;
      _measuredAt = _now();
      return Map<int, double>.of(measured);
    }();
    _pending = operation;
    _pendingKey = key;
    try {
      return await operation;
    } finally {
      if (identical(_pending, operation)) {
        _pending = null;
        _pendingKey = null;
      }
    }
  }
}

List<SimpleVpnServer> sortServersByLatency(
    List<SimpleVpnServer> servers, Map<int, double> readings,
    {int? preferredServerId}) {
  final order = {for (var i = 0; i < servers.length; i++) servers[i].id: i};
  double? value(SimpleVpnServer s) {
    final ms = readings[s.id];
    return ms != null && ms.isFinite && ms > 0 ? ms : null;
  }

  return List<SimpleVpnServer>.of(servers)
    ..sort((a, b) {
      if (a.id == preferredServerId && b.id != preferredServerId) return -1;
      if (b.id == preferredServerId && a.id != preferredServerId) return 1;
      final x = value(a), y = value(b);
      if (x == null && y != null) return 1;
      if (x != null && y == null) return -1;
      final compared = x != null && y != null ? x.compareTo(y) : 0;
      return compared != 0 ? compared : order[a.id]!.compareTo(order[b.id]!);
    });
}
