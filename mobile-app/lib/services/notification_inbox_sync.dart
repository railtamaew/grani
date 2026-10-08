import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import 'auth_service.dart';
import 'notification_journal_service.dart';

/// Pulling server history also covers denied pushes and unopened notifications.
class NotificationInboxSync with WidgetsBindingObserver {
  NotificationInboxSync(this.auth);
  final AuthService auth;
  Timer? _timer;
  String? _account;
  bool _busy = false;
  bool _active = true;
  bool _disposed = false;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    auth.addListener(_authChanged);
    _authChanged();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(sync()));
  }

  void _authChanged() {
    final current = auth.isAuthenticated ? auth.user?.id.toString() : null;
    if (current == _account) return;
    _account = current;
    unawaited(NotificationJournalService.instance.setAccount(current).then((_) => sync()));
  }

  Future<void> sync() async {
    final userId = _account;
    final token = auth.token;
    if (_disposed || !_active || _busy || userId == null || token == null) return;
    _busy = true;
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiBaseUrl}/notifications'),
        headers: {'Authorization': 'Bearer $token'}).timeout(const Duration(seconds: 8));
      if (_disposed || _account != userId || response.statusCode != 200) return;
      final items = (jsonDecode(response.body) as Map)['items'] as List;
      for (final raw in items) {
        if (_disposed || _account != userId) return;
        final item = Map<String, dynamic>.from(raw as Map);
        await NotificationJournalService.instance.append(
          title: item['title'] as String, body: item['body'] as String,
          source: 'server', eventId: item['id'] as String, accountId: userId,
          receivedAt: DateTime.parse(item['created_at'] as String),
          data: Map<String, dynamic>.from(item['data'] as Map));
      }
    } catch (e) {
      debugPrint('[Journal] sync deferred: ${e.runtimeType}');
    } finally {
      _busy = false;
      if (!_disposed && _account != userId) unawaited(sync());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (_active) unawaited(sync());
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    auth.removeListener(_authChanged);
    WidgetsBinding.instance.removeObserver(this);
  }
}
