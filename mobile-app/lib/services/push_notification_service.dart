import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../config/app_navigation.dart';
import '../core/api/api_client.dart';
import '../core/logger/logger.dart';
import '../l10n/app_localizations.dart';
import '../l10n/localized_messages.dart';
import 'entitlement_push_handler.dart';
import 'fcm_journal_policy.dart';
import 'notification_journal_service.dart';

AppLocalizations _fcmL10n() =>
    lookupAppLocalizations(Locale(LocalizedMessages.currentLanguageCode));

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  // Android: [EntitlementFcmReceiver] обрабатывает тот же intent без второго FlutterEngine.
  // Раньше здесь вызывались Firebase.initializeApp + ensureInitialized → лишний isolate,
  // FlutterJNI «loadLibrary called more than once», риск OOM/краша при пиковой нагрузке.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return;
  }
  await Firebase.initializeApp();
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[Push] Background message: ${message.messageId} data=${message.data}');
  await EntitlementPushHandler.handleFcmData(
    Map<String, dynamic>.from(message.data),
    source: 'fcm_background_ios',
  );
  if (FcmJournalPolicy.shouldAppendToJournal(message)) {
    try {
      final pair = FcmJournalPolicy.titlesForMessage(message, _fcmL10n());
      await NotificationJournalService.instance.append(
        title: pair.title,
        body: pair.body,
        source: 'fcm_background_ios',
        data: Map<String, dynamic>.from(message.data),
      );
    } catch (e, st) {
      debugPrint('[Push] journal append (background ios): $e $st');
    }
  }
}

class PushNotificationService {
  static final PushNotificationService _instance =
      PushNotificationService._internal();
  factory PushNotificationService() => _instance;
  PushNotificationService._internal();

  final _logger = Logger();
  late final FirebaseMessaging _messaging;
  FlutterLocalNotificationsPlugin? _localNotifications;
  String? _fcmToken;
  bool _initialized = false;

  String? get fcmToken => _fcmToken;

  /// После смены аккаунта на том же устройстве [init] уже не вызывает отправку токена.
  /// Вызывать из потоков успешного логина с уже выставленным JWT в [ApiClient].
  Future<void> syncPushTokenWithCurrentSession() async {
    if (!_initialized) {
      await init();
      return;
    }
    await resendTokenIfNeeded();
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      await Firebase.initializeApp();
      _messaging = FirebaseMessaging.instance;
      _logger.info('Firebase initialized', 'PushNotificationService');
    } catch (e) {
      _logger.error('Firebase init error', 'PushNotificationService', e);
      return;
    }

    // Android: не регистрируем Dart-isolate для фона — плагин поднимает второй FlutterEngine
    // (FLTFireBGExecutor / FlutterFirebaseMessagingBackgroundService), что на OEM (Oplus)
    // совпадает с потерей фокуса при первом VPN connect. Обработка data-сообщений — native
    // [EntitlementFcmReceiver]; Dart handler на Android и так no-op.
    if (defaultTargetPlatform != TargetPlatform.android) {
      FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
    }

    await _initLocalNotifications();
    await _createNotificationChannel();
    await _requestPermission();
    await _getAndSendToken();

    _messaging.onTokenRefresh.listen((newToken) {
      _fcmToken = newToken;
      _sendTokenToBackend(newToken);
    });

