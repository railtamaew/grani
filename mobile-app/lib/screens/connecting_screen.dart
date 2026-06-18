import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import '../theme.dart';
import '../widgets/custom_widgets.dart';
import '../widgets/connection_block.dart';
import '../services/vpn_service.dart';
import '../widgets/button_connection.dart';

class ConnectingScreen extends StatelessWidget {
  const ConnectingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    
    // Размеры из макета (базовый экран 412x917)
    final designWidth = 412.0;
    final designHeight = 917.0;
    final scaleX = screenWidth / designWidth;
    final scaleY = screenHeight / designHeight;
    final titleBlockWidth = 354 * scaleX;
    
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Color(0xFFFFFFFF),
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFFF7F9FA),
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: GraniTheme.primaryBackground,
        body: SafeArea(
        child: Stack(
          children: [
            // Logo - из Figma: x: 171, y: 42, width: 65, height: 39
            Positioned(
              top: 42 * scaleY,
              left: 171 * scaleX,
              child: SizedBox(
                width: 65 * scaleX,
                height: 39 * scaleY,
                child: Image.asset(
                  'assets/images/figma/logo_grani_new.png',
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      color: Colors.grey[300],
                      child: const Icon(Icons.image_not_supported, size: 20),
                    );
                  },
                ),
              ),
            ),
            
            // Menu Icon - из Figma: x: 31, y: 47, width: 32, height: 29
            Positioned(
              top: 47 * scaleY,
              left: 31 * scaleX,
              child: SizedBox(
                width: 32 * scaleX,
                height: 33 * scaleY,
                child: SvgPicture.asset(
                  'assets/images/figma/profile/menu_new.svg',
                  fit: BoxFit.contain,
                ),
              ),
            ),
            
            // Text Block - из Figma: x: 17, y: 331, width: 354, gap: 10px
            Positioned(
              top: 331 * scaleY,
              left: (screenWidth - titleBlockWidth) / 2,
              child: SizedBox(
                width: titleBlockWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Заголовок "Идет подключение..."
                    // Стиль: Montserrat, 400, 32px, lineHeight: 0.9, letterSpacing: -4%
                    Text(
                      'Идет подключение...',
                      style: GraniTheme.headingLarge.copyWith(
                        fontSize: 32 * scaleX,
                        height: 0.9,
                        letterSpacing: -0.04 * 32 * scaleX,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    
                    SizedBox(height: 10 * scaleY),
                    
                    // Описание
                    // Стиль: Montserrat, 300, 16px, lineHeight: 0.97, letterSpacing: 6%
                    Text(
                      'Протестируй сервис - подключайся бесплатно, 24 часа.',
                      style: GraniTheme.bodyLarge.copyWith(
                        fontSize: 16 * scaleX,
                        height: 0.97,
                        letterSpacing: 0.06 * 16 * scaleX,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
            
            // Блок подключения (без скорости), отступ от низа как на макете
            Positioned(
              bottom: GraniTheme.navigationBarHeight * scaleY + MediaQuery.of(context).padding.bottom,
              left: (screenWidth - GraniTheme.backgroundBoxWidth * scaleX) / 2,
              child: ConnectionBlock(
                scaleX: scaleX,
                scaleY: scaleY,
                showSpeedModule: false,
                connectionState: ButtonConnectionState.connecting,
                onConnectionTap: () {
                  final vpnService = Provider.of<VpnService>(context, listen: false);
                  vpnService.disconnect(source: 'connecting_screen_cancel');
                  Navigator.pushReplacementNamed(context, '/main');
                },
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

}
