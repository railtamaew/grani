import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/simple_logger.dart';

void main() {
  // Инициализация логгера
  final logger = SimpleLogger();
  logger.initialize();
  logger.info('App', 'Приложение запущено');
  
  runApp(const MinimalVpnApp());
}

class MinimalVpnApp extends StatelessWidget {
  const MinimalVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VPN Minimal Test',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const VpnTestScreen(),
    );
  }
}

class VpnTestScreen extends StatefulWidget {
  const VpnTestScreen({super.key});

  @override
  State<VpnTestScreen> createState() => _VpnTestScreenState();
}

class _VpnTestScreenState extends State<VpnTestScreen> {
  static const MethodChannel _channel = MethodChannel('com.granivpn.test/vpn');
  
  final SimpleLogger _logger = SimpleLogger();
  
  bool _isConnected = false;
  bool _isConnecting = false;
  String _status = 'Отключено';
  String _logs = '';

  void _addLog(String message) {
    setState(() {
      _logs += '${DateTime.now().toString().substring(11, 19)}: $message\n';
    });
    // Отправляем лог на сервер
    _logger.info('VPN', message);
  }

  Future<void> _connect() async {
    if (_isConnected || _isConnecting) return;
    
    setState(() {
      _isConnecting = true;
      _status = 'Подключение...';
    });
    _addLog('Начало подключения...');
    _logger.info('VPN', 'Начало подключения VPN');

    try {
      // Получаем тестовую конфигурацию WireGuard
      final config = _getTestWireGuardConfig();
      _addLog('Конфигурация подготовлена (${config.length} символов)');
      _logger.debug('VPN', 'Конфигурация подготовлена', extra: {'config_length': config.length});
      
      final result = await _channel.invokeMethod<bool>('connect', {
        'config': config,
      });

      if (result == true) {
        setState(() {
          _isConnected = true;
          _isConnecting = false;
          _status = 'Подключено';
        });
        _addLog('✅ Подключение успешно');
        _logger.info('VPN', 'VPN подключен успешно');
      } else {
        setState(() {
          _isConnected = false;
          _isConnecting = false;
          _status = 'Ошибка подключения';
        });
        _addLog('❌ Подключение не удалось');
        _logger.error('VPN', 'Подключение не удалось', extra: {'result': result});
      }
    } catch (e) {
      setState(() {
        _isConnected = false;
        _isConnecting = false;
        _status = 'Ошибка: $e';
      });
      _addLog('❌ Ошибка: $e');
      _logger.error('VPN', 'Ошибка подключения', extra: {'error': e.toString()});
      // Принудительная отправка логов при ошибке
      _logger.flush();
    }
  }

  Future<void> _disconnect() async {
    if (!_isConnected) return;

    setState(() {
      _isConnecting = true;
      _status = 'Отключение...';
    });
    _addLog('Начало отключения...');
    _logger.info('VPN', 'Начало отключения VPN');

    try {
      final result = await _channel.invokeMethod<bool>('disconnect');

      if (result == true) {
        setState(() {
          _isConnected = false;
          _isConnecting = false;
          _status = 'Отключено';
        });
        _addLog('✅ Отключение успешно');
        _logger.info('VPN', 'VPN отключен успешно');
      } else {
        setState(() {
          _isConnecting = false;
        });
        _addLog('❌ Отключение не удалось');
        _logger.warn('VPN', 'Отключение не удалось', extra: {'result': result});
      }
    } catch (e) {
      setState(() {
        _isConnecting = false;
      });
      _addLog('❌ Ошибка отключения: $e');
      _logger.error('VPN', 'Ошибка отключения', extra: {'error': e.toString()});
      // Принудительная отправка логов при ошибке
      _logger.flush();
    }
  }

  String _getTestWireGuardConfig() {
    // Тестовая конфигурация WireGuard с реальным сервером
    // TODO: Заменить на реальные ключи из основного проекта
    return '''[Interface]
PrivateKey = YOUR_PRIVATE_KEY_HERE
Address = 10.0.0.2/32
DNS = 8.8.8.8, 8.8.4.4
MTU = 1420

[Peer]
PublicKey = SERVER_PUBLIC_KEY_HERE
Endpoint = 45.12.132.94:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25''';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('VPN Minimal Test'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Статус
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Text(
                      _status,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isConnected
                                ? Colors.green
                                : _isConnecting
                                    ? Colors.orange
                                    : Colors.grey,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _isConnected 
                              ? 'Подключено' 
                              : _isConnecting 
                                  ? 'Подключение...' 
                                  : 'Отключено',
                          style: const TextStyle(fontSize: 16),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // Кнопки
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: _isConnecting ? null : _connect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    minimumSize: const Size(150, 50),
                  ),
                  child: const Text('Подключиться'),
                ),
                ElevatedButton(
                  onPressed: (!_isConnected || _isConnecting) ? null : _disconnect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    minimumSize: const Size(150, 50),
                  ),
                  child: const Text('Отключиться'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Логи
            const Text(
              'Логи:',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: Text(
                      _logs.isEmpty ? 'Логи появятся здесь...' : _logs,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
