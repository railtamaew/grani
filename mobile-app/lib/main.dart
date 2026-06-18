import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:get_it/get_it.dart';
import 'theme.dart';
import 'screens/start_screen.dart';
import 'screens/auth_email_screen.dart';
import 'screens/auth_code_screen.dart';
import 'screens/main_content_screen.dart';
import 'screens/bottom_sheet_profile.dart';
import 'screens/trial_ended_screen.dart';
import 'screens/devices_screen.dart' deferred as devices_screen;
import 'screens/device_limit_screen.dart';
import 'screens/payment_screen.dart' deferred as payment_screen;
import 'screens/privacy_policy_screen.dart' deferred as privacy_policy_screen;
import 'screens/split_tunnel_screen.dart';
// PlanSelectionScreen удалён — маршрут /subscription теперь ведёт на TrialEndedScreen
import 'services/vpn_service.dart';
import 'services/auth_service.dart';
import 'services/native_vpn_service.dart';
import 'services/subscription_service.dart';
import 'config/page_transitions.dart';
import 'config/app_config.dart';
import 'config/app_navigation.dart';
import 'core/api/api_client.dart';
import 'core/api/preferred_route_storage.dart';
import 'core/logger/logger.dart';
import 'core/cache/cache_service.dart';
import 'core/storage/storage_service.dart';
import 'core/storage/shared_preferences_holder.dart';
import 'core/errors/error_handler.dart';
import 'core/session/app_session_controller.dart';
import 'core/vpn/lifecycle_network_controller.dart';
import 'core/session/locale_controller.dart';
import 'core/perf/perf_logger.dart';
import 'l10n/localized_messages.dart';
import 'l10n/app_localizations.dart';
import 'services/connection_logger.dart';
import 'services/app_update_service.dart';
import 'services/push_notification_service.dart';
import 'services/entitlement_native_sync.dart';
import 'services/notification_journal_service.dart';
import 'screens/notification_journal_screen.dart';
import 'widgets/pending_device_limit_listener.dart';

const String _simpleVpnActiveSessionCacheKey =
    'simple_vpn_active_session_id_v1';

bool get _isMobileTarget =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

Future<void> _disconnectVpnAfterAuthLoss() async {
  const source = 'auth_logout_callback';
  String? simpleSessionId;

  try {
    simpleSessionId = await CacheService().getString(
      _simpleVpnActiveSessionCacheKey,
    );
  } catch (_) {
    simpleSessionId = null;
  }

  try {
    final vpn = GetIt.instance<VpnService>();
    vpn.resetSession();
    unawaited(
      vpn.disconnect(
        reason: VpnDisconnectReason.authLost,
        source: source,
      ),
    );
  } catch (_) {
    // VpnService может быть ещё не зарегистрирован при logout до первого открытия экрана с VPN.
  }

  try {
    await NativeVpnService.disconnectAmneziaWg(
      reason: 'auth_lost',
      source: source,
      connectionSessionId: simpleSessionId,
    );
  } catch (e) {
    Logger().warning(
      'AmneziaWG disconnect after auth loss failed: $e',
      'AuthLogout',
    );
  }

  try {
    await NativeVpnService.disconnect(
      reason: 'auth_lost',
      source: source,
      connectionSessionId: simpleSessionId,
    );
  } catch (e) {
    Logger().warning(
      'Native VPN disconnect after auth loss failed: $e',
      'AuthLogout',
    );
  }

  try {
    await CacheService().remove(_simpleVpnActiveSessionCacheKey);
  } catch (_) {}
}

// Критичные для стартового и экрана входа изображения — предзагрузка в фоне после первого кадра
void _precacheImages() {
  Future.delayed(const Duration(milliseconds: 100), () async {
    const images = [
      'assets/images/figma/logo_grani_new.png',
      'assets/images/figma/pic1_welcome_babushka.png',
      'assets/images/figma/google_logo.png',
      'assets/images/figma/button_connecting.png',
      'assets/images/figma/screen2_connecting.png',
    ];
    for (final imagePath in images) {
      try {
        final provider = AssetImage(imagePath);
        await provider.obtainKey(const ImageConfiguration());
      } catch (e) {
        Logger().debug('Ошибка предзагрузки $imagePath: $e', 'main');
      }
    }
  });
}

