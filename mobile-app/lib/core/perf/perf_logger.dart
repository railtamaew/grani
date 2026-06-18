import 'package:flutter/foundation.dart';
import '../logger/logger.dart';

class PerfLogger {
  static final PerfLogger _instance = PerfLogger._internal();
  factory PerfLogger() => _instance;
  PerfLogger._internal();

  final Logger _logger = Logger();
  final Map<String, Stopwatch> _timers = {};

  void start(String name) {
    final sw = Stopwatch()..start();
    _timers[name] = sw;
  }

  int? stop(
    String name, {
    Map<String, Object?>? details,
  }) {
    final sw = _timers.remove(name);
    if (sw == null) {
      return null;
    }
    sw.stop();
    final durationMs = sw.elapsedMilliseconds;
    _log(name, durationMs, details);
    return durationMs;
  }

  void record(
    String name,
    int durationMs, {
    Map<String, Object?>? details,
  }) {
    _log(name, durationMs, details);
  }

  void _log(String name, int durationMs, Map<String, Object?>? details) {
    final extra = details == null || details.isEmpty ? '' : ' details=$details';
    _logger.info('Perf[$name]: ${durationMs}ms$extra', 'Perf');
    if (kDebugMode) {
      debugPrint('Perf[$name]: ${durationMs}ms$extra');
    }
  }
}
