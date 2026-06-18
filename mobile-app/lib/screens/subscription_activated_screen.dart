import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme.dart';
import '../l10n/l10n.dart';
import '../widgets/auth_logo.dart';
import '../widgets/button_connection.dart';
import 'bottom_sheet_profile.dart';

/// Экран "Подписка активирована"
/// Подтверждает успешную оплату и даёт доступ к VPN.
///
/// **Не используется в основном потоке** (план оптимизации после вёрстки).
/// После успешной оплаты пользователь переходит сразу на /home с toast
/// «Подписка активирована» (TrialEndedScreen._purchase). Маршрут /subscription-activated
/// редиректит на /home. Экран оставлен для legacy/deep link.
class SubscriptionActivatedScreen extends StatelessWidget {
  const SubscriptionActivatedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    final designWidth = 412.0;
    final designHeight = 917.0;
    final scaleX = screenWidth / designWidth;
    final scaleY = screenHeight / designHeight;

    return Scaffold(
      backgroundColor: GraniTheme.primaryBackground,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            // Navigation bars
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                height: GraniTheme.navigationBarHeight * scaleY,
                color: Colors.transparent,
              ),
            ),

            // Menu Icon - из Figma: x: 33, y: 53, width: 32, height: 29
            Positioned(
              top: 53 * scaleY,
              left: 33 * scaleX,
              child: GestureDetector(
                onTap: () {
                  showProfileDrawer(context);
                },
                child: SizedBox(
                  width: 32 * scaleX,
                  height: 33 * scaleY,
                  child: SvgPicture.asset(
                    'assets/images/figma/profile/menu_new.svg',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),

            // Logo - из Figma: x: 173, y: 48, width: 65, height: 39
            Positioned(
              top: 48 * scaleY,
              left: (screenWidth - 65 * scaleX) / 2,
              child: SizedBox(
                width: 65 * scaleX,
                height: 39 * scaleY,
                child: Image.asset(
                  'assets/images/figma/logo_grani_new.png',
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return AuthLogo();
                  },
                ),
              ),
            ),

            // Illustration (pic) - из Figma: x: 131, y: 140, width: 149, height: 149
            Positioned(
              top: 140 * scaleY,
              left: (screenWidth - 149 * scaleX) / 2,
              child: SizedBox(
                width: 149 * scaleX,
                height: 149 * scaleY,
                child: Image.asset(
                  'assets/images/figma/pic1_welcome_babushka.png',
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      color: Colors.grey[300],
                      child: const Icon(Icons.person, size: 60),
                    );
                  },
                ),
              ),
            ),

            // Text Block - из Figma: x: 15, y: 336, width: 383, gap: 8px
            Positioned(
              top: 336 * scaleY,
              left: (screenWidth - 383 * scaleX) / 2,
              child: SizedBox(
                width: 383 * scaleX,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Заголовок "Подписка активирована!"
                    Text(
                      l10n.subscriptionActivatedTitle,
                      style: TextStyle(
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w400,
                        fontSize: 24 * scaleX,
                        height: 0.9,
                        letterSpacing: -0.96 * scaleX,
                        color: GraniTheme.primaryText,
                      ),
                    ),
                    SizedBox(height: 8 * scaleY),
                    // Описание "Доступ открыт! 1 месяц полной скорости и защиты"
                    Text(
                      l10n.subscriptionActivatedSubtitle,
                      style: TextStyle(
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w300,
                        fontSize: 16 * scaleX,
                        height: 0.97,
                        letterSpacing: 0.96 * scaleX,
                        color: GraniTheme.primaryText,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Background Box (положка) - из Figma: x: 20, y: 467, width: 372, height: 343
            Positioned(
              top: 467 * scaleY,
              left: (screenWidth - 372 * scaleX) / 2,
              child: Container(
                width: 372 * scaleX,
                height: 343 * scaleY,
                decoration: BoxDecoration(
                  gradient: GraniTheme.surfaceControlGradient,
                  borderRadius: BorderRadius.circular(28 * scaleX),
                  border: Border.all(
                    color: GraniTheme.surfaceControlBorder.withOpacity(0.86),
                  ),
                  boxShadow: GraniTheme.surfaceControlShadowStrong
                      .map((shadow) => BoxShadow(
                            color: shadow.color,
                            offset: Offset(shadow.offset.dx * scaleX,
                                shadow.offset.dy * scaleY),
                            blurRadius: shadow.blurRadius * scaleX,
                            spreadRadius: shadow.spreadRadius * scaleX,
                          ))
                      .toList(),
                ),
                child: Stack(
                  children: [
                    // Protocol Grid - из Figma: x: 45, y: 489 (относительно экрана), width: 330, height: 53
                    // Относительно карточки: top: 489 - 467 = 22, left: 45 - 20 = 25
                    Positioned(
                      top: 22 * scaleY, // 489 - 467 = 22
                      left: 25 * scaleX, // 45 - 20 = 25
                      child: SizedBox(
                        width: 330 * scaleX,
                        height: 53 * scaleY,
                        child: GridView.count(
                          crossAxisCount: 3,
                          mainAxisSpacing: 11 * scaleY,
                          crossAxisSpacing: 11 * scaleX,
                          childAspectRatio: (330 / 3) / (53 / 2),
                          physics: const NeverScrollableScrollPhysics(),
                          children: [
                            _buildProtocolItem(
                                'VLESS WS', false, scaleX, scaleY),
                            _buildProtocolItem(
                                'Hysteria 2', false, scaleX, scaleY),
                            _buildProtocolItem(
                                'WireGuard obf', true, scaleX, scaleY),
                          ],
                        ),
                      ),
                    ),

                    // Connection Button - из Figma: x: 119, y: 568 (относительно экрана), width: 173, height: 173
                    // Относительно карточки: top: 568 - 467 = 101, left: 119 - 20 = 99
                    Positioned(
                      top: 101 * scaleY, // 568 - 467 = 101
                      left: 99 * scaleX, // 119 - 20 = 99
                      child: ButtonConnection(
                        state: ButtonConnectionState.on,
                        onTap: () {
                          Navigator.pushNamed(context, '/main');
                        },
                        size: 173.0,
                        scaleX: scaleX,
                        scaleY: scaleY,
                      ),
                    ),

                    // Status Text "готово к подключению" - из Figma: x: 71, y: 767 (относительно экрана), width: 270, height: 22
                    // Относительно карточки: top: 767 - 467 = 300, left: 71 - 20 = 51
                    Positioned(
                      top: 300 * scaleY, // 767 - 467 = 300
                      left: 51 * scaleX, // 71 - 20 = 51
                      child: SizedBox(
                        width: 270 * scaleX,
                        height: 22 * scaleY,
                        child: Text(
                          l10n.subscriptionReadyToConnect,
                          style: TextStyle(
                            fontFamily: 'Montserrat',
                            fontWeight: FontWeight.w400,
                            fontSize: 24 * scaleX,
                            height: 0.9,
                            letterSpacing: -0.96 * scaleX,
                            color: GraniTheme.primaryText,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProtocolItem(
      String protocol, bool isSelected, double scaleX, double scaleY) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 19 * scaleX,
          height: 19 * scaleY,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isSelected
                ? GraniTheme.xrayActive
                : GraniTheme.protocolInactive,
          ),
        ),
        SizedBox(width: 5 * scaleX),
        Text(
          protocol,
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontWeight: FontWeight.w400,
            fontSize: 14 * scaleX,
            height: 0.9,
            letterSpacing: -0.56 * scaleX,
            color: GraniTheme.black,
          ),
        ),
      ],
    );
  }
}
