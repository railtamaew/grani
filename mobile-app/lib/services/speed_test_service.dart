import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Сервис для измерения скорости интернета в реальном времени
class SpeedTestService {
  Timer? _measurementTimer;
  double _currentSpeed = 0.0; // Мбит/с
  bool _isMeasuring = false;
  final List<Function(double)> _listeners = [];

  double get currentSpeed => _currentSpeed;
  bool get isMeasuring => _isMeasuring;

  /// Добавить слушателя изменений скорости
  void addListener(Function(double) listener) {
    _listeners.add(listener);
  }

  /// Удалить слушателя
  void removeListener(Function(double) listener) {
    _listeners.removeWhere((l) => l == listener);
  }

  /// Уведомить всех слушателей об изменении скорости
  void _notifyListeners() {
    for (var listener in _listeners) {
      listener(_currentSpeed);
    }
  }

  /// Начать измерение скорости
  /// Обновляет значение каждые 2-3 секунды
  void startMeasurement() {
    if (_isMeasuring) {
      debugPrint('SpeedTestService: Измерение уже запущено');
      return;
    }

    _isMeasuring = true;
    debugPrint('SpeedTestService: Запуск измерения скорости');

    // Первое измерение сразу
    _measureSpeed();

    // Затем каждые 2-3 секунды
    _measurementTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!_isMeasuring) {
        timer.cancel();
        return;
      }
      _measureSpeed();
    });
  }

  /// Остановить измерение скорости
  void stopMeasurement() {
    if (!_isMeasuring) {
      return;
    }

    _isMeasuring = false;
    _measurementTimer?.cancel();
    _measurementTimer = null;
    _currentSpeed = 0.0;
    _notifyListeners();
    debugPrint('SpeedTestService: Измерение остановлено');
  }

  /// Измерить текущую скорость интернета
  Future<void> _measureSpeed() async {
    try {
      // Используем несколько тестовых URL для более точного измерения
      // Можно использовать публичные сервисы или собственный API
      final testUrls = [
        'https://www.google.com/favicon.ico', // Небольшой файл для быстрого теста
        'https://httpbin.org/bytes/1048576', // 1 MB файл
      ];

      double totalSpeed = 0.0;
      int successfulTests = 0;

      for (var url in testUrls) {
        try {
          final startTime = DateTime.now();
          final response = await http.get(
            Uri.parse(url),
            headers: {
              'Cache-Control': 'no-cache',
            },
          ).timeout(const Duration(seconds: 10));

          if (response.statusCode == 200) {
            final endTime = DateTime.now();
            final duration = endTime.difference(startTime).inMilliseconds;

            if (duration > 0) {
              // Размер данных в байтах
              final dataSize = response.bodyBytes.length;
              // Скорость в Мбит/с: (байты * 8) / (время в секундах * 1,000,000)
              final speedMbps =
                  (dataSize * 8) / (duration / 1000.0) / 1000000.0;

              totalSpeed += speedMbps;
              successfulTests++;

              debugPrint(
                  'SpeedTestService: Измерение $url - ${speedMbps.toStringAsFixed(2)} Мбит/с');
            }
          }
        } catch (e) {
          debugPrint('SpeedTestService: Ошибка измерения для $url: $e');
          // Продолжаем с другим URL
        }
      }

      if (successfulTests > 0) {
        _currentSpeed = totalSpeed / successfulTests;
        // Округляем до 1 знака после запятой
        _currentSpeed = double.parse(_currentSpeed.toStringAsFixed(1));
        _notifyListeners();
        debugPrint(
            'SpeedTestService: Средняя скорость: ${_currentSpeed.toStringAsFixed(1)} Мбит/с');
      } else {
        // Если все тесты провалились, устанавливаем 0
        _currentSpeed = 0.0;
        _notifyListeners();
        debugPrint('SpeedTestService: Не удалось измерить скорость');
      }
    } catch (e) {
      debugPrint('SpeedTestService: Ошибка измерения скорости: $e');
      _currentSpeed = 0.0;
      _notifyListeners();
    }
  }

  /// Получить текущую скорость (синхронно)
  double getCurrentSpeed() {
    return _currentSpeed;
  }

  /// Очистить ресурсы
  void dispose() {
    stopMeasurement();
    _listeners.clear();
  }
}
