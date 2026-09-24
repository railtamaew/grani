import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_navigation.dart';
import '../config/app_config.dart';
import '../core/api/api_client.dart';
import '../core/logger/logger.dart';
import '../core/storage/storage_service.dart';
import '../l10n/app_localizations.dart';
import '../l10n/localized_messages.dart';
import 'analytics_service.dart';
import 'entitlement_push_handler.dart';
import 'fcm_journal_policy.dart';
import 'in_app_event_banner_service.dart';
import 'notification_journal_service.dart';

AppLocalizations _fcmL10n() =>
    lookupAppLocalizations(Locale(LocalizedMessages.currentLanguageCode));

enum NotificationPermissionOffer {
  none,
  requestSystemPermission,
  openSystemSettings,
}

@immutable
class AndroidNotificationPermissionSnapshot {
  const AndroidNotificationPermissionSnapshot({
    required this.enabled,
    required this.runtimePermissionRequired,
    required this.runtimePermissionGranted,
    required this.sdkInt,
  });

  factory AndroidNotificationPermissionSnapshot.fromMap(
    Map<dynamic, dynamic> value,
  ) {
    return AndroidNotificationPermissionSnapshot(
      enabled: value['enabled'] == true,
      runtimePermissionRequired: value['runtime_permission_required'] == true,
      runtimePermissionGranted: value['runtime_permission_granted'] == true,
      sdkInt: (value['sdk_int'] as num?)?.toInt() ?? 0,
    );
  }

