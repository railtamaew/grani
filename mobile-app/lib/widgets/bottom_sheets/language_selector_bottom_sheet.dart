import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/session/locale_controller.dart';
import '../../services/auth_service.dart';
import '../../services/push_notification_service.dart';
import '../../l10n/app_localizations.dart';
import '../../theme.dart';

/// Выбор языка приложения — визуально как [ProtocolSelectorBottomSheet] / серверы.
class LanguageSelectorBottomSheet extends StatelessWidget {
  const LanguageSelectorBottomSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      enableDrag: true,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => const LanguageSelectorBottomSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screenWidth = media.size.width;
    final screenHeight = media.size.height;

    const designWidth = 412.0;
    final scaleX = screenWidth / designWidth;
    final scaleY = screenHeight / 917.0;

    return DraggableScrollableSheet(
      initialChildSize: 0.38,
      minChildSize: 0.32,
      maxChildSize: 0.55,
      builder: (context, scrollController) {
        final l10n = AppLocalizations.of(context)!;
        return ClipRRect(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(18 * scaleX),
            topRight: Radius.circular(18 * scaleX),
          ),
          child: Container(
            decoration: const BoxDecoration(
              gradient: GraniTheme.startScreenBackgroundGradient,
            ),
            child: Stack(
              children: [
                Positioned(
                  top: 31 * scaleY,
                  left: (screenWidth - 69 * scaleX) / 2,
                  child: Container(
                    width: 69 * scaleX,
                    height: 4 * scaleY,
                    decoration: BoxDecoration(
                      color: GraniTheme.surfaceControlBorder,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Positioned(
                  top: 58 * scaleY,
                  left: 31 * scaleX,
                  child: Text(
                    l10n.profileLanguage,
                    style: GraniTheme.headingSmall.copyWith(
                      fontSize: 24 * scaleX,
                      letterSpacing: -0.96 * scaleX,
                      height: 0.9,
                      color: GraniTheme.primaryText,
                    ),
                  ),
                ),
                Positioned(
                  top: 107 * scaleY,
                  left: (screenWidth - 312 * scaleX) / 2,
                  right: (screenWidth - 312 * scaleX) / 2,
                  bottom: media.padding.bottom + 32 * scaleY,
                  child: Consumer<LocaleController>(
                    builder: (context, controller, _) {
                      final current =
                          controller.locale.languageCode.toLowerCase();
                      return ListView(
                        controller: scrollController,
                        padding: EdgeInsets.zero,
                        children: [
                          _LanguageOptionRow(
                            label: l10n.appLanguageEnglish,
                            isSelected: current == 'en',
                            scaleX: scaleX,
                            scaleY: scaleY,
                            onTap: () async {
                              await controller.setLocale(const Locale('en'));
                              if (!context.mounted) return;
                              unawaited(
                                Provider.of<AuthService>(context, listen: false)
                                    .syncPreferredLanguage('en'),
                              );
                              unawaited(
                                  PushNotificationService().syncLanguage());
                              if (context.mounted) Navigator.of(context).pop();
                            },
                          ),
                          SizedBox(height: 10 * scaleY),
                          _LanguageOptionRow(
                            label: l10n.appLanguageRussian,
                            isSelected: current == 'ru',
                            scaleX: scaleX,
                            scaleY: scaleY,
                            onTap: () async {
                              await controller.setLocale(const Locale('ru'));
                              if (!context.mounted) return;
                              unawaited(
                                Provider.of<AuthService>(context, listen: false)
                                    .syncPreferredLanguage('ru'),
                              );
                              unawaited(
                                  PushNotificationService().syncLanguage());
                              if (context.mounted) Navigator.of(context).pop();
                            },
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LanguageOptionRow extends StatelessWidget {
  final String label;
  final bool isSelected;
  final double scaleX;
  final double scaleY;
  final VoidCallback onTap;

  const _LanguageOptionRow({
    required this.label,
    required this.isSelected,
    required this.scaleX,
    required this.scaleY,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(25 * scaleX),
      child: Container(
        height: 57 * scaleY,
        padding: EdgeInsets.only(
          left: 20 * scaleX,
          right: 20 * scaleX,
          top: 10 * scaleY,
          bottom: 10 * scaleY,
        ),
        decoration: GraniTheme.graniSurfaceDecoration(
          radius: 25 * scaleX,
          borderColor: isSelected
              ? GraniTheme.connectedStatus
              : GraniTheme.surfaceControlBorder,
          borderOpacity: isSelected ? 0.32 : 0.86,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontWeight: FontWeight.w400,
                  fontSize: 16 * scaleX,
                  letterSpacing: -0.64 * scaleX,
                  height: 0.9,
                  color: GraniTheme.primaryText,
                ),
              ),
            ),
            SizedBox(
              width: 24 * scaleX,
              height: 20 * scaleY,
              child: Icon(
                isSelected ? Icons.check_circle : Icons.circle_outlined,
                color: isSelected
                    ? GraniTheme.connectedStatus
                    : GraniTheme.secondaryText,
                size: 20 * scaleX,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
