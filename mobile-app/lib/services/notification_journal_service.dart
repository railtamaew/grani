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
  static final NotificationJournalService instance = NotificationJournalService._();

  static const _prefsKey = 'grani_notification_journal_v1';
  static const _maxEntries = 200;

  final List<NotificationJournalEntry> _entries = [];
  bool _loaded = false;

  List<NotificationJournalEntry> get entries => List.unmodifiable(_entries);

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await getSharedPreferences();
    final raw = prefs.getString(_prefsKey);
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
  }) async {
    await ensureLoaded();
    final id = '${DateTime.now().microsecondsSinceEpoch}_${title.hashCode}';
    final dataJson = data == null || data.isEmpty ? null : jsonEncode(data);
    _entries.insert(
      0,
      NotificationJournalEntry(
        id: id,
        title: title,
        body: body,
        receivedAt: DateTime.now(),
        source: source,
        dataJson: dataJson,
      ),
    );
    while (_entries.length > _maxEntries) {
      _entries.removeLast();
    }
    await _persist();
    notifyListeners();
  }

  Future<void> clearAll() async {
    await ensureLoaded();
    _entries.clear();
    await _persist();
    notifyListeners();
  }
}