  final bool enabled;
  final bool runtimePermissionRequired;
  final bool runtimePermissionGranted;
  final int sdkInt;
}

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
  debugPrint(
    '[Push] Background message: ${message.messageId} data=${message.data}',
  );
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
  static const _notificationChannel = MethodChannel(
    'com.granivpn.mobile/notifications',
  );
  static const _promptAttemptedKey =
      'notification_permission_prompt_attempted_v2';
  static const _settingsOfferBuildKey =
      'notification_permission_settings_offer_build';
  static final PushNotificationService _instance =
      PushNotificationService._internal();
  factory PushNotificationService() => _instance;
  PushNotificationService._internal();

  final _logger = Logger();
  late final FirebaseMessaging _messaging;
  FlutterLocalNotificationsPlugin? _localNotifications;
  String? _fcmToken;
  bool _initialized = false;
  DateTime? _lastAnalyticsIdentitySyncAt;

  String? get fcmToken => _fcmToken;

  /// После смены аккаунта на том же устройстве [init] уже не вызывает отправку токена.
  /// Вызывать из потоков успешного логина с уже выставленным JWT в [ApiClient].
  Future<void> syncPushTokenWithCurrentSession() async {
    await syncAnalyticsIdentityWithCurrentSession(force: true);
    if (!_initialized) {
      await init();
      return;
    }
    await resendTokenIfNeeded();
  }

  /// Sync Firebase Analytics identity independently from FCM.
  ///
  /// Notification permission denial or an unavailable FCM token must not make
  /// backend funnel events fall out of the Android Firebase data stream.
  Future<void> syncAnalyticsIdentityWithCurrentSession({
    bool force = false,
  }) async {
    final lastSync = _lastAnalyticsIdentitySyncAt;
    if (!force &&
        lastSync != null &&
        DateTime.now().difference(lastSync) < const Duration(minutes: 10)) {
      return;
    }

    try {
      final storage = StorageService();
      final deviceId =
          (await storage.getSecureString('device_id')) ??
          (await storage.getString('device_id'));
      if (deviceId == null || deviceId.isEmpty) {
        _logger.warning(
          'Analytics identity not sent: device_id is missing',
          'PushNotificationService',
        );
        return;
      }

      final identity = await AnalyticsService().getBackendMeasurementIdentity();
      final appInstanceId = identity['firebase_app_instance_id'];
      if (appInstanceId is! String || appInstanceId.isEmpty) {
        _logger.warning(
          'Analytics identity not sent: app_instance_id is missing',
          'PushNotificationService',
        );
        return;
      }

      await ApiClient().post(
        '/vpn/device/analytics-identity',
        data: <String, dynamic>{'device_id': deviceId, ...identity},
      );
      _lastAnalyticsIdentitySyncAt = DateTime.now();
      _logger.info(
        'Firebase analytics identity sent to backend',
        'PushNotificationService',
      );
    } catch (e) {
      _logger.warning(
        'Failed to send analytics identity: $e',
        'PushNotificationService',
      );
    }
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
    await _getAndSendToken();

    _messaging.onTokenRefresh.listen((newToken) {
      _fcmToken = newToken;
      _sendTokenToBackend(newToken);
    });

    FirebaseMessaging.onMessage.listen((m) {
      _handleForegroundMessage(m).catchError((e, st) {
        _logger.warning(
          'foreground FCM handler: $e $st',
          'PushNotificationService',
        );
      });
    });

    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      _handleMessageOpenedApp(m).catchError((e, st) {
        _logger.warning(
          'openedApp FCM handler: $e $st',
          'PushNotificationService',
        );
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
      final android = fln
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          'grani_notifications',
          'GRANI',
          description: 'Push notifications',
          importance: Importance.high,
        ),
      );
      _localNotifications = fln;
      _logger.info(
        'Local notifications plugin ready',
        'PushNotificationService',
      );
    } catch (e, st) {
      _logger.warning(
        'Local notifications init: $e $st',
        'PushNotificationService',
      );
    }
  }

  void _onLocalNotificationTapped(NotificationResponse response) {
    final payload = response.payload ?? '';
    if (payload.startsWith('lifecycle:')) {
      try {
        final decoded = jsonDecode(payload.substring('lifecycle:'.length));
        if (decoded is Map) {
          unawaited(
            _openLifecycleMessage(
              Map<String, dynamic>.from(decoded),
              sourceSurface: 'foreground_local_notification',
            ),
          );
          return;
        }
      } catch (e) {
        _logger.warning(
          'Invalid lifecycle notification payload: $e',
          'PushNotificationService',
        );
      }
    }
    if (payload == 'open_journal') {
      appNavigatorKey.currentState?.pushNamed('/notification-journal');
    }
  }

  Future<void> _createNotificationChannel() async {
    try {
      final l10n = lookupAppLocalizations(
        Locale(LocalizedMessages.currentLanguageCode),
      );
      await _notificationChannel.invokeMethod('createNotificationChannel', {
        'id': 'grani_notifications',
        'name': l10n.notificationChannelName,
        'description': l10n.notificationChannelDescription,
        'importance': 4, // IMPORTANCE_HIGH
      });
    } catch (e) {
      _logger.warning(
        'createNotificationChannel: $e',
        'PushNotificationService',
      );
    }
  }

  Future<AuthorizationStatus> notificationPermissionStatus() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final snapshot = await _androidNotificationPermissionSnapshot();
      if (snapshot.enabled) return AuthorizationStatus.authorized;
      final promptAttempted =
          await StorageService().getBool(_promptAttemptedKey) ?? false;
      return snapshot.runtimePermissionRequired && !promptAttempted
          ? AuthorizationStatus.notDetermined
          : AuthorizationStatus.denied;
    }
    if (!_initialized) await init();
    final settings = await _messaging.getNotificationSettings();
    return settings.authorizationStatus;
  }

  Future<AndroidNotificationPermissionSnapshot>
  _androidNotificationPermissionSnapshot() async {
    final raw = await _notificationChannel.invokeMethod<Map<dynamic, dynamic>>(
      'notificationPermissionSnapshot',
    );
    if (raw == null) {
      throw StateError('Android notification permission snapshot is missing');
    }
    return AndroidNotificationPermissionSnapshot.fromMap(raw);
  }

  @visibleForTesting
  static NotificationPermissionOffer offerForStatus(
    AuthorizationStatus status, {
    required bool supportsSettingsRecovery,
  }) {
    switch (status) {
      case AuthorizationStatus.notDetermined:
        return NotificationPermissionOffer.requestSystemPermission;
      case AuthorizationStatus.denied:
        return supportsSettingsRecovery
            ? NotificationPermissionOffer.openSystemSettings
            : NotificationPermissionOffer.none;
      case AuthorizationStatus.authorized:
      case AuthorizationStatus.provisional:
        return NotificationPermissionOffer.none;
    }
  }

  @visibleForTesting
  static NotificationPermissionOffer offerForAndroidSnapshot(
    AndroidNotificationPermissionSnapshot snapshot, {
    required bool promptAttempted,
  }) {
    if (snapshot.enabled) return NotificationPermissionOffer.none;
    if (snapshot.runtimePermissionRequired && !promptAttempted) {
      return NotificationPermissionOffer.requestSystemPermission;
    }
    return NotificationPermissionOffer.openSystemSettings;
  }

  Future<NotificationPermissionOffer> notificationPermissionOffer({
    String sourceSurface = 'unknown',
  }) async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return NotificationPermissionOffer.none;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      final snapshot = await _androidNotificationPermissionSnapshot();
      final promptAttempted =
          await StorageService().getBool(_promptAttemptedKey) ?? false;
      await AnalyticsService().logNotificationPermissionStatusChecked(
        sourceSurface: sourceSurface,
        enabled: snapshot.enabled,
        runtimePermissionRequired: snapshot.runtimePermissionRequired,
        runtimePermissionGranted: snapshot.runtimePermissionGranted,
        promptAttempted: promptAttempted,
        sdkInt: snapshot.sdkInt,
      );
      return offerForAndroidSnapshot(
        snapshot,
        promptAttempted: promptAttempted,
      );
    }
    return offerForStatus(
      await notificationPermissionStatus(),
      supportsSettingsRecovery: false,
    );
  }

  Future<bool> shouldOfferPermissionPrompt() async {
    return await notificationPermissionOffer() ==
        NotificationPermissionOffer.requestSystemPermission;
  }

  Future<bool> shouldOfferSettingsRecovery() async {
    if (await notificationPermissionOffer() !=
        NotificationPermissionOffer.openSystemSettings) {
      return false;
    }
    final lastOfferedBuild = await StorageService().getString(
      _settingsOfferBuildKey,
    );
    return lastOfferedBuild != AppConfig.buildNumber;
  }

  Future<void> recordSettingsRecoveryShown({
    required String sourceSurface,
  }) async {
    await StorageService().setString(
      _settingsOfferBuildKey,
      AppConfig.buildNumber,
    );
    await AnalyticsService().logNotificationPermissionSettingsOffer(
      sourceSurface: sourceSurface,
    );
  }

  Future<bool> openNotificationSettings({required String sourceSurface}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      final opened =
          await _notificationChannel.invokeMethod<bool>(
            'openNotificationSettings',
          ) ??
          false;
      if (opened) {
        await AnalyticsService().logNotificationPermissionSettingsOpened(
          sourceSurface: sourceSurface,
        );
      }
      return opened;
    } catch (e) {
      _logger.warning(
        'openNotificationSettings: $e',
        'PushNotificationService',
      );
      return false;
    }
  }

  Future<bool> requestPermissionForOnboarding({
    required String sourceSurface,
  }) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final before = await _androidNotificationPermissionSnapshot();
      if (before.enabled) {
        await AnalyticsService().logNotificationPermissionAlreadyGranted(
          sourceSurface: sourceSurface,
        );
        return true;
      }
      if (!before.runtimePermissionRequired) return false;
      final promptAttempted =
          await StorageService().getBool(_promptAttemptedKey) ?? false;
      if (promptAttempted) return false;

      // Persist before crossing the platform boundary. Android 13+ reports
      // `denied` both before the first prompt and after a real denial, so this
      // local marker is the only reliable way to distinguish the two states.
      await StorageService().setBool(_promptAttemptedKey, true);
      await AnalyticsService().logNotificationPermissionPrompted(
        sourceSurface: sourceSurface,
      );
      final raw = await _notificationChannel
          .invokeMethod<Map<dynamic, dynamic>>(
            'requestPostNotificationsPermission',
          );
      final after = raw == null
          ? await _androidNotificationPermissionSnapshot()
          : AndroidNotificationPermissionSnapshot.fromMap(raw);
      final granted = after.enabled;
      await AnalyticsService().logNotificationPermissionResult(
        granted: granted,
        sourceSurface: sourceSurface,
      );
      return granted;
    }

    if (!_initialized) await init();
    final before = await _messaging.getNotificationSettings();
    if (before.authorizationStatus == AuthorizationStatus.authorized ||
        before.authorizationStatus == AuthorizationStatus.provisional) {
      return true;
    }
    await AnalyticsService().logNotificationPermissionPrompted(
      sourceSurface: sourceSurface,
    );
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
    final granted =
        settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
    await AnalyticsService().logNotificationPermissionResult(
      granted: granted,
      sourceSurface: sourceSurface,
    );
    return granted;
  }

  Future<void> recordPermissionDeferred({required String sourceSurface}) {
    return AnalyticsService().logNotificationPermissionDeferred(
      sourceSurface: sourceSurface,
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
      final storage = StorageService();
      final deviceId =
          (await storage.getSecureString('device_id')) ??
          (await storage.getString('device_id'));
      final data = <String, dynamic>{
        'push_token': token,
        'language': LocalizedMessages.currentLanguageCode,
      };
      if (deviceId != null && deviceId.isNotEmpty) {
        data['device_id'] = deviceId;
      }
      data.addAll(await AnalyticsService().getBackendMeasurementIdentity());
      await ApiClient().post('/vpn/device/push-token', data: data);
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
    Map<String, dynamic> data,
  ) async {
    final fln = _localNotifications;
    if (fln == null) return;
    final nid =
        (messageId?.hashCode ?? DateTime.now().microsecondsSinceEpoch) &
        0x7fffffff;
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
      payload: data['event'] == 'lifecycle_message'
          ? 'lifecycle:${jsonEncode(data)}'
          : 'open_journal',
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
    InAppEventBannerService.instance.show(
      title: pair.title,
      body: pair.body,
      data: Map<String, dynamic>.from(message.data),
      actionLabel: message.data['event'] == 'lifecycle_message'
          ? ((message.data['cta'] ?? '').toString().trim().isNotEmpty
                ? message.data['cta'].toString().trim()
                : (LocalizedMessages.currentLanguageCode == 'ru'
                      ? 'Открыть'
                      : 'Open'))
          : null,
      onAction: message.data['event'] == 'lifecycle_message'
          ? () => unawaited(
              _openLifecycleMessage(
                Map<String, dynamic>.from(message.data),
                sourceSurface: 'foreground_banner',
              ),
            )
          : null,
    );
    // Lifecycle messages already have an in-app banner with a CTA. Showing a
    // local notification as well would duplicate the same message in foreground.
    if (message.data['event'] != 'lifecycle_message') {
      await _showLocalBanner(
        pair.title,
        pair.body,
        message.messageId,
        l10n,
        Map<String, dynamic>.from(message.data),
      );
    }
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
    await _openLifecycleMessage(
      Map<String, dynamic>.from(message.data),
      sourceSurface: 'fcm_opened_app',
    );
    _logger.info('Push opened app: ${message.data}', 'PushNotificationService');
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
    await _openLifecycleMessage(
      Map<String, dynamic>.from(message.data),
      sourceSurface: 'fcm_initial_message',
    );
    _logger.info(
      'Push initial message: ${message.data}',
      'PushNotificationService',
    );
  }

  @visibleForTesting
  static String? safeLifecycleRoute(Map<String, dynamic> data) {
    if (data['event']?.toString() != 'lifecycle_message') return null;
    final route = data['route']?.toString().trim() ?? '';
    const allowedRoutes = <String>{
      '/main',
      '/trial-ended',
      '/split-tunnel',
      '/notification-journal',
      '/payment',
    };
    return allowedRoutes.contains(route) ? route : null;
  }

  @visibleForTesting
  static Uri? safeLifecycleExternalUrl(Map<String, dynamic> data) {
    if (data['event']?.toString() != 'lifecycle_message') return null;
    final uri = Uri.tryParse(data['url']?.toString().trim() ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.toLowerCase() != 'granilink.com') {
      return null;
    }
    return uri;
  }

  Future<void> _openLifecycleMessage(
    Map<String, dynamic> data, {
    required String sourceSurface,
  }) async {
    if (data['event']?.toString() != 'lifecycle_message') return;
    final campaignId = data['campaign_id']?.toString().trim() ?? '';
    final route = safeLifecycleRoute(data);
    final externalUrl = safeLifecycleExternalUrl(data);

    var opened = false;
    if (route != null) {
      for (var attempt = 0; attempt < 6; attempt++) {
        final navigator = appNavigatorKey.currentState;
        if (navigator != null) {
          await navigator.pushNamed(route);
          opened = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } else if (externalUrl != null) {
      opened = await launchUrl(
        externalUrl,
        mode: LaunchMode.externalApplication,
      );
    }

    if (opened && campaignId.isNotEmpty) {
      await AnalyticsService().logLifecycleMessageOpen(
        campaignId: campaignId,
        sourceSurface: sourceSurface,
      );
    }
    _logger.info(
      'Lifecycle message action campaign=$campaignId route=$route '
          'url=${externalUrl?.host ?? '-'} opened=$opened source=$sourceSurface',
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
