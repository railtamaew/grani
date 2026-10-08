import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

typedef TelemetrySender = Future<Set<String>> Function(
    List<Map<String, dynamic>> events);

/// Bounded diagnostics only. No probes, periodic speed tests or VPN ownership.
class SimpleVpnTelemetry {
  SimpleVpnTelemetry({
    required this.send,
    required this.canSend,
    this.cancelSend,
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
    DateTime Function()? now,
    this.automaticScheduling = true,
  })  : _read = read ?? _readPreferences,
        _write = write ?? _writePreferences,
        _now = now ?? DateTime.now;

  // v2 has no account ownership. Never relabel its queued records after login.
  static const storageKey = 'simple_vpn_telemetry_v3';
  static const maxEntries = 128;
  static const maxEventBytes = 3072;
  static const maxBatch = 8;
  static const minInterval = Duration(minutes: 1);
  static const maxAge = Duration(hours: 24);
  static const acceptedEvents = <String>{
    'connect_intent',
    'attempt_started',
    'connect_deferred',
    'vpn_existing_session_adopted',
    'ui_state_transition',
    'attempt_blocked',
    'device_limit_blocked',
    'access_required_disconnect',
    'telemetry_health',
    'connect_tap',
    'native_start_ok',
    'connect_failed',
    'connect_cancelled',
    'disconnect_ok',
    'disconnect_failed',
    'vpn_unexpected_disconnect',
    'vpn_data_verified',
    'node_data_verified',
    'connectivity_probe',
  };
  static const detailFields = <String>{
    'intent_id',
    'attempt_id',
    'reason_code',
    'failure_stage',
    'error_family',
    'from',
    'to',
    'ui_state_from',
    'ui_state_to',
    'state_reason',
    'contract_version',
    'protocol',
    'selected_protocol',
    'runtime_protocol',
    'server_id',
    'runtime_session_id',
    'backend_session_id',
    'connection_session_id',
    'vpn_session_id',
    'source',
    'reason',
    'phase',
    'error_code',
    'runtime_down',
    'connection_duration_ms',
    'proof_latency_ms',
    'connect_to_native_ready_ms',
    'rx_bytes',
    'tx_bytes',
    'service_proof_seen',
    'terminal_source',
    'verification_scope',
    'verification_source',
    'traffic_counters_available',
    'node_verified',
    'from_cache',
    'config_from_cache',
    'state',
    'status',
    'public_ok',
    'public_rtt_ms',
    'public_http_status',
    'public_probe_route',
    'public_vpn_proof',
    'protocol_bridge_ready',
    'public_fallback_unbound',
    'public_probe_attempts',
    'api_ok',
    'api_rtt_ms',
    'api_http_status',
    'api_probe_route',
    'underlying_network_type',
    'underlying_network_available',
    'underlying_internet_ok',
    'internet_without_vpn_ok',
    'underlying_probe_rtt_ms',
    'underlying_probe_http_status',
    'control_plane_degraded',
    'vpn_transport_bound',
    'disconnect_source',
    'lifecycle_state',
    'had_verified_traffic',
    'session_age_bucket',
    'app_version',
    'build_number',
    'platform',
    'http_duration_semantics',
    'schema_version',
    'observed_at',
  };

  final TelemetrySender send;
  final bool Function() canSend;
  final void Function()? cancelSend;
  final Future<String?> Function() _read;
  final Future<void> Function(String) _write;
  final DateTime Function() _now;
  final bool automaticScheduling;
  final List<Map<String, dynamic>> _entries = [];
  final Map<String, DateTime> _probeTimes = {};
  Future<void> _serial = Future<void>.value();
  Timer? _timer;
  DateTime? _nextSend;
  DateTime? _lastAttempt;
  bool _loaded = false;
  bool _sending = false;
  bool _disposed = false;
  int _failures = 0;
  int droppedEvents = 0;
  String? _installationId;
  int _sequence = 0;

