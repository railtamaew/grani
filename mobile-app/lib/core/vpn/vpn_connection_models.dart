/// Модели прогресса и сценария подключения VPN (вынесены из [VpnService] для читаемости).
library;

/// Прогресс подключения VPN
enum ConnectionProgress {
  checkingPermissions(0, 'проверка разрешений...'),
  validatingToken(10, 'проверка авторизации...'),
  autoSelectingServer(15, 'выбор сервера...'),
  registeringDevice(20, 'регистрация устройства...'),
  gettingConfig(30, 'получение конфигурации...'),
  parsingConfig(40, 'обработка конфигурации...'),
  creatingTun(50, 'создание VPN интерфейса...'),
  startingProtocol(60, 'запуск протокола...'),
  /// Пока этот этап активен, [VpnConnectionState] остаётся `connecting` — не `connected`.
  verifyingConnection(80, 'проверка трафика…'),
  connected(100, 'подключено');

  final int percent;
  final String message;
  const ConnectionProgress(this.percent, this.message);
}

/// Тип текущего сценария подключения для UX и диагностики.
enum ConnectionFlowType {
  unknown,
  coldCreateConfig,
  warmCacheReconnect,
}

/// Контекст одной попытки подключения: таймеры и данные этапов для connect().
class ConnectAttemptContext {
  final Stopwatch stageStopwatch = Stopwatch()..start();
  final Stopwatch connectionStopwatch = Stopwatch()..start();
  String? networkType;
  String? currentStage;
}
