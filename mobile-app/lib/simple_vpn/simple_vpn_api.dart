import 'package:dio/dio.dart';

import '../core/api/api_client.dart';
import '../core/api/endpoint_router.dart';

class SimpleVpnAccessRequiredException implements Exception {
  const SimpleVpnAccessRequiredException(
      [this.message = 'Требуется активная подписка']);

  final String message;

  @override
  String toString() => message;
}

bool _isPaymentRequired(Object error) {
  return error is DioException && error.response?.statusCode == 402;
}

String _accessRequiredMessage(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['detail'] != null) return data['detail'].toString();
    final message = error.message;
    if (message != null && message.isNotEmpty) return message;
  }
  return 'Требуется активная подписка';
}

Never _rethrowAccessRequired(Object error) {
  if (_isPaymentRequired(error)) {
    throw SimpleVpnAccessRequiredException(_accessRequiredMessage(error));
  }
  throw error;
}

class SimpleVpnServer {
  SimpleVpnServer({
    required this.id,
    required this.name,
    required this.country,
    required this.city,
    required this.ipAddress,
    required this.wireguardPort,
    required this.currentUsers,
    required this.maxUsers,
    this.countryCode = '',
    this.cityCode = '',
    this.countryLocalized = const <String, String>{},
    this.cityLocalized = const <String, String>{},
    this.pingMs,
  });

  final int id;
  final String name;
  final String country;
  final String city;
  final String countryCode;
  final String cityCode;
  final Map<String, String> countryLocalized;
  final Map<String, String> cityLocalized;
  final String ipAddress;
  final int wireguardPort;
  final int currentUsers;
  final int maxUsers;
  final double? pingMs;

  String get label => city.isNotEmpty ? '$city, $country' : country;

  String localizedCountry(String languageCode) =>
      _localizedValue(countryLocalized, languageCode, country);

  String localizedCity(String languageCode) =>
      _localizedValue(cityLocalized, languageCode, city);

  factory SimpleVpnServer.fromJson(Map<String, dynamic> json) {
    return SimpleVpnServer(
      id: (json['id'] as num?)?.toInt() ??
          int.tryParse(json['id']?.toString() ?? '') ??
          0,
      name: json['name']?.toString() ?? 'GRANI VPN',
      country: json['country']?.toString() ?? '',
      city: json['city']?.toString() ?? '',
      countryCode: json['country_code']?.toString() ?? '',
      cityCode: json['city_code']?.toString() ?? '',
      countryLocalized: _parseLocalizedMap(json['country_localized']),
      cityLocalized: _parseLocalizedMap(json['city_localized']),
      ipAddress: (json['ip_address'] ?? json['ip'])?.toString() ?? '',
      wireguardPort: (json['wireguard_port'] as num?)?.toInt() ??
          (json['port'] as num?)?.toInt() ??
          51820,
      currentUsers: (json['current_users'] as num?)?.toInt() ?? 0,
      maxUsers: (json['max_users'] as num?)?.toInt() ?? 100,
      pingMs:
          json['ping_ms'] is num ? (json['ping_ms'] as num).toDouble() : null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'country': country,
        'city': city,
        if (countryCode.isNotEmpty) 'country_code': countryCode,
        if (cityCode.isNotEmpty) 'city_code': cityCode,
        if (countryLocalized.isNotEmpty) 'country_localized': countryLocalized,
        if (cityLocalized.isNotEmpty) 'city_localized': cityLocalized,
        'ip_address': ipAddress,
        'wireguard_port': wireguardPort,
        'current_users': currentUsers,
        'max_users': maxUsers,
        if (pingMs != null) 'ping_ms': pingMs,
      };
}

Map<String, String> _parseLocalizedMap(Object? raw) {
  if (raw is! Map) return const <String, String>{};
  final result = <String, String>{};
  raw.forEach((key, value) {
    final locale = key?.toString().trim().toLowerCase() ?? '';
    final text = value?.toString().trim() ?? '';
    if (locale.isNotEmpty && text.isNotEmpty) {
      result[locale] = text;
    }
  });
  return Map<String, String>.unmodifiable(result);
}

String _localizedValue(
  Map<String, String> values,
  String languageCode,
  String fallback,
) {
  final lang = languageCode.trim().toLowerCase();
  return values[lang] ??
      values[lang.split('-').first] ??
      values['en'] ??
      fallback;
}

class SimpleVpnProtocol {
  SimpleVpnProtocol({
    required this.id,
    required this.engine,
    required this.status,
    required this.role,
  });

  final String id;
  final String engine;
  final String status;
  final String role;

  String get label {
    if (id == 'vless_ws') return 'VLESS WS';
    if (id == 'hysteria2') return 'Hysteria 2';
    if (id == 'graniwg') return 'WireGuard obf';
    return id;
  }