  static String _randomId() {
    final random = Random.secure();
    return List.generate(16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<String?> _readPreferences() async =>
      (await SharedPreferences.getInstance()).getString(storageKey);
  static Future<void> _writePreferences(String value) async {
    await (await SharedPreferences.getInstance()).setString(storageKey, value);
  }

  Future<void> _locked(Future<void> Function() action) {
    final work = _serial.then((_) => action());
    _serial = work.catchError((Object _) {});
    return work;
  }

  Future<void> _load() async {
    if (_loaded) return;
    try {
      final raw = await _read();
      if (raw != null && utf8.encode(raw).length <= 256 * 1024) {
        final value = jsonDecode(raw) as Map;
        _nextSend = DateTime.tryParse(value['next_send']?.toString() ?? '');
        _lastAttempt = DateTime.tryParse(value['last_attempt']?.toString() ?? '');
        _failures = (value['failures'] as num?)?.toInt() ?? 0;
        _installationId = value['installation_id'] as String?;
        _sequence = (value['sequence'] as num?)?.toInt() ?? 0;
        droppedEvents = (value['dropped_events'] as num?)?.toInt() ?? 0;
        for (final item
            in (value['events'] as List? ?? const []).take(maxEntries)) {
          if (item is Map &&
              utf8.encode(jsonEncode(item)).length <= maxEventBytes) {
            _entries.add(Map<String, dynamic>.from(item));
          }
        }
      }
    } catch (_) {
      // A corrupt diagnostic cache must never prevent a VPN connection.
    }
    _loaded = true;
    _installationId ??= _randomId();
    _prune();
  }

  void _prune() {
    final oldest = _now().subtract(maxAge);
    _entries.removeWhere((e) {
      final date = DateTime.tryParse(e['observed_at']?.toString() ?? '');
      final remove = date == null || date.isBefore(oldest);
      if (remove) droppedEvents++;
      return remove;
    });
    while (_entries.length > maxEntries) {
      final probe =
          _entries.indexWhere((e) => e['event'] == 'connectivity_probe');
      _entries.removeAt(probe >= 0 ? probe : 0);
      droppedEvents++;
    }
  }

  Future<void> _persist() => _write(jsonEncode({
        'events': _entries,
        'next_send': _nextSend?.toUtc().toIso8601String(),
        'last_attempt': _lastAttempt?.toUtc().toIso8601String(),
        'failures': _failures,
        'installation_id': _installationId,
        'sequence': _sequence,
        'dropped_events': droppedEvents,
      }));

  /// Completes after local enqueue, never after an HTTP request.
  Future<void> enqueue(Map<String, dynamic> payload) async {
    if (_disposed || !acceptedEvents.contains(payload['event'])) return;
    if (int.tryParse(payload['owner_id']?.toString() ?? '') == null) {
      debugPrint('[PRODUCT_TELEMETRY] dropped reason=invalid_account');
      return;
    }
    try {
      await _locked(() async {
        await _load();
        final now = _now();
        final details = <String, dynamic>{};
        final original = payload['details'];
        if (original is Map) {
          for (final key in detailFields) {
            final value = original[key];
            if (value is bool || value is num || value == null) {
              if (value != null) details[key] = value;
            } else if (value is String) {
              details[key] =
                  value.length > 160 ? value.substring(0, 160) : value;
            }
          }
        }
        if (payload['event'] == 'connectivity_probe') {
          final key =
              '${details['runtime_session_id']}:${details['public_probe_route']}';
          final previous = _probeTimes[key];
          if (previous != null && now.difference(previous) < minInterval) {
            return;
          }
          if (_probeTimes.length >= 64) {
            _probeTimes.remove(_probeTimes.keys.first);
          }
          _probeTimes[key] = now;
        }
        final id = _randomId();
        details['schema_version'] = 3;
        details['event_sequence'] = ++_sequence;
        details['queue_dropped_events'] = droppedEvents;
        details['observed_at'] = now.toUtc().toIso8601String();
        details['idempotency_key'] = id;
        final item = <String, dynamic>{
          'event_id': id,
          'installation_id': _installationId,
          'owner_id': int.parse(payload['owner_id'].toString()),
          'observed_at': details['observed_at'],
          'event': payload['event'],
          'device_id': payload['device_id'],
          if (payload['session_id'] != null)
            'session_id': payload['session_id'],
          'level': payload['level'] ?? 'info',
          'details': details,
        };
        if (utf8.encode(jsonEncode(item)).length > maxEventBytes) {
          droppedEvents++;
          return;
        }
        _entries.add(item);
        _prune();
        await _persist();
        debugPrint('[PRODUCT_TELEMETRY] queued event=${payload['event']} count=${_entries.length}');
      });
      _schedule();
    } catch (error) {
      // Storage failure affects diagnostics only.
      debugPrint('[PRODUCT_TELEMETRY] storage_error type=${error.runtimeType}');
    }
  }

  Future<void> connectionStateChanged({bool connectionRecovered = false}) async {
    if (!canSend()) cancelSend?.call();
    try {
      await _locked(() async {
        await _load();
        if (connectionRecovered && canSend() && _failures > 0) {
          // A working VPN is new evidence that a queued retry can succeed.
          // Keep the one-batch-per-minute cap, including persisted old queues.
          final earliest = (_lastAttempt ?? _now()).add(minInterval);
          final retry = earliest.isAfter(_now()) ? earliest : _now();
          if (_nextSend == null || _nextSend!.isAfter(retry)) _nextSend = retry;
          _failures = 0;
          await _persist();
        }
      });
    } catch (error) {
      debugPrint('[PRODUCT_TELEMETRY] resume_error type=${error.runtimeType}');
    } finally {
      _timer?.cancel();
      _timer = null;
      _schedule();
    }
  }

  Future<void> resume() async {
    try {
      await _locked(_load);
      _schedule();
    } catch (_) {}
  }

  void _schedule() {
    if (_disposed ||
        !automaticScheduling ||
        _sending ||
        _timer != null ||
        _entries.isEmpty) {
      return;
    }
    var delay = const Duration(seconds: 5);
    final until = _nextSend?.difference(_now());
    if (until != null && until > delay) delay = until;
    if (!canSend() && delay < const Duration(seconds: 30)) {
      delay = const Duration(seconds: 30);
    }
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(flush());
    });
  }

