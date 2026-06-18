import 'dart:math' show Random;

/// UUID v4 для заголовка [X-Request-ID] — склейка логов клиент ↔ nginx ↔ API ↔ Cloudflare (по полю).
String newGraniRequestId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const hex = '0123456789abcdef';
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(hex[x >> 4]);
    sb.write(hex[x & 0x0f]);
  }
  final s = sb.toString();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20, 32)}';
}
