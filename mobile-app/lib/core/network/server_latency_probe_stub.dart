import '../../models/server.dart';

const int kDefaultXrayProbePort = 4443;

/// На платформах без `dart:io` замер не выполняется.
Future<List<Server>> enrichServersWithClientPing(
  List<Server> servers, {
  int defaultXrayPort = kDefaultXrayProbePort,
  int concurrency = 3,
  Duration timeout = const Duration(seconds: 2),
}) async =>
    List<Server>.from(servers);