  Future<void> flush() async {
    if (_disposed || _sending) return;
    _sending = true;
    List<Map<String, dynamic>> batch = [];
    try {
      await _locked(() async {
        await _load();
        final beforePrune = _entries.length;
        _prune();
        if (_entries.length != beforePrune) await _persist();
        if (!canSend() || (_nextSend?.isAfter(_now()) ?? false)) {
          return;
        }
        batch = _entries
            .take(maxBatch)
            .map((e) => <String,dynamic>{...e, 'details': <String,dynamic>{
              ...Map<String,dynamic>.from(e['details'] as Map),
              'queue_dropped_events': droppedEvents,
              'queue_oldest_age_ms': max(0, _now().difference(
                DateTime.tryParse(e['observed_at'].toString()) ?? _now()).inMilliseconds),
            }})
            .toList();
        if (batch.isNotEmpty) {
          _lastAttempt = _now();
          _nextSend = _now().add(minInterval);
          await _persist();
        }
      });
      if (batch.isEmpty) return;
      // Never hold the persistence lock across network I/O.
      final acknowledged = await send(batch);
      final sentIds = batch.map((e) => e['event_id'] as String).toSet();
      final confirmed = acknowledged.intersection(sentIds);
      if (confirmed.isEmpty) {
        throw StateError('No persisted telemetry acknowledgement');
      }
      await _locked(() async {
        _entries.removeWhere((e) => confirmed.contains(e['event_id']));
        _failures = 0;
        await _persist();
      });
    } catch (error) {
      debugPrint('[PRODUCT_TELEMETRY] retry type=${error.runtimeType}');
      try {
        await _locked(() async {
          _failures = min(_failures + 1, 6);
          _nextSend =
              _now().add(Duration(minutes: min(1 << (_failures - 1), 30)));
          // A stale/unregistered device in one batch must not permanently
          // head-of-line block newer sessions; keep its events for bounded retry.
          final attemptedIds = batch.map((e) => e['event_id']).toSet();
          final attempted = _entries
              .where((e) => attemptedIds.contains(e['event_id']))
              .toList();
          _entries.removeWhere((e) => attemptedIds.contains(e['event_id']));
          _entries.addAll(attempted);
          _prune();
          await _persist();
        });
      } catch (_) {}
    } finally {
      _sending = false;
      _schedule();
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    cancelSend?.call();
  }
}
