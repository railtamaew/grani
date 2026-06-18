import 'dart:io';

import '../../models/server.dart';

/// Порт по умолчанию для Xray на ноде (согласован с backend DEFAULT_XRAY_PORT).
const int kDefaultXrayProbePort = 4443;

/// Для серверов без [Server.ping] с API — замер TCP connect до ноды (мс).
/// Не блокирует надолго: пачки по [concurrency], таймаут на сокет.
Future<List<Server>> enrichServersWithClientPing(
  List<Server> servers, {
  int defaultXrayPort = kDefaultXrayProbePort,
  int concurrency = 3,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final out = List<Server>.from(servers);
  final indices = <int>[];
  for (var i = 0; i < out.length; i++) {
    if (out[i].ping == null) {
      indices.add(i);
    }
  }
  if (indices.isEmpty) {
    return out;
  }

  for (var i = 0; i < indices.length; i += concurrency) {
    final batch = indices.skip(i).take(concurrency);
    await Future.wait(
      batch.map((idx) async {
        final s = out[idx];
        final port = s.xrayPort ?? defaultXrayPort;
        final sw = Stopwatch()..start();
        Socket? socket;
        try {
          socket = await Socket.connect(s.ip, port, timeout: timeout);
          sw.stop();
          final ms = sw.elapsedMilliseconds.toDouble();
          out[idx] = s.withPing(ms);
        } catch (_) {
          // ping остаётся null
        } finally {
          socket?.destroy();
        }
      }),
    );
  }
  return out;
}
