import 'package:flutter/material.dart';

import 'grani_top_icon_button.dart';
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
            GraniTopIconButton(
              assetName: 'assets/images/figma/profile/menu_new.svg',
              onTap: onMenuTap,
              width: 40 * scaleX,
              height: 40 * scaleY,
              iconWidth: 26 * scaleX,
              iconHeight: 20 * scaleY,
              surfaceSize: 38 * scaleX,
              fallbackIcon: Icons.menu,
            ),
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
            GraniTopIconButton(
              assetName: 'assets/images/figma/share_icon.svg',
              onTap: onShareTap,
              width: 40 * scaleX,
              height: 40 * scaleY,
              iconWidth: 22 * scaleX,
              iconHeight: 22 * scaleY,
              surfaceSize: 38 * scaleX,
              fallbackIcon: Icons.share,
            ),
          ],
        ),
      ),
    );
  }
}
