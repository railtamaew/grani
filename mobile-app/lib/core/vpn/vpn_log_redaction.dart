import 'dart:convert';

/// Маскирование типичных секретов Xray/VLESS в строках для debug/logcat.
abstract final class VpnLogRedaction {
  static final RegExp _uuid = RegExp(
    r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
    caseSensitive: false,
  );

  static final RegExp _quotedSensitive = RegExp(
    r'"(publicKey|privateKey|password|pbk|shortId)"\s*:\s*"[^"]*"',
    caseSensitive: false,
  );

  /// Идентификатор пользователя VLESS и др. в outbound.
  static final RegExp _idField = RegExp(
    r'"id"\s*:\s*"[^"]+"',
    caseSensitive: false,
  );

  static String redactSensitiveJson(String text) {
    var s = text.replaceAllMapped(
      _quotedSensitive,
      (m) => '"${m.group(1)}":"<redacted>"',
    );
    s = s.replaceAll(_idField, '"id":"<redacted>"');
    return s.replaceAll(_uuid, '<redacted>');
  }

  static String redactForLog(Object? value) {
    if (value == null) return 'null';
    final str = value is String ? value : jsonEncode(value);
    return redactSensitiveJson(str);
  }

  static String previewRedacted(String text, int maxLen) {
    final r = redactSensitiveJson(text);
    if (r.length <= maxLen) return r;
    return '${r.substring(0, maxLen)}…';
  }
}
