import 'package:flutter/material.dart';

import 'grani_top_icon_button.dart';
import 'grani_gift_art.dart';
import '../theme.dart';

class VpnTopBar extends StatelessWidget {
  const VpnTopBar({
    super.key,
    required this.scaleX,
    required this.scaleY,
    required this.onMenuTap,
    required this.onShareTap,
  });

  final double scaleX;
  final double scaleY;
  final VoidCallback onMenuTap;
  final VoidCallback onShareTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20 * scaleX,
          12 * scaleY,
          20 * scaleX,
          12 * scaleY,
        ),
        child: Row(
          children: [
            SizedBox(
                width: 72,
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: GraniTopIconButton(
                      assetName: 'assets/images/figma/profile/menu_new.svg',
                      onTap: onMenuTap,
                      width: 40 * scaleX,
                      height: 40 * scaleY,
                      iconWidth: 26 * scaleX,
                      iconHeight: 20 * scaleY,
                      surfaceSize: 38 * scaleX,
                      fallbackIcon: Icons.menu,
                    ))),
            const Spacer(),
            SizedBox(
              width: GraniTheme.logoWidth * 1.08 * scaleX,
              height: GraniTheme.logoHeight * 1.08 * scaleY,
              child: Image.asset(
                'assets/images/figma/logo_grani_new.png',
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return Icon(
                    Icons.vpn_key,
                    size: 28 * scaleX,
                    color: GraniTheme.primaryText,
                  );
                },
              ),
            ),
            const Spacer(),
            Semantics(
                button: true,
                label: Localizations.localeOf(context).languageCode == 'ru'
                    ? 'Подарить другу 7 дней GRANI'
                    : 'Give a friend 7 days of GRANI',
                child: Tooltip(
                    message:
                        Localizations.localeOf(context).languageCode == 'ru'
                            ? 'Подарить другу'
                            : 'Give a friend a gift',
                    child: InkResponse(
                        onTap: onShareTap,
                        radius: 36,
                        child: const GraniGiftArt(size: 72)))),
          ],
        ),
      ),
    );
  }
}