    FirebaseMessaging.onMessage.listen((m) {
      _handleForegroundMessage(m).catchError((e, st) {
        _logger.warning('foreground FCM handler: $e $st', 'PushNotificationService');
      });
    });

    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      _handleMessageOpenedApp(m).catchError((e, st) {
        _logger.warning('openedApp FCM handler: $e $st', 'PushNotificationService');
      });
    });

    final initial = await _messaging.getInitialMessage();
    if (initial != null) {
      await _handleInitialMessage(initial);
    }
  }

  Future<void> _initLocalNotifications() async {
    try {
      final fln = FlutterLocalNotificationsPlugin();
      await fln.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_notification_g'),
          iOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: _onLocalNotificationTapped,
      );
      final android =
          fln.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          'grani_notifications',
          'GRANI',
          description: 'Push notifications',
          importance: Importance.high,
        ),
      );
      await android?.requestNotificationsPermission();
      _localNotifications = fln;
      _logger.info('Local notifications plugin ready', 'PushNotificationService');
    } catch (e, st) {
      _logger.warning('Local notifications init: $e $st', 'PushNotificationService');
    }
  }

  void _onLocalNotificationTapped(NotificationResponse response) {
    if (response.payload == 'open_journal') {
      appNavigatorKey.currentState?.pushNamed('/notification-journal');
    }
  }

  Future<void> _createNotificationChannel() async {
    try {
      final l10n = lookupAppLocalizations(
        Locale(LocalizedMessages.currentLanguageCode),
      );
      const channel = MethodChannel('com.granivpn.mobile/notifications');
      await channel.invokeMethod('createNotificationChannel', {
        'id': 'grani_notifications',
        'name': l10n.notificationChannelName,
        'description': l10n.notificationChannelDescription,
        'importance': 4, // IMPORTANCE_HIGH
      });
    } catch (e) {
      _logger.warning('createNotificationChannel: $e', 'PushNotificationService');
    }
  }

  Future<void> _requestPermission() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    _logger.info(
      'Push permission: ${settings.authorizationStatus}',
      'PushNotificationService',
    );
  }

  Future<void> _getAndSendToken() async {
    try {
      _fcmToken = await _messaging.getToken();
      if (_fcmToken != null) {
        _logger.info(
          'FCM token received: ${_fcmToken!.substring(0, 20)}...',
          'PushNotificationService',
        );
        await _sendTokenToBackend(_fcmToken!);
      }
    } catch (e) {
      _logger.error('getToken error', 'PushNotificationService', e);
    }
  }

  Future<void> _sendTokenToBackend(String token) async {
    try {
      await ApiClient().post(
        '/vpn/device/push-token',
        data: {
          'push_token': token,
          'language': LocalizedMessages.currentLanguageCode,
        },
      );
      _logger.info('Push token sent to backend', 'PushNotificationService');
    } catch (e) {
      _logger.warning(
        'Failed to send push token: $e',
        'PushNotificationService',
      );
    }
  }

  Future<void> _showLocalBanner(
    String title,
    String body,
    String? messageId,
    AppLocalizations l10n,
  ) async {
    final fln = _localNotifications;
    if (fln == null) return;
    final nid = (messageId?.hashCode ?? DateTime.now().microsecondsSinceEpoch) & 0x7fffffff;
    final android = AndroidNotificationDetails(
      'grani_notifications',
      l10n.notificationChannelName,
      channelDescription: l10n.notificationChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      icon: '@drawable/ic_notification_g',
    );
    final details = NotificationDetails(
      android: android,
      iOS: const DarwinNotificationDetails(),
    );
    await fln.show(
      nid,
      title,
      body.isEmpty ? ' ' : body,
      details,
      payload: 'open_journal',
    );
  }

  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    await EntitlementPushHandler.handleFcmData(
      Map<String, dynamic>.from(message.data),
      source: 'fcm_foreground',
    );
    final l10n = _fcmL10n();
    if (!FcmJournalPolicy.shouldAppendToJournal(message)) {
      return;
    }
    final pair = FcmJournalPolicy.titlesForMessage(message, l10n);
    await NotificationJournalService.instance.append(
      title: pair.title,
      body: pair.body,
      source: 'fcm_foreground',
      data: Map<String, dynamic>.from(message.data),
    );
    await _showLocalBanner(pair.title, pair.body, message.messageId, l10n);
    _logger.info(
      'Foreground push shown: ${pair.title}',
      'PushNotificationService',
    );
  }

  Future<void> _handleMessageOpenedApp(RemoteMessage message) async {
    final l10n = _fcmL10n();
    if (FcmJournalPolicy.shouldAppendToJournal(message)) {
      final pair = FcmJournalPolicy.titlesForMessage(message, l10n);
      await NotificationJournalService.instance.append(
        title: pair.title,
        body: pair.body,
        source: 'fcm_opened_app',
        data: Map<String, dynamic>.from(message.data),
      );
    }
    await EntitlementPushHandler.handleFcmData(
      Map<String, dynamic>.from(message.data),
      source: 'fcm_opened_app',
    );
    _logger.info(
      'Push opened app: ${message.data}',
      'PushNotificationService',
    );
  }

  Future<void> _handleInitialMessage(RemoteMessage message) async {
    final l10n = _fcmL10n();
    if (FcmJournalPolicy.shouldAppendToJournal(message)) {
      final pair = FcmJournalPolicy.titlesForMessage(message, l10n);
      await NotificationJournalService.instance.append(
        title: pair.title,
        body: pair.body,
        source: 'fcm_initial_message',
        data: Map<String, dynamic>.from(message.data),
      );
    }
    await EntitlementPushHandler.handleFcmData(
      Map<String, dynamic>.from(message.data),
      source: 'fcm_initial_message',
    );
    _logger.info(
      'Push initial message: ${message.data}',
      'PushNotificationService',
    );
  }

  Future<void> resendTokenIfNeeded() async {
    if (_fcmToken != null) {
      await _sendTokenToBackend(_fcmToken!);
    } else {
      await _getAndSendToken();
    }
  }

  Future<void> syncLanguage() async {
    await _createNotificationChannel();
    await resendTokenIfNeeded();
  }
}