VpnService _createVpnService(AuthService auth) {
  final service = _createVpnServiceInternal(auth);
  try {
    GetIt.instance.registerSingleton<VpnService>(service);
  } catch (_) {
    GetIt.instance.unregister<VpnService>();
    GetIt.instance.registerSingleton<VpnService>(service);
  }
  return service;
}

VpnService _createVpnServiceInternal(AuthService auth) {
  try {
    return VpnService(
      apiClient: ApiClient(),
      logger: Logger(),
      cacheService: CacheService(),
      storageService: StorageService(),
      errorHandler: ErrorHandler(),
      connectionLogger: ConnectionLogger(),
      authService: auth,
    );
  } catch (e, stackTrace) {
    Logger().error('Ошибка создания VpnService', 'main', e, stackTrace);
    return VpnService(
      apiClient: ApiClient(),
      logger: Logger(),
      cacheService: CacheService(),
      storageService: StorageService(),
      errorHandler: ErrorHandler(),
      connectionLogger: ConnectionLogger(),
      authService: auth,
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final perf = PerfLogger();
  perf.start('app_startup');
  if (_isMobileTarget) {
    perf.start('firebase_core_init');
    await Firebase.initializeApp();
    perf.stop('firebase_core_init');
  }

  // Инициализация AppConfig (загрузка версии из package_info)
  perf.start('app_config_init');
  await AppConfig.init();
  perf.stop('app_config_init', details: {
    'version': AppConfig.getFullVersion(),
  });

  // Инициализация core компонентов: один экземпляр SharedPreferences, параллельно Storage + Cache, затем ApiClient
  perf.start('core_init');
  await _initializeCoreComponents();
  await NotificationJournalService.instance.ensureLoaded();
  perf.stop('core_init');

  // Единый singleton AuthService: создаём один раз, ждём загрузку токенов, регистрируем в GetIt
  perf.start('auth_init');
  final authService = AuthService();
  await authService.waitForTokenLoad();
  try {
    GetIt.instance.registerSingleton<AuthService>(authService);
  } catch (e) {
    GetIt.instance.unregister<AuthService>();
    GetIt.instance.registerSingleton<AuthService>(authService);
  }
  ApiClient().setTokenProvider(() => authService.token);
  ApiClient().setRefreshTokenProvider(authService.refreshAccessToken);
  authService.setOnLogoutCallback(() {
    unawaited(_disconnectVpnAfterAuthLoss());
  });
  perf.stop('auth_init');

  final localeController = LocaleController();
  await localeController.init();
  LocalizedMessages.bind(localeController);
  // Синхронизация языка с бэкендом/FCM — только из UI выбора языка (см. LanguageSelectorBottomSheet),
  // без глобального listener на LocaleController (избегаем лишних запросов при любом notify).

  // Push/FCM синхронизируем после первого кадра, чтобы не держать старт UI.

  // Глобальный обработчик ошибок Flutter
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    Logger().error('Flutter Error: ${details.exception}', 'FlutterError',
        details.exception, details.stack);
  };

  if (_isMobileTarget) {
    // Статус-бар и навбар = фон приложения на всех экранах (градиент: верх #FFFFFF, низ #F7F9FA)
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor:
            Color(0xFFFFFFFF), // верх градиента (как у стартового экрана)
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFFF7F9FA), // низ градиента
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );

    // Только портрет: вёрстка рассчитана на книжную ориентацию (см. Home/Trial).
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
  }

  // Предзагрузка изображений в фоне (не блокирует запуск)
  _precacheImages();

  try {
    runApp(
        GraniApp(authService: authService, localeController: localeController));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      perf.stop('app_startup');
      _syncPushAfterFirstFrame(authService);
    });
  } catch (e, stack) {
    Logger().error('Fatal error during app startup', 'main', e, stack);
    // Показываем простой экран ошибки
    runApp(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('en'), Locale('ru')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: Center(
            child: Text('Startup error: $e'),
          ),
        ),
      ),
    );
  }
}

