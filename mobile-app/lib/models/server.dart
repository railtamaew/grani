import 'dart:convert';

class Server {
  final String id;
  final String name;
  final String country;
  final String city;
  final String ip;
  final int port;
  final bool isActive;
  final int currentLoad;
  final int maxLoad;
  /// RTT до ноды (мс) с бэкенда или null, если ещё не измерен.
  final double? ping;
  final double? speed; // Скорость в Мб/сек
  /// Порт Xray на ноде (для диагностики/сортировки).
  final int? xrayPort;
  final String? flagUrl;
  final String? wireguardPublicKey;
  final String? wireguardPrivateKey;
  final List<String>? supportedProtocols;

  Server({
    required this.id,
    required this.name,
    required this.country,
    required this.city,
    required this.ip,
    required this.port,
    required this.isActive,
    required this.currentLoad,
    required this.maxLoad,
    this.ping,
    this.speed,
    this.flagUrl,
    this.wireguardPublicKey,
    this.wireguardPrivateKey,
    this.supportedProtocols,
    this.xrayPort,
  });

  factory Server.fromJson(Map<String, dynamic> json) {
    List<String>? supportedProtocols;
    if (json['supported_protocols'] != null) {
      if (json['supported_protocols'] is List) {
        supportedProtocols = List<String>.from(json['supported_protocols']);
      } else if (json['supported_protocols'] is String) {
        // Если это строка JSON, парсим её
        try {
          final parsed = jsonDecode(json['supported_protocols']) as List;
          supportedProtocols = List<String>.from(parsed);
        } catch (e) {
          supportedProtocols = [];
        }
      }
    } else {
      supportedProtocols = [];
    }

    // Оставляем только известные протоколы; список управляется из админки
    // xray — для мобильных, graniwg — для desktop (на мобильных не показывается через isImplemented)
    supportedProtocols = (supportedProtocols ?? []).where((p) =>
      p == 'xray_vless' ||
      p == 'xray_vless_ws_tls' ||
      p == 'xray_vless_grpc_tls' ||
      p == 'xray_vmess' ||
      p == 'xray_reality' ||
      p == 'graniwg'
    ).toList();
    if (supportedProtocols.isEmpty) {
      supportedProtocols = ['xray_vless'];
    }
    
    double? pingVal;
    if (json['ping_ms'] != null) {
      pingVal = (json['ping_ms'] as num).toDouble();
    } else if (json['ping'] != null) {
      pingVal = (json['ping'] as num).toDouble();
    }

    int? xrayPortVal;
    if (json['xray_port'] != null) {
      xrayPortVal = (json['xray_port'] as num).toInt();
    }

    return Server(
      id: json['id'].toString(),
      name: json['name'],
      country: json['country'],
      city: json['city'] ?? json['country'] ?? '', // Безопасная обработка city
      ip: json['ip_address'] ?? json['ip'],
      port: json['wireguard_port'] ?? json['port'] ?? 51820, // Используем wireguard_port из API
      isActive: json['is_active'] ?? true,
      currentLoad: json['current_users'] ?? json['current_load'] ?? 0,
      maxLoad: json['max_users'] ?? json['max_load'] ?? 100,
      ping: pingVal,
      speed: json['speed'] != null ? (json['speed'] as num).toDouble() : null,
      flagUrl: json['flag_url'],
      wireguardPublicKey: json['wireguard_public_key'],
      wireguardPrivateKey: json['wireguard_private_key'],
      supportedProtocols: supportedProtocols,
      xrayPort: xrayPortVal,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'country': country,
      'city': city,
      'ip_address': ip, // Используем ip_address для совместимости с fromJson
      'ip': ip,
      'port': port,
      'wireguard_port': port, // Сохраняем также как wireguard_port
      'is_active': isActive,
      'current_users': currentLoad, // Используем current_users для совместимости
      'current_load': currentLoad,
      'max_users': maxLoad, // Используем max_users для совместимости
      'max_load': maxLoad,
      'ping_ms': ping,
      'ping': ping,
      if (xrayPort != null) 'xray_port': xrayPort,
      'speed': speed,
      'flag_url': flagUrl,
      'wireguard_public_key': wireguardPublicKey,
      'wireguard_private_key': wireguardPrivateKey,
      'supported_protocols': supportedProtocols, // Добавляем supported_protocols
    };
  }

  double get loadPercentage => (currentLoad / maxLoad) * 100;

  String get displayName => '$city, $country';

  /// Копия с подставленным ping (после клиентского TCP-замера).
  Server withPing(double? newPing) {
    return Server(
      id: id,
      name: name,
      country: country,
      city: city,
      ip: ip,
      port: port,
      isActive: isActive,
      currentLoad: currentLoad,
      maxLoad: maxLoad,
      ping: newPing,
      speed: speed,
      flagUrl: flagUrl,
      wireguardPublicKey: wireguardPublicKey,
      wireguardPrivateKey: wireguardPrivateKey,
      supportedProtocols: supportedProtocols,
      xrayPort: xrayPort,
    );
  }
  
  /// Получить порт WireGuard (использует port, если wireguard_port не указан отдельно)
  int? get wireguardPort => port;
}
