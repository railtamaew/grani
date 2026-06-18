import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../config/app_config.dart';

/// Упрощенный логгер для отправки логов на сервер
/// Используется в минимальном приложении для тестирования VPN протоколов
class SimpleLogger {
  static final SimpleLogger _instance = SimpleLogger._internal();
  factory SimpleLogger() => _instance;
  SimpleLogger._internal();

  final Dio _dio = Dio(BaseOptions(
    baseUrl: AppConfig.apiBaseUrl,
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  final List<Map<String, dynamic>> _pendingLogs = [];
  Timer? _flushTimer;
  bool _isFlushing = false;
  bool _enabled = true;

  /// Инициализация логгера
  void initialize() {
    if (!_enabled) return;
    
    // Отправка каждые 15 секунд (уменьшено для быстрой проверки)
    _flushTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _flushLogs();
    });
    
    debugPrint('SimpleLogger: Инициализирован, отправка каждые 30 секунд');
  }

  /// Включить/выключить логирование
  void setEnabled(bool enabled) {
    _enabled = enabled;
    if (!enabled) {
      _flushTimer?.cancel();
    }
  }

  /// Логирование с уровнем
  void log(String level, String tag, String message, {Map<String, dynamic>? extra}) {
    if (!_enabled) return;
    
    final logEntry = {
      'timestamp': DateTime.now().toIso8601String(),
      'level': level, // DEBUG, INFO, WARN, ERROR
      'tag': tag,
      'message': message,
      if (extra != null) 'extra': extra,
    };

    _pendingLogs.add(logEntry);
    debugPrint('[$level] $tag: $message');

    // Если накопилось много, отправляем сразу
    if (_pendingLogs.length >= 10) {
      _flushLogs();
    }
    
    // Принудительная отправка при ошибках (чтобы не терять важные логи)
    if (level == 'ERROR' && _pendingLogs.length >= 1) {
      _flushLogs();
    }
  }

  /// Удобные методы для разных уровней
  void debug(String tag, String message, {Map<String, dynamic>? extra}) {
    log('DEBUG', tag, message, extra: extra);
  }

  void info(String tag, String message, {Map<String, dynamic>? extra}) {
    log('INFO', tag, message, extra: extra);
  }

  void warn(String tag, String message, {Map<String, dynamic>? extra}) {
    log('WARN', tag, message, extra: extra);
  }

  void error(String tag, String message, {Map<String, dynamic>? extra}) {
    log('ERROR', tag, message, extra: extra);
  }

  /// Отправка накопленных логов на сервер
  Future<void> _flushLogs() async {
    if (!_enabled || _isFlushing || _pendingLogs.isEmpty) {
      return;
    }

    _isFlushing = true;
    
    final logsToSend = List<Map<String, dynamic>>.from(_pendingLogs);
    _pendingLogs.clear();

    try {
      debugPrint('SimpleLogger: Отправка ${logsToSend.length} логов на сервер...');
      debugPrint('SimpleLogger: URL: ${AppConfig.apiBaseUrl}/vpn/logs/test');
      
      final response = await _dio.post(
        '/vpn/logs/test',
        data: {
          'app': AppConfig.appName,
          'logs': logsToSend,
        },
      );
      
      debugPrint('SimpleLogger: ✅ Логи отправлены на сервер: ${logsToSend.length} шт.');
      debugPrint('SimpleLogger: Ответ сервера: ${response.data}');
    } catch (e) {
      debugPrint('SimpleLogger: ❌ Ошибка отправки логов: $e');
      if (e is DioException) {
        debugPrint('SimpleLogger: Status: ${e.response?.statusCode}');
        debugPrint('SimpleLogger: Response: ${e.response?.data}');
        debugPrint('SimpleLogger: Request: ${e.requestOptions.uri}');
      }
      // Возвращаем логи в очередь для повторной попытки
      _pendingLogs.addAll(logsToSend);
    } finally {
      _isFlushing = false;
    }
  }

  /// Принудительная отправка всех накопленных логов
  Future<void> flush() async {
    await _flushLogs();
  }

  /// Очистка ресурсов
  void dispose() {
    _flushTimer?.cancel();
    flush(); // Отправляем оставшиеся логи
  }
}