void _syncPushAfterFirstFrame(AuthService authService) {
  if (!_isMobileTarget) return;
  if (!authService.isAuthenticated) return;
  unawaited(() async {
    final perf = PerfLogger();
    perf.start('push_sync_after_first_frame');
    try {
      await PushNotificationService().syncPushTokenWithCurrentSession();
      perf.stop('push_sync_after_first_frame', details: {
        'result': 'success',
      });
    } catch (e) {
      perf.stop('push_sync_after_first_frame', details: {
        'result': 'error',
        'error': e.toString(),
      });
      Logger().warning('Push sync after first frame failed: $e', 'main');
    }
  }());
}

/// Инициализация core компонентов: один SharedPreferences, параллельно Storage + Cache, затем ApiClient
Future<void> _initializeCoreComponents() async {
  try {
    final prefs = await getSharedPreferences();
    await PreferredRouteStorage.applyDomainFirstPolicyMigration();
    await Future.wait([
      StorageService().initialize(prefs),
      CacheService().initialize(prefs),
    ]);
    ApiClient().initialize();
    Logger().info('Core components initialized');
  } catch (e) {
    Logger().error('Ошибка инициализации core компонентов', 'main', e);
  }
}

/// Запускает VpnService (и загрузку серверов) в фоне после первого кадра.
/// К моменту нажатия «Подключить» серверы уже загружены.
class _PreloadVpnWidget extends StatefulWidget {
  final Widget child;

  const _PreloadVpnWidget({required this.child});

  @override
  State<_PreloadVpnWidget> createState() => _PreloadVpnWidgetState();
}