  factory SimpleVpnProtocol.fromJson(Map<String, dynamic> json) {
    return SimpleVpnProtocol(
      id: json['id']?.toString() ?? 'graniwg',
      engine: json['engine']?.toString() ?? 'amneziawg',
      status: json['status']?.toString() ?? 'development',
      role: json['role']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'engine': engine,
        'status': status,
        'role': role,
      };
}

class SimpleVpnConfig {
  SimpleVpnConfig({
    required this.protocol,
    required this.configType,
    required this.engine,
    required this.serverName,
    required this.server,
    required this.configRevision,
    required this.config,
    required this.jsonConfig,
  });

  final String protocol;
  final String configType;
  final String engine;
  final String serverName;
  final SimpleVpnServer? server;
  final String configRevision;
  final String config;
  final Map<String, dynamic> jsonConfig;

  factory SimpleVpnConfig.fromJson(Map<String, dynamic> json) {
    final server = json['server'];
    final serverMap =
        server is Map ? Map<String, dynamic>.from(server) : <String, dynamic>{};
    final rawConfig = json['json_config'];
    final parsedServer =
        serverMap.isEmpty ? null : SimpleVpnServer.fromJson(serverMap);
    return SimpleVpnConfig(
      protocol: json['protocol']?.toString() ?? 'graniwg',
      configType: json['config_type']?.toString() ?? 'amneziawg',
      engine: json['engine']?.toString() ?? 'amneziawg',
      serverName:
          serverMap['name']?.toString() ?? parsedServer?.name ?? 'GRANI VPN',
      server: parsedServer,
      configRevision: json['config_revision']?.toString() ?? 'simple-vpn',
      config: json['config']?.toString() ?? '',
      jsonConfig: rawConfig is Map
          ? Map<String, dynamic>.from(rawConfig)
          : <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'protocol': protocol,
        'config_type': configType,
        'engine': engine,
        'server': server?.toJson() ?? <String, dynamic>{'name': serverName},
        'config_revision': configRevision,
        'config': config,
        'json_config': jsonConfig,
      };
}

class SimpleVpnStartResult {
  SimpleVpnStartResult({required this.sessionId, required this.status});

  final String sessionId;
  final String status;

  factory SimpleVpnStartResult.fromJson(Map<String, dynamic> json) {
    return SimpleVpnStartResult(
      sessionId: json['session_id']?.toString() ?? '',
      status: json['status']?.toString() ?? 'starting',
    );
  }
}

class SimpleVpnVerifyResult {
  SimpleVpnVerifyResult({
    required this.verified,
    required this.status,
    this.serverId,
    this.vpnIp,
    this.handshakeAgeSec,
    this.rxBytes,
    this.txBytes,
    this.reason,
  });

  final bool verified;
  final String status;
  final int? serverId;
  final String? vpnIp;
  final int? handshakeAgeSec;
  final int? rxBytes;
  final int? txBytes;
  final String? reason;

  factory SimpleVpnVerifyResult.fromJson(Map<String, dynamic> json) {
    return SimpleVpnVerifyResult(
      verified: json['verified'] == true,
      status: json['status']?.toString() ?? 'unverified',
      serverId: (json['server_id'] as num?)?.toInt(),
      vpnIp: json['vpn_ip']?.toString(),
      handshakeAgeSec: (json['handshake_age_sec'] as num?)?.toInt(),
      rxBytes: (json['rx_bytes'] as num?)?.toInt(),
      txBytes: (json['tx_bytes'] as num?)?.toInt(),
      reason: json['reason']?.toString(),
    );
  }
}

class SimpleVpnApi {
  SimpleVpnApi({ApiClient? apiClient}) : _apiClient = apiClient ?? ApiClient();

  final ApiClient _apiClient;

  static List<SimpleVpnProtocol> get displayProtocols => <SimpleVpnProtocol>[
        SimpleVpnProtocol(
            id: 'vless_ws', engine: 'xray', status: 'active', role: 'fallback'),
        SimpleVpnProtocol(
            id: 'hysteria2',
            engine: 'hysteria2',
            status: 'runtime_pending',
            role: 'server_ready'),
        SimpleVpnProtocol(
            id: 'graniwg',
            engine: 'amneziawg',
            status: 'active',
            role: 'primary'),
      ];

