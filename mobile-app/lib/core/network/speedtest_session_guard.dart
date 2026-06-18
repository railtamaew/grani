import 'dart:async';

/// Один активный speedtest (ТЗ: mutex, макс. длительность можно обернуть снаружи).
class SpeedtestSessionGuard {
  SpeedtestSessionGuard._();

  static Completer<void>? _holder;

  /// Возвращает false, если уже идёт сессия.
  static bool tryAcquire() {
    if (_holder != null) return false;
    _holder = Completer<void>();
    return true;
  }

  static void release() {
    _holder?.complete();
    _holder = null;
  }

  static bool get hasActiveSession => _holder != null;
}