class _PreloadVpnWidgetState extends State<_PreloadVpnWidget> {
  @override
  void initState() {
    super.initState();
    // Legacy VpnService preload disabled: active VPN path uses clean AmneziaWG controller.
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Виджет для обработки lifecycle событий с доступом к Provider
class _AppLifecycleHandler extends StatefulWidget {
  final Widget child;

  const _AppLifecycleHandler({required this.child});

  @override
  State<_AppLifecycleHandler> createState() => _AppLifecycleHandlerState();
}

class _AppLifecycleHandlerState extends State<_AppLifecycleHandler>
    with WidgetsBindingObserver {
  Timer? _inactiveVpnSyncDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        Future<void>.delayed(const Duration(seconds: 2), () {
          return AppUpdateService.instance.checkForPlayUpdate(
            trigger: 'startup',
          );
        }),
      );
    });
  }

  @override
  void dispose() {
    _inactiveVpnSyncDebounce?.cancel();
    _inactiveVpnSyncDebounce = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    LifecycleNetworkController.onAppLifecycleChanged(state);

    if (state == AppLifecycleState.resumed) {
      _inactiveVpnSyncDebounce?.cancel();
      _inactiveVpnSyncDebounce = null;
      ConnectionLogger().flushPendingAfterResumeIfAny();
      unawaited(
        AppUpdateService.instance.checkForPlayUpdate(
          trigger: 'resume',
        ),
      );
    } else if (state == AppLifecycleState.inactive) {
      // Шторка уведомлений / системный оверлей часто даёт только inactive без paused —
      // один раз сверяемся с нативом после короткой стабилизации.
      _inactiveVpnSyncDebounce?.cancel();
      _inactiveVpnSyncDebounce = null;
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _inactiveVpnSyncDebounce?.cancel();
      _inactiveVpnSyncDebounce = null;
      // Do not touch VPN state on pause; Android VPN must keep running independently.
    }
  }

  void _pollVpnStateSync() {
    if (!mounted) return;
    try {
      final vpnService = Provider.of<VpnService>(context, listen: false);
      vpnService.syncConnectionStateWithNative();
    } catch (_) {}
  }

  Future<void> _refreshServersIfNeeded() async {
    if (!mounted) return;

    await EntitlementNativeSync.drainPendingFromNativePrefs();
    if (!mounted) return;

    try {
      final vpnService = Provider.of<VpnService>(context, listen: false);
      final session = Provider.of<AppSessionController>(context, listen: false);
      await session.performResumeCoordination(vpnService);
      if (!mounted) return;
      await vpnService.revalidateDeviceQuotaFromServer();
      if (!mounted) return;
    } catch (e) {
      Logger()
          .warning('Ошибка при возврате из фона: $e', 'AppLifecycleHandler');
    } finally {
      _markResumeSyncEnd();
    }
  }

  void _markResumeSyncStart() {
    if (!mounted) return;
    try {
      final vpnService = Provider.of<VpnService>(context, listen: false);
      vpnService.beginResumeSyncGuard();
      Logger().debug('resume_sync_start', 'AppLifecycleHandler');
    } catch (_) {}
  }

  void _markResumeSyncEnd() {
    if (!mounted) return;
    try {
      final vpnService = Provider.of<VpnService>(context, listen: false);
      vpnService.endResumeSyncGuard();
      Logger().debug('resume_sync_end', 'AppLifecycleHandler');
    } catch (_) {}
  }

  Future<void> _syncConnectionStateOnPause() async {
    if (!mounted) return;

    try {
      final vpnService = Provider.of<VpnService>(context, listen: false);
      unawaited(
        vpnService.setNativeTrafficTelemetryForAppLifecycle(inBackground: true),
      );

      // Если VPN подключен, но приложение закрывается - отключаем на сервере
      // Не отключаем локальный туннель: по продуктовой логике VPN должен оставаться активным в фоне/после закрытия UI.
      if (vpnService.isVpnSessionPotentiallyActive) {
        Logger().debug(
          'Приложение ушло в background/detached, VPN активен — туннель сохраняем (без auto-disconnect)',
          'AppLifecycleHandler',
        );
      }
    } catch (e) {
      Logger()
          .warning('Ошибка синхронизации состояния: $e', 'AppLifecycleHandler');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _AuthRedirectListener extends StatefulWidget {
  final AuthService authService;
  final Widget child;

  const _AuthRedirectListener({
    required this.authService,
    required this.child,
  });

  @override
  State<_AuthRedirectListener> createState() => _AuthRedirectListenerState();
}

class _AuthRedirectListenerState extends State<_AuthRedirectListener> {
  bool _wasAuthenticated = false;

  @override
  void initState() {
    super.initState();
    _wasAuthenticated = widget.authService.isAuthenticated;
    widget.authService.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    widget.authService.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    final isAuth = widget.authService.isAuthenticated;
    if (_wasAuthenticated && !isAuth) {
      _wasAuthenticated = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && context.mounted) {
          Navigator.maybeOf(context)
              ?.pushNamedAndRemoveUntil('/', (_) => false);
        }
      });
    } else {
      _wasAuthenticated = isAuth;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Маршруты на shell trial/home ([MainContentScreen]). Новый код — только `/main`.
const _kRoutesToMainContentShell = <String>{
  '/main',
  '/home',
  '/trial-start',
  '/vpn-disconnected-trial',
  '/vpn-connecting-trial',
  '/vpn-connected-trial',
  '/subscription-activated',
  '/vpn-connecting',
  '/vpn-connected',
  '/connecting',
  '/connected',
};

class GraniApp extends StatefulWidget {
  GraniApp(
      {super.key, required this.authService, required this.localeController});
  final AuthService authService;
  final LocaleController localeController;

  @override
  State<GraniApp> createState() => _GraniAppState();
}

class _GraniAppState extends State<GraniApp> {
  String? _initialRoute;
  bool _isDeterminingRoute = true;
  bool _initialRouteError = false;
  final PerfLogger _perfLogger = PerfLogger();

  @override
  void initState() {
    super.initState();
    EntitlementNativeSync.registerDartSideHandler();
    _determineInitialRoute();
  }

  /// Определяет начальный маршрут: по кэшу сразу (без блокировки на refreshUserStatus), затем обновление в фоне.
  /// При запуске с плитки без подписки платформа передаёт /subscription — открываем выбор тарифа.
  /// Таймаут 10 с — при зависании показываем ошибку с кнопкой «Повторить» (BUG-005).
  Future<void> _determineInitialRoute() async {
    _perfLogger.start('route_determination');
    final authService = widget.authService;
    try {
      await _determineInitialRouteInternal(authService).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          Logger().warning('Таймаут определения маршрута (10 с)', 'GraniApp');
          throw TimeoutException('Превышено время ожидания');
        },
      );
    } on TimeoutException {
      if (_useAuthenticatedRouteFallback('timeout')) {
        _perfLogger.stop('route_determination', details: {
          'route': _initialRoute ?? '/',
          'fallback': 'authenticated_timeout',
        });
        return;
      }
      if (mounted) {
        setState(() {
          _isDeterminingRoute = false;
          _initialRouteError = true;
          _initialRoute = '/';
        });
      }
      _perfLogger.stop('route_determination', details: {'error': 'timeout'});
      return;
    } catch (e) {
      Logger().error('Ошибка определения маршрута', 'GraniApp', e);
      if (_useAuthenticatedRouteFallback(e.toString())) {
        _perfLogger.stop('route_determination', details: {
          'route': _initialRoute ?? '/',
          'fallback': 'authenticated_error',
          'error': e.toString(),
        });
        return;
      }
      if (mounted) {
        setState(() {
          _isDeterminingRoute = false;
          _initialRouteError = true;
          _initialRoute = '/';
        });
      }
      _perfLogger.stop('route_determination', details: {'error': e.toString()});
      return;
    }
    if (mounted) {
      setState(() {
        _isDeterminingRoute = false;
        _initialRouteError = false;
      });
    }
    _perfLogger.stop('route_determination', details: {
      'route': _initialRoute ?? '/',
    });
  }

  Future<void> _determineInitialRouteInternal(AuthService authService) async {
    if (authService.isAuthenticated && authService.token != null) {
      String? platformRoute;
      try {
        platformRoute = await const MethodChannel('com.granivpn.mobile/vpn')
            .invokeMethod<String>('getLaunchInitialRoute')
            .timeout(const Duration(seconds: 3), onTimeout: () => null);
      } catch (_) {
        platformRoute = null;
      }
      _initialRoute = (platformRoute != null && platformRoute.isNotEmpty)
          ? platformRoute
          : _getTargetRoute(authService);
      Logger().debug(
        'Начальный маршрут: $_initialRoute${platformRoute != null ? " (с плитки)" : ""}',
        'GraniApp',
      );
      _scheduleControlPlaneRefresh(authService);
    } else {
      _initialRoute = '/';
      Logger().debug(
          'Пользователь не авторизован, начальный маршрут: /', 'GraniApp');
    }
  }

  bool _useAuthenticatedRouteFallback(String reason) {
    final authService = widget.authService;
    if (!authService.isAuthenticated || authService.token == null) {
      return false;
    }
    Logger().warning(
      'Определение маршрута не удалось ($reason), открываем кешированный /main для авторизованного пользователя',
      'GraniApp',
    );
    if (mounted) {
      setState(() {
        _initialRoute = '/main';
        _initialRouteError = false;
        _isDeterminingRoute = false;
      });
      _scheduleControlPlaneRefresh(authService);
    }
    return true;
  }

  /// Обновляет control-plane snapshot только после сборки MultiProvider.
  /// Стартовый маршрут не должен зависеть от этого сетевого/Provider шага.
  void _scheduleControlPlaneRefresh(AuthService authService) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = appNavigatorKey.currentContext;
      if (ctx == null) {
        Logger().debug(
            'Navigator context недоступен для snapshot при старте', 'GraniApp');
        return;
      }
      _refreshControlPlaneInBackground(ctx, authService);
    });
  }

  /// Обновляет control-plane snapshot в фоне; при смене на trial-ended — переходит на соответствующий экран.
  void _refreshControlPlaneInBackground(
      BuildContext providerContext, AuthService authService) {
    if (!mounted) return;
    VpnService vpnService;
    try {
      vpnService = Provider.of<VpnService>(providerContext, listen: false);
    } catch (e) {
      Logger().debug(
          'VpnService недоступен для snapshot при старте: $e', 'GraniApp');
      return;
    }
    vpnService.refreshControlPlaneSnapshot(authService).timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        Logger()
            .debug('Таймаут snapshot при старте, используем кеш', 'GraniApp');
      },
    ).then((_) {
      if (!mounted) return;
      final newRoute = _getTargetRoute(authService);
      if (newRoute == '/trial-ended' && _initialRoute == '/main') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final ctx = appNavigatorKey.currentContext;
          if (ctx != null) {
            Navigator.maybeOf(ctx)
                ?.pushNamedAndRemoveUntil('/trial-ended', (_) => false);
          }
        });
      }
    }).catchError((e) {
      Logger()
          .debug('Ошибка snapshot при старте: $e, используем кеш', 'GraniApp');
    });
  }

  /// Определяет целевой маршрут на основе статуса пользователя
  String _getTargetRoute(AuthService authService) =>
      AppSessionController.targetRouteForAuthenticatedUser(authService);

  void _retryInitialRoute() {
    setState(() {
      _isDeterminingRoute = true;
      _initialRouteError = false;
    });
    _determineInitialRoute();
  }

  List<LocalizationsDelegate<dynamic>> get _localizationDelegates => const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ];

  List<Locale> get _supportedLocales => const [Locale('en'), Locale('ru')];

  @override
  Widget build(BuildContext context) {
    // Ошибка определения маршрута (таймаут и т.п.) — показываем fallback с «Повторить» (BUG-005)
    if (_initialRouteError) {
      return MaterialApp(
        title: 'GRANI',
        locale: widget.localeController.locale,
        supportedLocales: _supportedLocales,
        localizationsDelegates: _localizationDelegates,
        theme: GraniTheme.theme,
        home: Scaffold(
          backgroundColor: GraniTheme.primaryBackground,
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline,
                      size: 48, color: GraniTheme.warningOrange),
                  const SizedBox(height: 16),
                  Text(
                    AppLocalizations.of(context)?.errorConnection ??
                        'Connection error. Check internet connection.',
                    textAlign: TextAlign.center,
                    style: GraniTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _retryInitialRoute,
                    child: Text(AppLocalizations.of(context)?.authTryAgain ??
                        'Try again'),
                  ),
                ],
              ),
            ),
          ),
        ),
        debugShowCheckedModeBanner: false,
      );
    }
    // Показываем загрузку пока определяем маршрут
    if (_isDeterminingRoute) {
      return MaterialApp(
        title: 'GRANI',
        locale: widget.localeController.locale,
        supportedLocales: _supportedLocales,
        localizationsDelegates: _localizationDelegates,
        theme: GraniTheme.theme,
        home: Scaffold(
          backgroundColor: GraniTheme.primaryBackground,
          body: const Center(
            child: CircularProgressIndicator(),
          ),
        ),
        debugShowCheckedModeBanner: false,
      );
    }

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: widget.localeController),
        ChangeNotifierProvider.value(value: widget.authService),
        ChangeNotifierProvider(
          create: (context) => AppSessionController(
            Provider.of<AuthService>(context, listen: false),
          ),
        ),
        ChangeNotifierProxyProvider<AuthService, VpnService>(
          create: (context) => _createVpnService(
            Provider.of<AuthService>(context, listen: false),
          ),
          update: (_, __, previous) => previous!,
        ),
        ChangeNotifierProvider(
          create: (_) => SubscriptionService(),
        ),
        ChangeNotifierProvider<NotificationJournalService>.value(
          value: NotificationJournalService.instance,
        ),
      ],
      child: Builder(
        builder: (context) => MaterialApp(
          navigatorKey: appNavigatorKey,
          navigatorObservers: [appRouteObserver],
          title: 'GRANI',
          theme: GraniTheme.theme,
          locale: context.watch<LocaleController>().locale,
          supportedLocales: _supportedLocales,
          localizationsDelegates: _localizationDelegates,
          initialRoute: _initialRoute ?? '/',
          builder: (context, child) {
            // Оборачиваем в lifecycle handler и auth redirect (logout → экран входа)
            return _AppLifecycleHandler(
              child: _AuthRedirectListener(
                authService: widget.authService,
                child: PendingDeviceLimitListener(
                  child: _PreloadVpnWidget(
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              ),
            );
          },
          onGenerateRoute: (settings) {
            Logger().debug('onGenerateRoute: ${settings.name}', 'GraniApp');
            final routeName = settings.name;
            // Канонический shell — /main; остальные имена — совместимость (см. docs/MOBILE_APP_ROUTES_INVENTORY.md).
            if (routeName != null &&
                _kRoutesToMainContentShell.contains(routeName)) {
              return PageRouteBuilder<void>(
                settings: settings,
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
                pageBuilder: (context, _, __) => const MainContentScreen(),
                transitionsBuilder: (context, _, __, child) => child,
              );
            }
            switch (settings.name) {
              case '/':
                return SlideFadePageRoute(
                  child: const StartScreen(),
                  slideFromRight: false,
                  settings: settings,
                );
              case '/auth-email':
                return MaterialPageRoute(
                  builder: (context) => const AuthEmailScreen(),
                  settings: settings,
                );
              case '/auth-code':
                final args = settings.arguments;
                AuthCodeScreenArguments parsedArgs;
                if (args is AuthCodeScreenArguments) {
                  parsedArgs = args;
                } else if (args is String) {
                  parsedArgs = AuthCodeScreenArguments(email: args);
                } else {
                  parsedArgs =
                      const AuthCodeScreenArguments(email: 'user@example.com');
                }
                // Переходы между экранами авторизации - без анимации (instant)
                return MaterialPageRoute(
                  builder: (_) => AuthCodeScreen(
                    email: parsedArgs.email,
                    isError: parsedArgs.isError,
                    initialSeconds: parsedArgs.initialSeconds,
                    dailyRemaining: parsedArgs.dailyRemaining,
                  ),
                  settings: settings,
                );
              case '/trial-ended':
                return SlideFadePageRoute(
                  child: const TrialEndedScreen(),
                  slideFromRight: true,
                  settings: settings,
                );
              case '/profile':
                // Profile показывается через showProfileDrawer; deep link: MainContentScreen + sheet
                return MaterialPageRoute(
                  builder: (ctx) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (ctx.mounted) {
                        showProfileDrawer(ctx);
                      }
                    });
                    return const MainContentScreen();
                  },
                  settings: settings,
                );
              case '/device-limit':
                final args = settings.arguments;
                final devices = args is List ? args : <dynamic>[];
                return MaterialPageRoute(
                  builder: (_) => DeviceLimitScreen(
                    initialDevices: devices,
                    maxDevices: AppConfig.maxDevices,
                  ),
                  settings: settings,
                );
              case '/split-tunnel':
                return SlideFadePageRoute(
                  child: const SplitTunnelScreen(),
                  slideFromRight: true,
                  settings: settings,
                );
              case '/notification-journal':
                return SlideFadePageRoute(
                  child: const NotificationJournalScreen(),
                  slideFromRight: true,
                  settings: settings,
                );
              case '/devices':
                return SlideFadePageRoute(
                  child: FutureBuilder<void>(
                    future: devices_screen.loadLibrary(),
                    builder: (_, snap) => snap.connectionState ==
                            ConnectionState.done
                        ? devices_screen.DevicesScreen()
                        : const Scaffold(
                            body: Center(child: CircularProgressIndicator())),
                  ),
                  slideFromRight: true,
                  settings: settings,
                );
              case '/payment':
                return SlideFadePageRoute(
                  child: FutureBuilder<void>(
                    future: payment_screen.loadLibrary(),
                    builder: (_, snap) => snap.connectionState ==
                            ConnectionState.done
                        ? payment_screen.PaymentScreen()
                        : const Scaffold(
                            body: Center(child: CircularProgressIndicator())),
                  ),
                  slideFromRight: true,
                  settings: settings,
                );
              case '/privacy':
                return SlideFadePageRoute(
                  child: FutureBuilder<void>(
                    future: privacy_policy_screen.loadLibrary(),
                    builder: (_, snap) => snap.connectionState ==
                            ConnectionState.done
                        ? privacy_policy_screen.PrivacyPolicyScreen()
                        : const Scaffold(
                            body: Center(child: CircularProgressIndicator())),
                  ),
                  slideFromRight: true,
                  settings: settings,
                );
              case '/subscription':
                final mode = settings.arguments is SubscriptionScreenMode
                    ? settings.arguments as SubscriptionScreenMode
                    : SubscriptionScreenMode.expired;
                return SlideFadePageRoute(
                  child: TrialEndedScreen(mode: mode),
                  slideFromRight: true,
                  settings: settings,
                );
              default:
                return SlideFadePageRoute(
                  child: const StartScreen(),
                  slideFromRight: false,
                  settings: settings,
                );
            }
          },
          debugShowCheckedModeBanner: false,
        ),
      ),
    );
  }
}