  Future<List<SimpleVpnServer>> fetchServers() async {
    try {
      final response = await _apiClient.get(
        '/simple-vpn/servers',
        requestKind: RequestKind.vpnControl,
        options: Options(receiveTimeout: const Duration(seconds: 8)),
      );
      final data = _asMap(response.data);
      final raw = data['servers'];
      if (raw is! List) return <SimpleVpnServer>[];
      return raw
          .whereType<Map>()
          .map((item) =>
              SimpleVpnServer.fromJson(Map<String, dynamic>.from(item)))
          .where((server) => server.id > 0)
          .toList(growable: false);
    } catch (error) {
      _rethrowAccessRequired(error);
    }
  }

  Future<List<SimpleVpnProtocol>> fetchProtocols() async {
    try {
      final response = await _apiClient.get(
        '/simple-vpn/protocols',
        requestKind: RequestKind.vpnControl,
        options: Options(receiveTimeout: const Duration(seconds: 8)),
      );
      final data = _asMap(response.data);
      final raw = data['protocols'];
      if (raw is! List) {
        return displayProtocols;
      }
      final protocols = raw
          .whereType<Map>()
          .map((item) =>
              SimpleVpnProtocol.fromJson(Map<String, dynamic>.from(item)))
          .where((protocol) =>
              protocol.id == 'vless_ws' ||
              protocol.id == 'hysteria2' ||
              protocol.id == 'graniwg')
          .toList(growable: false);
      final merged = <String, SimpleVpnProtocol>{
        for (final protocol in protocols) protocol.id: protocol,
      };
      return displayProtocols
          .map((fallback) => merged[fallback.id] ?? fallback)
          .toList(growable: false);
    } catch (error) {
      _rethrowAccessRequired(error);
    }
  }

  Future<SimpleVpnConfig> fetchConfig(
      {int? serverId, String? deviceId, String? protocol}) async {
    try {
      final response = await _apiClient.get(
        '/simple-vpn/config',
        queryParameters: <String, dynamic>{
          if (serverId != null && serverId > 0) 'server_id': serverId,
          if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
          if (protocol != null && protocol.isNotEmpty) 'protocol': protocol,
        },
        requestKind: RequestKind.vpnControl,
        options: Options(receiveTimeout: const Duration(seconds: 45)),
      );
      final data = _asMap(response.data);
      return SimpleVpnConfig.fromJson(data);
    } catch (error) {
      _rethrowAccessRequired(error);
    }
  }

  Future<SimpleVpnStartResult> startSession(
      {String? protocol, String? deviceId, int? serverId}) async {
    try {
      final response = await _apiClient.post(
        '/simple-vpn/session/start',
        data: <String, dynamic>{
          if (protocol != null && protocol.isNotEmpty) 'protocol': protocol,
          if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
          if (serverId != null && serverId > 0) 'server_id': serverId,
        },
        requestKind: RequestKind.vpnControl,
        options: Options(receiveTimeout: const Duration(seconds: 8)),
      );
      return SimpleVpnStartResult.fromJson(_asMap(response.data));
    } catch (error) {
      _rethrowAccessRequired(error);
    }
  }

  Future<SimpleVpnVerifyResult> verifySession({
    String? sessionId,
    String? deviceId,
    int? serverId,
    String? protocol,
  }) async {
    try {
      final response = await _apiClient.post(
        '/simple-vpn/session/verify',
        data: <String, dynamic>{
          if (sessionId != null && sessionId.isNotEmpty)
            'session_id': sessionId,
          if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
          if (serverId != null && serverId > 0) 'server_id': serverId,
          if (protocol != null && protocol.isNotEmpty) 'protocol': protocol,
        },
        requestKind: RequestKind.vpnControl,
        options: Options(receiveTimeout: const Duration(seconds: 12)),
      );
      return SimpleVpnVerifyResult.fromJson(_asMap(response.data));
    } catch (error) {
      _rethrowAccessRequired(error);
    }
  }

  Future<void> stopSession(
      {String? sessionId, String? reason, String? deviceId}) async {
    await _apiClient.post(
      '/simple-vpn/session/stop',
      data: <String, dynamic>{
        if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
        if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
      },
      requestKind: RequestKind.vpnControl,
      options: Options(receiveTimeout: const Duration(seconds: 5)),
    );
  }

  Future<void> log({
    required String event,
    String level = 'info',
    String? sessionId,
    String? deviceId,
    Map<String, dynamic>? details,
  }) async {
    try {
      await _apiClient.post(
        '/simple-vpn/logs',
        data: <String, dynamic>{
          'event': event,
          'level': level,
          if (sessionId != null && sessionId.isNotEmpty)
            'session_id': sessionId,
          if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
          if (details != null && details.isNotEmpty) 'details': details,
        },
        requestKind: RequestKind.logging,
        options: Options(receiveTimeout: const Duration(seconds: 5)),
      );
    } catch (_) {
      // Logging must never control the simple VPN path.
    }
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return <String, dynamic>{};
  }
}
