import 'package:flutter/foundation.dart';

import '../../core/vpn/vpn_log_redaction.dart';
import 'models/xray_config.dart';

/// Главный класс для работы с Xray протоколом
class XrayProtocol {
  XrayConfig? _config;
  bool _isConnected = false;
  
  /// Инициализирует протокол с конфигурацией
  void initialize(String configString) {
    try {
      _config = XrayConfig.fromString(configString);
    } catch (e) {
      debugPrint('Ошибка парсинга конфигурации Xray: $e');
      rethrow;
    }
  }
  
  /// Инициализирует протокол с JSON конфигурацией
  void initializeFromJson(Map<String, dynamic> json) {
    try {
      _config = XrayConfig.fromJson(json);
    } catch (e) {
      debugPrint('Ошибка парсинга JSON конфигурации Xray: $e');
      rethrow;
    }
  }
  
  /// Подключается к Xray серверу
  /// 
  /// ВАЖНО: Реальное подключение происходит через NativeVpnService.connect() в VpnService._applyXrayConfig()
  /// Этот метод только проверяет инициализацию и устанавливает статус.
  /// Нативный VPN сервис обрабатывает реальное подключение через libXray.
  Future<bool> connect({
    Function(String)? onError,
    Function()? onConnected,
    Function()? onDisconnected,
  }) async {
    if (_config == null) {
      throw StateError('Конфигурация не инициализирована');
    }
    
    try {
      debugPrint('XrayProtocol.connect: Начало подключения');
      debugPrint('XrayProtocol.connect: Сервер: ${_config!.address}:${_config!.port}');
      debugPrint('XrayProtocol.connect: Протокол: ${_config!.protocol}');
      debugPrint(
        'XrayProtocol.connect: client_id (redacted): ${VpnLogRedaction.redactSensitiveJson(_config!.uuid)}',
      );
      debugPrint('XrayProtocol.connect: Security: ${_config!.security}');
      debugPrint('XrayProtocol.connect: Network: ${_config!.network}');
      
      // Реальное подключение происходит через NativeVpnService.connect() в VpnService._applyXrayConfig()
      // Этот метод только проверяет, что конфигурация готова к подключению
      // Статус подключения будет установлен после успешного вызова NativeVpnService.connect()
      
      debugPrint('XrayProtocol.connect: Конфигурация готова к подключению');
      debugPrint('XrayProtocol.connect: Реальное подключение будет выполнено через NativeVpnService');
      
      // Возвращаем true, так как конфигурация валидна
      // Реальное подключение произойдет в _applyXrayConfig() через NativeVpnService
      return true;
    } catch (e) {
      debugPrint('Ошибка подключения Xray: $e');
      onError?.call(e.toString());
      return false;
    }
  }
  
  /// Отключается от сервера
  Future<void> disconnect() async {
    try {
      debugPrint('Отключение от Xray сервера');
      _isConnected = false;
    } catch (e) {
      debugPrint('Ошибка отключения Xray: $e');
    }
  }
  
  /// Проверяет, подключен ли протокол
  bool get isConnected => _isConnected;
  
  /// Устанавливает статус подключения (вызывается после успешного подключения через NativeVpnService)
  void setConnected(bool connected) {
    _isConnected = connected;
    debugPrint('XrayProtocol.setConnected: Статус подключения установлен в $connected');
  }
  
  /// Получает текущую конфигурацию
  XrayConfig? get config => _config;
  
  /// Генерирует строку конфигурации для внешнего клиента
  String generateConfigString() {
    if (_config == null) {
      throw StateError('Конфигурация не инициализирована');
    }
    
    return _config!.toConfigString();
  }
  
  /// Генерирует JSON конфигурацию
  Map<String, dynamic> generateJsonConfig() {
    if (_config == null) {
      throw StateError('Конфигурация не инициализирована');
    }
    
    return _config!.toJson();
  }
}

