import 'package:flutter/foundation.dart';

/// Уровни логирования
enum LogLevel {
  debug,
  info,
  warning,
  error,
}

/// Единый Logger для всего приложения
/// Заменяет debugPrint на структурированное логирование
class Logger {
  static final Logger _instance = Logger._internal();
  factory Logger() => _instance;
  Logger._internal();

  LogLevel _minLevel = kDebugMode ? LogLevel.debug : LogLevel.info;
  final List<LogEntry> _logs = [];
  static const int _maxLogsDebug = 1000;
  static const int _maxLogsRelease = 100;
  int get _maxLogs => kDebugMode ? _maxLogsDebug : _maxLogsRelease;

  /// Установить минимальный уровень логирования
  void setMinLevel(LogLevel level) {
    _minLevel = level;
  }

  /// Debug уровень - детальная информация для разработки
  void debug(String message, [String? tag]) {
    _log(LogLevel.debug, message, tag);
  }

  /// Info уровень - общая информация о работе приложения
  void info(String message, [String? tag]) {
    _log(LogLevel.info, message, tag);
  }

  /// Warning уровень - предупреждения о потенциальных проблемах
  void warning(String message, [String? tag]) {
    _log(LogLevel.warning, message, tag);
  }

  /// Error уровень - ошибки, требующие внимания
  void error(String message, [String? tag, Object? error, StackTrace? stackTrace]) {
    _log(LogLevel.error, message, tag, error, stackTrace);
  }

  /// Внутренний метод логирования
  void _log(
    LogLevel level,
    String message,
    String? tag, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    if (level.index < _minLevel.index) {
      return;
    }

    final entry = LogEntry(
      level: level,
      message: message,
      tag: tag,
      timestamp: DateTime.now(),
      error: error,
      stackTrace: stackTrace,
    );

    // В release не храним debug-записи в буфере (уже отфильтровано по _minLevel)
    _logs.add(entry);
    while (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }

    // Выводим в консоль
    final prefix = tag != null ? '[$tag]' : '';
    final levelName = level.name.toUpperCase().padRight(7);
    final timestamp = entry.timestamp.toIso8601String().substring(11, 19);
    
    final logMessage = '$timestamp $levelName $prefix $message';
    
    if (kDebugMode) {
      debugPrint(logMessage);
      
      if (error != null) {
        debugPrint('Error: $error');
        if (stackTrace != null) {
          debugPrint('StackTrace: $stackTrace');
        }
      }
    }
  }

  /// Получить все логи
  List<LogEntry> getLogs() => List.unmodifiable(_logs);

  /// Получить логи определенного уровня
  List<LogEntry> getLogsByLevel(LogLevel level) {
    return _logs.where((entry) => entry.level == level).toList();
  }

  /// Очистить логи
  void clear() {
    _logs.clear();
  }

  /// Экспорт логов в строку (для отправки на сервер)
  String exportLogs() {
    final buffer = StringBuffer();
    for (final entry in _logs) {
      buffer.writeln(entry.toString());
    }
    return buffer.toString();
  }
}

/// Запись лога
class LogEntry {
  final LogLevel level;
  final String message;
  final String? tag;
  final DateTime timestamp;
  final Object? error;
  final StackTrace? stackTrace;

  LogEntry({
    required this.level,
    required this.message,
    this.tag,
    required this.timestamp,
    this.error,
    this.stackTrace,
  });

  @override
  String toString() {
    final prefix = tag != null ? '[$tag]' : '';
    final levelName = level.name.toUpperCase().padRight(7);
    final timestamp = this.timestamp.toIso8601String();
    final errorStr = error != null ? ' | Error: $error' : '';
    
    return '$timestamp $levelName $prefix $message$errorStr';
  }
}
