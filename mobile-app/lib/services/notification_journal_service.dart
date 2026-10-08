import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/storage/shared_preferences_holder.dart';

/// Запись журнала push / локальных уведомлений (хранится на устройстве).
class NotificationJournalEntry {
  NotificationJournalEntry({
    required this.id,
    required this.title,
    required this.body,
    required this.receivedAt,
    required this.source,
    this.dataJson,
  });

  final String id;
  final String title;
  final String body;
  final DateTime receivedAt;
  /// fcm_foreground | fcm_opened_app | fcm_initial_message | fcm_background_ios
  final String source;
  final String? dataJson;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'receivedAt': receivedAt.toIso8601String(),
        'source': source,
        'dataJson': dataJson,
      };

  static NotificationJournalEntry? fromJson(Map<String, dynamic> m) {
    final id = m['id'] as String?;
    final title = m['title'] as String?;
    final body = m['body'] as String?;
    final receivedAt = m['receivedAt'] as String?;
    final source = m['source'] as String?;
    if (id == null || title == null || body == null || receivedAt == null || source == null) {
      return null;
    }
    return NotificationJournalEntry(
      id: id,
      title: title,
      body: body,
      receivedAt: DateTime.tryParse(receivedAt) ?? DateTime.now(),
      source: source,
      dataJson: m['dataJson'] as String?,
    );
  }
}

/// Локальное хранение журнала уведомлений (SharedPreferences).
class NotificationJournalService extends ChangeNotifier {
  NotificationJournalService._();
  @visibleForTesting
  NotificationJournalService.test();
  static final NotificationJournalService instance = NotificationJournalService._();

  String _account = 'signed_out';
  String get _prefsKey => 'grani_notification_journal_v2_$_account';
  static const _maxEntries = 200;

  final List<NotificationJournalEntry> _entries = [];
  bool _loaded = false;
  DateTime? _clearedAt;
  Future<void> _queue = Future.value();

  Future<void> _serial(Future<void> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.catchError((Object e) {
      debugPrint('[Journal] storage operation failed: ${e.runtimeType}');
    });
    return next;
  }

  Future<void> setAccount(String? userId) => _serial(() async {
    final account = userId ?? 'signed_out';
    if (_account == account) return;
    _account = account;
    _entries.clear();
    _loaded = false;
    await _load();
  });

  List<NotificationJournalEntry> get entries => List.unmodifiable(_entries);
  bool accepts(Map<String, dynamic> data) => data['user_id'] == null || data['user_id'].toString() == _account;

  Future<void> ensureLoaded() => _serial(_load);

  Future<void> _load() async {
    if (_loaded) return;
    final prefs = await getSharedPreferences();
    final raw = prefs.getString(_prefsKey);
    _clearedAt = DateTime.tryParse(prefs.getString('${_prefsKey}_cleared') ?? '');
    _entries.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        for (final e in list) {
          if (e is Map) {
            final entry = NotificationJournalEntry.fromJson(
              Map<String, dynamic>.from(e),
            );
            if (entry != null) _entries.add(entry);
          }
        }
      } catch (_) {
        // ignore corrupt
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await getSharedPreferences();
    final list = _entries.map((e) => e.toJson()).toList();
    await prefs.setString(_prefsKey, jsonEncode(list));
  }

  /// Добавить запись (новые сверху). [showBanner] не используется здесь — только хранение.
  Future<void> append({
    required String title,
    required String body,
    required String source,
    Map<String, dynamic>? data,
    String? eventId,
    DateTime? receivedAt,
    String? accountId,
  }) => _serial(() async {
    await _load();
    final owner = accountId ?? data?['user_id']?.toString();
    if (owner != null && owner != _account) return;
    final at = receivedAt ?? DateTime.now();
    if (_clearedAt != null && !at.isAfter(_clearedAt!)) return;
    final id = eventId ?? data?['notification_id']?.toString() ??
        '${DateTime.now().microsecondsSinceEpoch}_${title.hashCode}';
    if (_entries.any((e) => e.id == id)) return;
    final dataJson = data == null || data.isEmpty ? null : jsonEncode(data);
    _entries.insert(
      0,
      NotificationJournalEntry(
        id: id,
        title: title,
        body: body,
        receivedAt: at,
        source: source,
        dataJson: dataJson,
      ),
    );
    _entries.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    while (_entries.length > _maxEntries) {
      _entries.removeLast();
    }
    await _persist();
    notifyListeners();
  });

  Future<void> clearAll() => _serial(() async {
    await _load();
    _entries.clear();
    _clearedAt = DateTime.now().toUtc();
    await (await getSharedPreferences()).setString('${_prefsKey}_cleared', _clearedAt!.toIso8601String());
    await _persist();
    notifyListeners();
  });
}
