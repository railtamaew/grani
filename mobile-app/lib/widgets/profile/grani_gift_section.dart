import 'package:flutter/material.dart';
import '../../theme.dart';
import '../grani_gift_art.dart';
import 'profile_ui_kit.dart';

/// All gift actions belong to one card. Callbacks retain their separate routes.
class GraniGiftSection extends StatelessWidget {
  const GraniGiftSection({
    super.key,
    required this.onShare,
    required this.onReceive,
    required this.onBonuses,
    this.rewardDays = 3,
  }) : assert(rewardDays == 3 || rewardDays == 4);

  final VoidCallback onShare;
  final VoidCallback onReceive;
  final VoidCallback onBonuses;
  final int rewardDays;

  @override
  Widget build(BuildContext context) {
    final ru = Localizations.localeOf(context).languageCode == 'ru';
    return GraniSectionCard(
      key: const ValueKey('profile-gifts-card'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Material(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              key: const ValueKey('profile-gift-share'),
              onTap: onShare,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    const GraniGiftArt(size: 64),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            ru ? 'Делитесь GRANI.' : 'Share GRANI.',
                            style: GraniTheme.bodyMedium.copyWith(
                              fontSize: 16,
                              height: 1.2,
                              fontWeight: FontWeight.w700,
                              color: GraniTheme.primaryText,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            ru
                                ? '7 дней другу, а вам $rewardDays!'
                                : '7 days for your friend, $rewardDays for you!',
                            style: GraniTheme.bodyMedium.copyWith(
                              fontSize: 14,
                              height: 1.25,
                              fontWeight: FontWeight.w500,
                              color: GraniTheme.primaryText,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.chevron_right,
                        size: 20, color: GraniTheme.secondaryText),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: GraniTheme.surfaceVariant),
            _GiftAction(
              key: const ValueKey('profile-gift-receive'),
              icon: Icons.redeem,
              label: ru ? 'Мне подарили' : 'Receive a gift',
              onTap: onReceive,
            ),
            const Divider(height: 1, color: GraniTheme.surfaceVariant),
            _GiftAction(
              key: const ValueKey('profile-gift-bonuses'),
              icon: Icons.history,
              label: ru ? 'Мои бонусы' : 'My bonuses',
              onTap: onBonuses,
            ),
          ],
        ),
      ),
    );
  }
}

class _GiftAction extends StatelessWidget {
  const _GiftAction(
      {super.key,
      required this.icon,
      required this.label,
      required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(children: [
              Icon(icon, size: 24, color: GraniTheme.primaryText),
              const SizedBox(width: 14),
              Expanded(
                  child: Text(label,
                      style: GraniTheme.bodyMedium.copyWith(
                          fontSize: 15,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          color: GraniTheme.primaryText))),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right,
                  size: 20, color: GraniTheme.secondaryText),
            ]),
          ),
        ),
      );
}
