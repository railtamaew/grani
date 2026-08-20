import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/push_notification_service.dart';

void main() {
  group('PushNotificationService.offerForStatus', () {
    test('offers the system prompt while permission is undecided', () {
      expect(
        PushNotificationService.offerForStatus(
          AuthorizationStatus.notDetermined,
          supportsSettingsRecovery: true,
        ),
        NotificationPermissionOffer.requestSystemPermission,
      );
    });

    test('offers Android settings after permission was denied', () {
      expect(
        PushNotificationService.offerForStatus(
          AuthorizationStatus.denied,
          supportsSettingsRecovery: true,
        ),
        NotificationPermissionOffer.openSystemSettings,
      );
    });

    test('does not offer unsupported denied recovery', () {
      expect(
        PushNotificationService.offerForStatus(
          AuthorizationStatus.denied,
          supportsSettingsRecovery: false,
        ),
        NotificationPermissionOffer.none,
      );
    });

    for (final status in <AuthorizationStatus>[
      AuthorizationStatus.authorized,
      AuthorizationStatus.provisional,
    ]) {
      test('does not prompt for $status', () {
        expect(
          PushNotificationService.offerForStatus(
            status,
            supportsSettingsRecovery: true,
          ),
          NotificationPermissionOffer.none,
        );
      });
    }
  });

  group('PushNotificationService.offerForAndroidSnapshot', () {
    const android13Denied = AndroidNotificationPermissionSnapshot(
      enabled: false,
      runtimePermissionRequired: true,
      runtimePermissionGranted: false,
      sdkInt: 33,
    );

    test('requests Android 13 system permission before the first attempt', () {
      expect(
        PushNotificationService.offerForAndroidSnapshot(
          android13Denied,
          promptAttempted: false,
        ),
        NotificationPermissionOffer.requestSystemPermission,
      );
    });

    test(
      'offers settings only after Android 13 prompt was really attempted',
      () {
        expect(
          PushNotificationService.offerForAndroidSnapshot(
            android13Denied,
            promptAttempted: true,
          ),
          NotificationPermissionOffer.openSystemSettings,
        );
      },
    );

    test('uses settings recovery on Android 12 when notifications are off', () {
      expect(
        PushNotificationService.offerForAndroidSnapshot(
          const AndroidNotificationPermissionSnapshot(
            enabled: false,
            runtimePermissionRequired: false,
            runtimePermissionGranted: true,
            sdkInt: 31,
          ),
          promptAttempted: false,
        ),
        NotificationPermissionOffer.openSystemSettings,
      );
    });

    test('does nothing when notifications are already enabled', () {
      expect(
        PushNotificationService.offerForAndroidSnapshot(
          const AndroidNotificationPermissionSnapshot(
            enabled: true,
            runtimePermissionRequired: true,
            runtimePermissionGranted: true,
            sdkInt: 35,
          ),
          promptAttempted: false,
        ),
        NotificationPermissionOffer.none,
      );
    });
  });

  group('lifecycle push destination', () {
    test('accepts only registered internal routes', () {
      expect(
        PushNotificationService.safeLifecycleRoute(const {
          'event': 'lifecycle_message',
          'route': '/split-tunnel',
        }),
        '/split-tunnel',
      );
      expect(
        PushNotificationService.safeLifecycleRoute(const {
          'event': 'lifecycle_message',
          'route': '/windows',
        }),
        isNull,
      );
    });

    test('accepts only HTTPS granilink lifecycle URLs', () {
      expect(
        PushNotificationService.safeLifecycleExternalUrl(const {
          'event': 'lifecycle_message',
          'url': 'https://granilink.com/en/windows?utm_source=grani',
        })?.host,
        'granilink.com',
      );
      expect(
        PushNotificationService.safeLifecycleExternalUrl(const {
          'event': 'lifecycle_message',
          'url': 'https://example.com/redirect',
        }),
        isNull,
      );
    });
  });
}
