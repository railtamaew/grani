import 'package:flutter_test/flutter_test.dart';
import '../lib/services/gift_notification_copy.dart';

void main() {
  for (final ru in [true, false]) {
    test('cached gift follows selected language ru=$ru without changing data',
        () {
      final data = <String, dynamic>{
        'event': 'referral_gift_received',
        'trial_days': '7',
        'added_days': '4',
        'title': 'Gift activated',
        'notification_id': 'same-id',
      };
      final original = Map<String, dynamic>.from(data);
      final copy = giftNotificationCopy(data, russian: ru)!;
      expect(copy.title, ru ? 'Подарок активирован' : 'Gift activated');
      expect(copy.body, contains(ru ? 'Всего 7 дней' : '7 days total'));
      expect(data, original);
    });
    for (final days in [3, 4]) {
      test('reward keeps actual $days days ru=$ru', () {
        final copy = giftNotificationCopy({
          'event': 'referral_reward_granted',
          'bonus_days': '$days',
        }, russian: ru)!;
        expect(
            copy.title,
            ru
                ? 'Вам начислено $days бонусных дня'
                : 'You earned $days bonus days');
      });
    }
  }
  test('numeric metadata from cached JSON also works', () {
    expect(
        giftNotificationCopy({
          'event': 'referral_gift_received',
          'trial_days': 7,
          'added_days': 4
        }, russian: true)
            ?.title,
        'Подарок активирован');
  });
  test('unknown and incomplete metadata keeps original fallback', () {
    for (final data in <Map<String, dynamic>>[
      {},
      {'event': 'payment_completed'},
      {'event': 'referral_gift_received'},
      {'event': 'referral_reward_granted', 'bonus_days': '20'},
      {
        'event': 'referral_gift_received',
        'trial_days': '10',
        'added_days': '7'
      },
    ]) {
      expect(giftNotificationCopy(data, russian: true), isNull);
    }
  });
}
