import 'dart:convert';

/// Конфигурация Xray протокола
class XrayConfig {
  final String uuid;
  final String address;
  final int port;
  final String protocol; // vless, vmess
  final String encryption; // none для vless
  final String security; // tls, none
  final String network; // ws, tcp
  final String? host; // для WebSocket
  final String? path; // для WebSocket
  final String? sni; // Server Name Indication для TLS
  final String? remark; // Название сервера

  // Поля для REALITY
  final String? realityPublicKey; // pbk - публичный ключ REALITY
  final String? realityShortId; // sid - короткий ID REALITY
  final String? realitySpx; // spx - путь для REALITY
  final String? realityFp; // fp - fingerprint для REALITY (например, "chrome")

  XrayConfig({
    required this.uuid,
    required this.address,
    required this.port,
    required this.protocol,
    this.encryption = 'none',
    this.security = 'tls',
    this.network = 'ws',
    this.host,
    this.path,
    this.sni,
    this.remark,
    this.realityPublicKey,
    this.realityShortId,
    this.realitySpx,
    this.realityFp,
  });

  static String? _normalizeParam(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final lower = trimmed.toLowerCase();
    if (lower == 'none' || lower == 'null') {
      return null;
    }
    return trimmed;
  }

  static String? _normalizeDynamicParam(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      return _normalizeParam(value);
    }
    return value.toString();
  }

  static String? _normalizeSecurity(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) {
        return null;
      }
      return trimmed.toLowerCase();
    }
    return value.toString().toLowerCase();
  }

  /// Парсит конфигурацию из строки (VLESS/VMess URL)
  factory XrayConfig.fromString(String configString) {
    try {
      final trimmedConfig = configString.trim();
      // Если конфигурация многострочная, берем только первую строку с URL
      final firstLine = trimmedConfig.split(RegExp(r'[\r\n]')).first;

      // Извлекаем remark из fragment (#...), если он есть
      String? remark;
      String configWithoutFragment = firstLine;
      final fragmentIndex = firstLine.indexOf('#');
      if (fragmentIndex != -1) {
        configWithoutFragment = firstLine.substring(0, fragmentIndex);
        final fragment = firstLine.substring(fragmentIndex + 1);
        if (fragment.isNotEmpty) {
          try {
            remark = Uri.decodeComponent(fragment);
          } catch (_) {
            remark = fragment;
          }
        }
      }

      // Удаляем префикс протокола
      String cleanConfig = configWithoutFragment;
      if (configWithoutFragment.startsWith('vless://') ||
          configWithoutFragment.startsWith('vmess://')) {
        cleanConfig = configWithoutFragment
            .substring(configWithoutFragment.indexOf('://') + 3);
      }

      // Определяем, это REALITY или нет
      final isReality = configWithoutFragment.contains('security=reality') ||
          configWithoutFragment.contains('&security=reality');

      // Извлекаем UUID (до @)
      final atIndex = cleanConfig.indexOf('@');
      if (atIndex == -1) {
        throw FormatException(
            'Неверный формат конфигурации Xray: отсутствует @');
      }

      final uuid = cleanConfig.substring(0, atIndex);
      final rest = cleanConfig.substring(atIndex + 1);

      // Разбираем остальную часть
      final parts = rest.split('?');
      if (parts.isEmpty) {
        throw FormatException(
            'Неверный формат конфигурации Xray: отсутствует адрес и порт');
      }

      final addressPort = parts[0].split(':');
      if (addressPort.length < 2) {
        throw FormatException(
            'Неверный формат конфигурации Xray: отсутствует порт');
      }

      final address = addressPort[0];
      final port = int.parse(addressPort[1]);

      // Определяем протокол
      final protocol =
          configWithoutFragment.startsWith('vmess://') ? 'vmess' : 'vless';

      // Парсим параметры
      String? host;
      String? path;
      String? security;
      String? network;

      // Для REALITY используем TCP вместо WS
      if (isReality) {
        network = 'tcp';
      }
      String? sni;
      String? realityPublicKey;
      String? realityShortId;
      String? realitySpx;
      String? realityFp;

      if (parts.length > 1) {
        // Используем Uri.splitQueryString для правильного декодирования параметров
        // Это автоматически декодирует %2F в /
        final queryString = parts[1];
        Map<String, String> params;
        try {
          params = Uri.splitQueryString(queryString);
        } catch (e) {
          // Fallback для некорректно закодированных параметров
          String safeDecode(String value) {
            final normalized = value.replaceAll('+', ' ');
            try {
              return Uri.decodeComponent(normalized);
            } catch (_) {
              return normalized;
            }
          }

          params = <String, String>{};
          for (final pair in queryString.split('&')) {
            if (pair.isEmpty) {
              continue;
            }
            final eqIndex = pair.indexOf('=');
            final rawKey = eqIndex == -1 ? pair : pair.substring(0, eqIndex);
            final rawValue = eqIndex == -1 ? '' : pair.substring(eqIndex + 1);
            params[safeDecode(rawKey)] = safeDecode(rawValue);
          }
        }
        security = params['security'] ?? 'tls';
        network = network ?? (params['type'] ?? 'ws');

        host = _normalizeParam(params['host']);
        path = _normalizeParam(params[
            'path']); // Uri.splitQueryString автоматически декодирует %2F в /
        sni = _normalizeParam(params['sni']);
        // REALITY параметры
        realityPublicKey = params['pbk'];
        realityShortId = params['sid'];
        realitySpx = params['spx'];
        realityFp = params['fp'];
      }

      return XrayConfig(
        uuid: uuid,
        address: address,
        port: port,
        protocol: protocol,
        security: security ?? 'tls',
        network: network ?? 'ws',
        host: host,
        path: path,
        sni: sni,
        remark: remark,
        realityPublicKey: realityPublicKey,
        realityShortId: realityShortId,
        realitySpx: realitySpx,
        realityFp: realityFp,
      );
    } catch (e) {
      throw FormatException('Ошибка парсинга конфигурации Xray: $e');
    }
  }

  /// Создает конфигурацию из JSON
  factory XrayConfig.fromJson(Map<String, dynamic> json) {
    // Обрабатываем port - может быть int или String
    int portValue;
    final portData = json['port'];
    if (portData is int) {
      portValue = portData;
    } else if (portData is String) {
      portValue = int.parse(portData);
    } else {
      throw FormatException(
          'Порт должен быть int или String, получен: ${portData.runtimeType}');
    }

    // Обрабатываем v - может быть int или String
    String? vValue;
    final vData = json['v'];
    if (vData is int) {
      vValue = vData.toString();
    } else if (vData is String) {
      vValue = vData;
    }

    // Определяем протокол:
    // - Если есть pbk (REALITY) -> VLESS
    // - Если tls == "reality" -> VLESS
    // - Если v == "2" и aid > 0 -> VMESS
    // - Если v == "2" и aid отсутствует/0 -> VLESS (vless JSON часто содержит v=2, aid=0)
    // - По умолчанию VLESS
    final hasReality = json['pbk'] != null || json['tls'] == 'reality';
    int? aidValue;
    final aidData = json['aid'];
    if (aidData is int) {
      aidValue = aidData;
    } else if (aidData is String) {
      aidValue = int.tryParse(aidData);
    }

    final protocolHint = json['protocol'] as String?;
    final isVmess = vValue == '2' && (aidValue != null && aidValue > 0);

    final protocolValue = (protocolHint == 'vless' || protocolHint == 'vmess')
        ? protocolHint!
        : (hasReality ? 'vless' : (isVmess ? 'vmess' : 'vless'));

    final rawEncryption = json['scy'] as String? ?? 'none';
    final normalizedEncryption = protocolValue == 'vless' &&
            (rawEncryption == 'auto' || rawEncryption.isEmpty)
        ? 'none'
        : rawEncryption;

    return XrayConfig(
      uuid: json['id'] as String,
      address: json['add'] as String,
      port: portValue,
      protocol: protocolValue,
      encryption: normalizedEncryption,
      security: _normalizeSecurity(json['tls']) ?? 'tls',
      network: _normalizeDynamicParam(json['net']) ?? 'ws',
      host: _normalizeDynamicParam(json['host']),
      path: _normalizeDynamicParam(json['path']),
      sni: _normalizeDynamicParam(json['sni']),
      remark: _normalizeDynamicParam(json['ps']),
      realityPublicKey: _normalizeDynamicParam(json['pbk']),
      realityShortId: _normalizeDynamicParam(json['sid']),
      realitySpx: _normalizeDynamicParam(json['spx']),
      realityFp: _normalizeDynamicParam(json['fp']),
    );
  }

  /// Преобразует в JSON формат
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      // Для VMESS добавляем поле "v", для VLESS не добавляем (не включаем пустую строку)
      if (protocol == 'vmess') 'v': '2',
      'ps': remark ?? 'GRANI',
      'add': address,
      'port': port.toString(),
      'id': uuid,
      'aid': '0',
      'scy': encryption,
      'net': network,
      'type': 'none',
      'host': host ?? address,
      'path': path ?? '/ray',
      'tls': security,
      'sni': sni ?? address,
      'alpn': '',
    };

    // Добавляем REALITY параметры, если они есть
    if (realityPublicKey != null && realityPublicKey!.isNotEmpty) {
      json['pbk'] = realityPublicKey!;
    }
    if (realityShortId != null && realityShortId!.isNotEmpty) {
      json['sid'] = realityShortId!;
    }
    if (realitySpx != null && realitySpx!.isNotEmpty) {
      json['spx'] = realitySpx!;
    }
    if (realityFp != null && realityFp!.isNotEmpty) {
      json['fp'] = realityFp!;
    }

    return json;
  }

  /// Генерирует строку конфигурации (VLESS/VMess URL)
  String toConfigString() {
    final params = <String, String>{};

    if (encryption != 'none') {
      params['encryption'] = encryption;
    }

    params['security'] = security;
    params['type'] = network;

    if (host != null) {
      params['host'] = host!;
    }

    if (path != null) {
      params['path'] = path!;
    }

    if (sni != null) {
      params['sni'] = sni!;
    }

    // Добавляем REALITY параметры, если они есть
    if (realityPublicKey != null) {
      params['pbk'] = realityPublicKey!;
    }
    if (realityShortId != null) {
      params['sid'] = realityShortId!;
    }
    if (realitySpx != null) {
      params['spx'] = realitySpx!;
    }
    if (realityFp != null) {
      params['fp'] = realityFp!;
    }

    final queryString = Uri(queryParameters: params).query;
    final url = '$protocol://$uuid@$address:$port?$queryString';

    if (remark != null) {
      return '$url#${Uri.encodeComponent(remark!)}';
    }

    return url;
  }

  /// Преобразует конфигурацию в формат sing-box JSON
  ///
  /// Sing-box использует другой формат конфигурации, чем Xray.
  /// Этот метод преобразует XrayConfig в формат, который понимает sing-box.
  String toSingBoxJsonConfig() {
    final json = <String, dynamic>{};

    // Логирование
    json['log'] = {'level': 'warn'};

    // DNS конфигурация
    // ВАЖНО: sing-box ожидает массив объектов с полем 'address', а не массив строк
    json['dns'] = {
      'servers': [
        {'address': '8.8.8.8'},
        {'address': '8.8.4.4'},
        {'address': '1.1.1.1'}
      ]
    };

    // Inbounds - TUN интерфейс для VPN
    // sing-box создаст TUN через PlatformInterface на основе этой конфигурации
    // ВАЖНО: Для sing-box параметры TUN должны быть на верхнем уровне, БЕЗ обертки "settings"
    // ВАЖНО: Поле inet4_route не поддерживается sing-box, используем auto_route вместо этого
    // ВАЖНО: Поле dns_address не поддерживается в TUN inbound, DNS указывается только в секции dns
    json['inbounds'] = [
      {
        'type': 'tun',
        'tag': 'tun-in',
        'mtu': 1420,
        'inet4_address': ['172.19.0.1/30'],
        'auto_route': true, // ✅ auto_route автоматически создает маршруты
        'strict_route': false,
      }
    ];

    // Outbounds
    // ВАЖНО: sing-box НЕ использует формат Xray с settings.vnext!
    // Параметры должны быть на верхнем уровне outbound
    final outbounds = <Map<String, dynamic>>[];
    final outbound = <String, dynamic>{
      'tag': 'proxy',
    };

    // Определяем тип протокола для sing-box
    if (protocol == 'vless') {
      outbound['type'] = 'vless';
      // ✅ ПРАВИЛЬНЫЙ формат для sing-box (БЕЗ settings.vnext)
      outbound['server'] = address;
      outbound['server_port'] = port;
      outbound['uuid'] = uuid;
      outbound['flow'] = '';
    } else if (protocol == 'vmess') {
      outbound['type'] = 'vmess';
      // ✅ ПРАВИЛЬНЫЙ формат для sing-box (БЕЗ settings.vnext)
      outbound['server'] = address;
      outbound['server_port'] = port;
      outbound['uuid'] = uuid;
      outbound['alter_id'] = 0;
    } else {
      throw ArgumentError('Неподдерживаемый протокол для sing-box: $protocol');
    }

    // TLS/Reality settings - формат sing-box
    if (security == 'tls') {
      outbound['tls'] = {
        'enabled': true,
        'server_name': sni ?? address,
        'insecure': false,
      };
    } else if (security == 'reality') {
      if (realityPublicKey == null || realityPublicKey!.isEmpty) {
        throw StateError('REALITY требует realityPublicKey (pbk)');
      }
      final tlsConfig = <String, dynamic>{
        'enabled': true,
        'server_name': sni ?? address,
        'reality': {
          'public_key': realityPublicKey!,
          'short_id': realityShortId ?? '',
        },
      };
      // Добавляем uTLS fingerprint если указан
      if (realityFp != null && realityFp!.isNotEmpty) {
        tlsConfig['utls'] = {
          'enabled': true,
          'fingerprint': realityFp!,
        };
      }
      outbound['tls'] = tlsConfig;
    }

    // Transport settings - формат sing-box
    if (network == 'ws') {
      outbound['transport'] = {
        'type': 'ws',
        'path': path ?? '/',
        'headers': {
          'Host': host ?? address,
        },
      };
    }
    outbounds.add(outbound);

    // Direct outbound для DNS
    outbounds.add({
      'type': 'direct',
      'tag': 'direct',
    });

    json['outbounds'] = outbounds;

    // ВАЖНО: libbox (sing-box) НЕ поддерживает route.rules с типом "field"
    // Маршрутизация происходит автоматически через auto_route в TUN inbound
    // Все пакеты из TUN автоматически идут через первый outbound (proxy)
    // Поэтому секция route НЕ добавляется

    return jsonEncode(json);
  }

  /// Преобразует конфигурацию в нативный формат XRay-core (не sing-box)
  ///
  /// XRay-core использует другой формат конфигурации, чем sing-box.
  /// Этот метод преобразует XrayConfig в формат, который понимает libXray.
  String toXrayNativeJsonConfig() {
    final normalizedHost = _normalizeParam(host) ?? address;
    final normalizedPath = _normalizeParam(path) ?? '/';
    final normalizedSni = _normalizeParam(sni) ?? address;
    final hasRealityKey =
        realityPublicKey != null && realityPublicKey!.isNotEmpty;
    final json = <String, dynamic>{};

    // Логирование
    json['log'] = {'loglevel': 'info'};

    // DNS (чтобы избежать таймаутов резолва внутри VPN)
    json['dns'] = {
      'servers': ['1.1.1.1', '9.9.9.9'],
    };

    // Inbounds - SOCKS для перенаправления трафика из VPN интерфейса
    // sniffing: при подключении по IP Xray извлекает домен из TLS SNI для routing
    json['inbounds'] = [
      {
        'tag': 'socks-in',
        'port': 10808,
        'protocol': 'socks',
        'settings': {
          'auth': 'noauth',
          'udp': true,
        },
        'sniffing': {
          'enabled': true,
          'destOverride': ['http', 'tls'],
        },
      }
    ];

    // Outbounds
    final outbounds = <Map<String, dynamic>>[];
    final outbound = <String, dynamic>{
      'tag': 'proxy',
    };

    // Определяем тип протокола для XRay-core
    if (protocol == 'vless') {
      outbound['protocol'] = 'vless';
      final user = <String, dynamic>{
        'id': uuid,
        'encryption': 'none',
      };
      final settings = <String, dynamic>{
        'vnext': [
          {
            'address': address,
            'port': port,
            'users': [user]
          }
        ]
      };
      // Keep REALITY on plain TCP framing for stability under churn.
      // packetEncoding=xudp amplifies UDP churn and causes retry storms on weak nodes.
      outbound['settings'] = settings;
    } else if (protocol == 'vmess') {
      outbound['protocol'] = 'vmess';
      outbound['settings'] = {
        'vnext': [
          {
            'address': address,
            'port': port,
            'users': [
              {
                'id': uuid,
                'alterId': 0,
                'security': encryption,
              }
            ]
          }
        ]
      };
    } else {
      throw ArgumentError('Неподдерживаемый протокол для XRay-core: $protocol');
    }

    // Stream settings (TLS/Reality/Transport)
    final streamSettings = <String, dynamic>{};

    // TLS/Reality settings
    if (hasRealityKey) {
      streamSettings['security'] = 'reality';
      final realitySettings = <String, dynamic>{
        'publicKey': realityPublicKey!,
        'serverName': normalizedSni,
        'fingerprint':
            realityFp != null && realityFp!.isNotEmpty ? realityFp! : 'chrome',
      };
      if (realityShortId != null && realityShortId!.isNotEmpty) {
        realitySettings['shortId'] = realityShortId!;
      }
      if (realitySpx != null && realitySpx!.isNotEmpty) {
        realitySettings['spiderX'] = realitySpx!;
      }
      streamSettings['realitySettings'] = realitySettings;
    } else if (security == 'tls') {
      streamSettings['security'] = 'tls';
      streamSettings['tlsSettings'] = {
        'serverName': normalizedSni,
        'allowInsecure': false,
      };
    }

    // Transport settings
    final normalizedNetwork = hasRealityKey ? 'tcp' : network;
    if (normalizedNetwork == 'ws') {
      streamSettings['network'] = 'ws';
      streamSettings['wsSettings'] = {
        'path': normalizedPath,
        'headers': {
          'Host': normalizedHost,
        }
      };
    } else if (normalizedNetwork == 'grpc') {
      streamSettings['network'] = 'grpc';
      streamSettings['grpcSettings'] = {
        'serviceName': normalizedPath == '/' ? 'xray-grpc' : normalizedPath,
      };
    } else if (normalizedNetwork == 'tcp') {
      streamSettings['network'] = 'tcp';
    }

    if (streamSettings.isNotEmpty) {
      outbound['streamSettings'] = streamSettings;
    }

    if (hasRealityKey) {
      // Diagnostic build: collapse YouTube's many short flows into fewer Reality TCP sessions.
      outbound['mux'] = {
        'enabled': true,
        'concurrency': 8,
      };
    }

    outbounds.add(outbound);

    // Direct outbound для DNS
    outbounds.add({'protocol': 'freedom', 'tag': 'direct', 'settings': {}});

    json['outbounds'] = outbounds;

    // Routing - правила маршрутизации
    // 1) VPN-сервер (address:port) в direct — КРИТИЧНО: иначе трафик к серверу идёт через proxy,
    //    образуется петля и интернет не работает. Xray: "taking detour [proxy] for [tcp:45.12.132.94:4443]".
    // 2) DNS-серверы в direct — иначе DNS-запросы идут через proxy и резолв может не проходить.
    // Базовый каркас: отдельного правила для API нет. На Android контрольный план — direct в XrayRoutingHelper.
    final rules = <Map<String, dynamic>>[];

    // VPN-сервер — всегда direct (предотвращает routing loop)
    final isServerIp =
        RegExp(r'^[\d.]+$').hasMatch(address) || address.contains(':');
    if (isServerIp) {
      rules.add({
        'type': 'field',
        'ip': [address],
        'outboundTag': 'direct',
      });
    } else {
      rules.add({
        'type': 'field',
        'domain': [address, 'domain:$address'],
        'outboundTag': 'direct',
      });
    }

    // DNS-серверы (1.1.1.1, 9.9.9.9, 8.8.8.8 и т.д.) — direct, иначе резолв через proxy может не работать
    rules.add({
      'type': 'field',
      'ip': ['1.1.1.1', '1.0.0.1', '9.9.9.9', '8.8.8.8', '8.8.4.4'],
      'outboundTag': 'direct',
    });

    rules.add({
      'type': 'field',
      'inboundTag': ['socks-in'],
      'outboundTag': 'proxy',
    });

    json['routing'] = {'rules': rules};

    return jsonEncode(json);
  }

  @override
  String toString() {
    return 'XrayConfig(uuid: $uuid, address: $address, port: $port, protocol: $protocol)';
  }
}
