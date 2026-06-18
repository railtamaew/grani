import 'package:dio/dio.dart';

/// Текст ошибки из JSON-тела ответа API (detail / error.message) — для UI и логов.
String? userVisibleMessageFromDioResponse(DioException e) {
  final data = e.response?.data;
  if (data is Map) {
    final detail = data['detail'];
    if (detail is String && detail.trim().isNotEmpty) return detail.trim();
    final err = data['error'];
    if (err is Map) {
      final m = err['message'];
      if (m is String && m.trim().isNotEmpty) return m.trim();
    }
    final msg = data['message'];
    if (msg is String && msg.trim().isNotEmpty) return msg.trim();
  }
  return null;
}
