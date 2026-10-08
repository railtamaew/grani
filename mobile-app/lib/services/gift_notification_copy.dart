/// Render structured gift events in the chosen app language, including cached
/// notifications received before account language synchronization.
class GiftNotificationCopy {
  const GiftNotificationCopy(this.title, this.body);
  final String title;
  final String body;
}

GiftNotificationCopy? giftNotificationCopy(Map<String, dynamic> data,
    {required bool russian}) {
  final event = data['event']?.toString();
  if (event == 'referral_gift_received' &&
      data['trial_days']?.toString() == '7' &&
      data['added_days']?.toString() == '4') {
    return GiftNotificationCopy(
      russian ? 'Подарок активирован' : 'Gift activated',
      russian
          ? 'К 3 пробным дням добавлены 4 подарочных. Всего 7 дней с начала пробного периода, без карты и автосписания.'
          : '4 gift days added to your 3-day trial: 7 days total from the start of your trial. No card or automatic charge.',
    );
  }
  final days = data['bonus_days']?.toString();
  if (event == 'referral_reward_granted' && (days == '3' || days == '4')) {
    return GiftNotificationCopy(
      russian
          ? 'Вам начислено $days бонусных дня'
          : 'You earned $days bonus days',
      russian
          ? 'Друг подключился по вашему приглашению. Бонусные дни используются после пробного или оплаченного доступа.'
          : 'Your friend connected using your invitation. Bonus days are used after your trial or paid access.',
    );
  }
  // Unknown/incomplete metadata keeps its original copy rather than making up
  // granted days. This helper never changes IDs, records, read state or access.
  return null;
}
