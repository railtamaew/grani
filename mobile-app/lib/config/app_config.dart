import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AppConfig {
  /// Primary auth CTA on start screen: google | email.
  static const String startScreenPrimaryAuth = String.fromEnvironment(
    'START_SCREEN_PRIMARY_AUTH',
    defaultValue: 'google',
  );
  static bool get isEmailPrimaryAuth =>
      startScreenPrimaryAuth.toLowerCase() == 'email';

  // Use --dart-define=API_BASE_URL=... to override at build time.
  /// Основной API (Cloudflare-first) — api.granilink.com.
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api.granilink.com/api',
  );

  /// Запасные URL API при блокировке оператора (пробуем по порядку после основного).
  /// Задаётся через --dart-define=API_BASE_URL_FALLBACKS=url1,url2 (без пробелов).
  /// Опционально список можно получать с бэкенда: GET /api/vpn/bootstrap (поле api_base_urls).
  /// См. docs/VPN_BYPASS_SCENARIOS.md (сценарий 6 — Bootstrap).
  static final List<String> apiBaseUrlFallbacks = () {
    const raw = String.fromEnvironment(
      'API_BASE_URL_FALLBACKS',
      // Пусто по умолчанию — один origin (см. [apiBaseUrls]); при необходимости задать через dart-define.
      defaultValue: '',
    );
    final list = <String>[];
    if (raw.isNotEmpty) {
      list.addAll(
          raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty));
    }
    return list;
  }();

  /// IP запасного API-proxy на HU-BUD-01.
  static const String apiServerIp = '45.12.132.94';

  /// Hostname для Host-header и TLS SNI при подключении по IP.
  static const String apiServerHost = 'api.granilink.com';

  /// IP VPN-сервера (доп. маршрут через reverse proxy к API).
  static const String apiVpnServerIp = '45.12.132.94';

  /// Запасной HTTPS-порт nginx→API на VPN-ноде (443 занят/режется). Не 8443 — там VMESS.
  static const int apiVpnServerHttpsAltPort = 8444;

  /// Hostname для Host/SNI при подключении к VPN-серверу по IP.
  static const String apiVpnServerHost = 'api.granilink.com';

  /// Тот же прокси на HU-BUD, имя под Cloudflare (вариант A).
  static const String apiVpnRuHost = 'api.granilink.com';

  /// IP-адреса, для которых принимаем TLS-сертификат (при подключении по IP).
  static const List<String> apiDirectIpAllowList = [apiVpnServerIp];

  /// Host для SNI при подключении по IP. Возвращает hostname для переданного IP.
  static String? hostForApiIp(String ip) {
    return ip == apiVpnServerIp ? apiVpnServerHost : null;
  }

  /// Кэш списка URL с бэкенда (bootstrap). Заполняется AuthService после GET /api/vpn/bootstrap.
  static List<String>? cachedApiBaseUrls;

  /// Время последнего перехода VPN в connected (для отложенного bootstrap, пока стабилизируется туннель).
  /// См. [AuthService.fetchBootstrapUrls] — задержка при недавнем connected.
  static DateTime? vpnTunnelConnectedAt;

  /// Порты Xray из bootstrap (`xray_expected_ports`); совпадают с backend/core/constants.py.
  static Map<String, int>? cachedXrayExpectedPorts;

  /// Ожидаемый порт в JSON-конфиге для протокола API (`xray_vless`, `xray_vmess`, `xray_reality`).
  static int? expectedXrayPort(String protocolApiValue) {
    final fromServer = cachedXrayExpectedPorts?[protocolApiValue];
    if (fromServer != null) return fromServer;
    switch (protocolApiValue) {
      case 'xray_vless':
        return 4443;
      case 'xray_vmess':
        return 8443;
      case 'xray_reality':
        return 2053;
      case 'xray_vless_ws_tls':
      case 'xray_vless_grpc_tls':
        return 443;
      default:
        return null;
    }
  }

  /// URL для прямого подключения по IP (fallback при блокировке домена).
  static String get apiDirectIpUrl =>
      'https://$apiServerIp:$apiVpnServerHttpsAltPort/api';

  /// URL VPN-сервера (reverse proxy к API).
  static String get apiVpnServerUrl => 'https://$apiVpnServerIp/api';

  /// api.granilink.com → HU-BUD → основной API.
  static String get apiGranivpnRuViaHuUrl => 'https://$apiVpnRuHost/api';
  static String get apiGranivpnRuViaHuUrlAlt =>
      'https://$apiVpnRuHost:$apiVpnServerHttpsAltPort/api';

  /// Тот же прокси на запасном порту (см. apiVpnServerHttpsAltPort).
  static String get apiVpnServerUrl8443 =>
      'https://$apiVpnServerIp:$apiVpnServerHttpsAltPort/api';

  /// Устаревшие/известно проблемные хосты API — не используем (bootstrap может всё ещё отдавать URL).
  static bool isDeprecatedApiBaseUrl(String url) {
    try {
      final h = Uri.parse(url).host.toLowerCase();
      return h == 'api.granilink.com';
    } catch (_) {
      return false;
    }
  }

  /// Единственный базовый origin API (по умолчанию `https://api.granilink.com/api`).
  /// Расширенный список из bootstrap / IP fallback отключён — см. историю multi-base в git.
  static List<String> get apiBaseUrls => [apiBaseUrl];

  static const String appName = 'GRANI';

  // Версия и информация о сборке (загружается из package_info)
  static String appVersion = '1.0.4';
  static String buildNumber = '23';
  static String buildDate = '2026-04-27'; // Автоматически заменяется при сборке

  // Инициализация версии из package_info
  static Future<void> init() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      appVersion = packageInfo.version;
      buildNumber = packageInfo.buildNumber;
    } catch (e) {
      // Если не удалось загрузить, используем значения по умолчанию
      appVersion = '1.0.4';
      buildNumber = '23';
    }
  }

  // Полная версия с датой сборки
  static String getFullVersion() {
    return '$appVersion+$buildNumber';
  }

  // Версия с датой сборки для отображения
  static String getVersionWithBuildDate() {
    return '$appVersion+$buildNumber\nСборка: $buildDate';
  }

  // Платежные системы
  // Payment providers (override via --dart-define for production builds).
  static const String cloudPaymentsPublicId = String.fromEnvironment(
    'CLOUDPAYMENTS_PUBLIC_ID',
    defaultValue: 'pk_test_1234567890',
  );
  static const String yukassaShopId = String.fromEnvironment(
    'YUKASSA_SHOP_ID',
    defaultValue: 'test_shop_id',
  );

  // Firebase
  static const String firebaseProjectId = 'granivpn-app';

  // Google OAuth:
  // - Android client IDs используются системой по package+SHA1.
  // - Web client ID — OAuth «Авторизация GRANI» в GCP; совпадает с google-services.json (serverClientId).
  static const String _googleOAuthWebClientIdRelease =
      '639166931934-nrqvjmguujm6a1jrvhusm7ail4fom97n.apps.googleusercontent.com';
  static const String _googleOAuthWebClientIdDebug =
      '639166931934-nrqvjmguujm6a1jrvhusm7ail4fom97n.apps.googleusercontent.com';
  static String get googleOAuthWebClientId => kDebugMode
      ? _googleOAuthWebClientIdDebug
      : _googleOAuthWebClientIdRelease;

  // VPN
  static const int maxDevices = int.fromEnvironment(
    'MAX_DEVICES',
    defaultValue: 5,
  );
  static const Duration connectionTimeout = Duration(seconds: 30);

  /// Таймаут запроса отключения через API (/vpn/disconnect). Используется только до fire-and-forget; после — запрос не блокирует.
  static const Duration disconnectApiTimeout = Duration(seconds: 8);

  /// В disconnect(): макс. время ожидания ответа API отключения перед переходом UI в disconnected (fire-and-forget после этого).
  static const Duration disconnectUiWaitMax = Duration(seconds: 2);

  /// Таймаут первого запроса create-client (Xray). При синхронном apply (Celery недоступен) до 25–30 с.
  static const Duration createClientTimeoutFirst = Duration(seconds: 25);

  /// Таймаут повторного запроса create-client (Xray fallback).
  static const Duration createClientTimeoutRetry = Duration(seconds: 18);

  /// Таймаут GET /vpn/xray/config (быстрый путь).
  static const Duration xrayGetConfigTimeout = Duration(seconds: 8);

  /// В disconnect(): макс. число шагов ожидания завершения connect (шаг 100 ms) перед принудительным отключением. 45 ≈ 4.5 с.
  static const int disconnectWaitConnectMaxAttempts = 45;
  static const Duration disconnectWaitConnectStep = Duration(milliseconds: 100);

  /// Debounce смены сети (Wi‑Fi ↔ мобильный) перед переподключением VPN. 1000 ms — быстрее реакция, меньше дрожания.
  static const Duration networkChangeDebounceDuration =
      Duration(milliseconds: 1000);

  /// В selectServer(): макс. число шагов ожидания завершения disconnect (шаг 100 ms) перед сменой сервера.
  static const int selectServerWaitDisconnectMaxAttempts = 50;
  static const Duration selectServerWaitDisconnectStep =
      Duration(milliseconds: 100);

  /// Задержка перед повторным connect при смене сети (Wi‑Fi ↔ мобильный). 200 ms — баланс стабильности tun2socks и скорости.
  static const Duration reconnectAfterNetworkChangeDelay =
      Duration(milliseconds: 200);

  /// Только если первая попытка `/auth/*` упала по **таймауту** (connect/send/receive):
  /// пауза перед granilink fallback. При `connectionError` задержки нет.
  static const Duration authPathFallbackDelay = Duration(milliseconds: 600);

  /// В начале [VpnService.connect]: мягкая пауза (не замена очереди control-plane; полноценная сериализация — отдельная задача).
  static const Duration controlPlaneSettleBeforeConnect =
      Duration(milliseconds: 150);

  /// Минимальный интервал после переподключения по смене сети, в течение которого новая смена сети не запускает disconnect→connect (снижает «дрожание»).
  static const Duration reconnectMinIntervalAfterNetworkChange =
      Duration(seconds: 2);

  /// После возврата из фона (resume/пробуждение экрана) смену сети не обрабатываем это время — избегаем ложного disconnect при «мигании» сети.
  static const Duration networkChangeIgnoreAfterResume = Duration(seconds: 5);

  /// Включает hedged GET для критичных control-plane endpoint'ов
  /// (/auth/me, /vpn/status и др.): второй маршрут стартует через короткую задержку.
  static const bool enableHedgedCriticalGet = bool.fromEnvironment(
    'ENABLE_HEDGED_CRITICAL_GET',
    defaultValue: true,
  );
  static const Duration hedgedCriticalDelay = Duration(milliseconds: 250);

  /// Подробные route-логи (policy/selected/failure/cooldown/hedged).
  /// В debug включено по умолчанию; в release включается через dart-define.
  static bool get enableRouteVerboseLogs =>
      kDebugMode ||
      const bool.fromEnvironment(
        'ENABLE_ROUTE_VERBOSE_LOGS',
        defaultValue: false,
      );

  /// Таймаут запроса отправки логов подключения (vpn/logs/send). 8 с — баланс между стабильностью и скоростью.
  static const Duration logsSendTimeout = Duration(seconds: 8);

  /// Задержка перед повторной попыткой отправки логов при таймауте/сетевой ошибке.
  static const Duration logsSendRetryDelay = Duration(seconds: 1);

  // Поддержка и шаринг
  /// Telegram support bot username.
  static const String supportTelegramBotUsername = String.fromEnvironment(
    'SUPPORT_TELEGRAM_BOT_USERNAME',
    defaultValue: 'granihelpbot',
  );

  /// Ссылка на Telegram-бота @granihelpbot (или t.me для браузера)
  static const String supportTelegramUrl = String.fromEnvironment(
    'SUPPORT_TELEGRAM_URL',
    defaultValue: 'https://t.me/granihelpbot',
  );

  /// Deep link для открытия Telegram-бота.
  static Uri supportTelegramDeepLink({String? start}) => Uri(
        scheme: 'tg',
        host: 'resolve',
        queryParameters: <String, String>{
          'domain': supportTelegramBotUsername,
          if (start != null && start.isNotEmpty) 'start': start,
        },
      );

  /// Browser fallback для Telegram-бота.
  static Uri supportTelegramWebLink({String? start}) {
    final base = Uri.parse(supportTelegramUrl);
    return base.replace(
      queryParameters: <String, String>{
        ...base.queryParameters,
        if (start != null && start.isNotEmpty) 'start': start,
      },
    );
  }

  /// URL Google Play для шаринга
  static const String sharePlayStoreUrl =
      'https://play.google.com/store/apps/details?id=com.granivpn.mobile';

  // UI
  static const double borderRadius = 12.0;
  static const double padding = 16.0;
}
