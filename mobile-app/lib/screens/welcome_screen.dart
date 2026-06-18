import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme.dart';
import '../widgets/custom_widgets.dart';
import '../widgets/privacy_policy_bottom_sheet.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    
    // Размеры из макета (базовый экран 412x929)
    final designWidth = 412.0;
    final designHeight = 929.0;
    final scaleX = screenWidth / designWidth;
    final scaleY = screenHeight / designHeight;
    
    return Scaffold(
      backgroundColor: GraniTheme.primaryBackground,
      body: SafeArea(
        child: Stack(
          children: [
            // Main Image - бабушка (из макета: x: 132, y: 133, размер: 150x150)
            // В Figma это второй слой после android_UI
            Positioned(
              top: 133 * scaleY,
              left: 132 * scaleX,
              child: SizedBox(
                width: 150 * scaleX,
                height: 150 * scaleY,
                child: Image.asset(
                  'assets/images/figma/pic1_welcome_babushka.png',
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      color: Colors.grey[300],
                      child: const Icon(Icons.image_not_supported),
                    );
                  },
                ),
              ),
            ),
            
            // Text Content (из макета: x: 20, y: 335, width: 352, mode: column, gap: 20px)
            // В Figma это третий слой
            Positioned(
              top: 335 * scaleY,
              left: 20 * scaleX,
              child: SizedBox(
                width: 352 * scaleX,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Заголовок "Выходи за грани ограничений"
                    // Стиль: Montserrat, 400, 40px, lineHeight: 0.9, letterSpacing: -4%
                    Text(
                      'Выходи за грани ограничений',
                      style: GraniTheme.headingLarge.copyWith(
                        fontSize: 40 * scaleX,
                        height: 0.9,
                        letterSpacing: -0.04 * 40 * scaleX,
                      ),
                      textAlign: TextAlign.left,
                    ),
                    
                    SizedBox(height: 20 * scaleY),
                    
                    // Описание
                    // Стиль: Montserrat, 300, 16px, lineHeight: 0.97, letterSpacing: 6%
                    Text(
                      'Доступ ко всему миру,\nзащита и скорость - одним нажатием',
                      style: GraniTheme.bodyLarge.copyWith(
                        fontSize: 16 * scaleX,
                        height: 0.97,
                        letterSpacing: 0.06 * 16 * scaleX,
                      ),
                      textAlign: TextAlign.left,
                    ),
                  ],
                ),
              ),
            ),
            
            // Bottom Card - положка (из макета: x: 20, y: 514, размер: 372x291)
            // В Figma это четвертый слой
            Positioned(
              top: 514 * scaleY,
              left: 20 * scaleX,
              child: Container(
                width: 372 * scaleX,
                height: 291 * scaleY,
                decoration: BoxDecoration(
                  color: GraniTheme.cardBackground,
                  borderRadius: BorderRadius.circular(28 * scaleX),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      offset: Offset(0, -2 * scaleY),
                      blurRadius: 10 * scaleX,
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    // Buttons Group - buttoon (из макета: x: 55, y: 553 относительно родителя)
                    // Отступ от левого края положка: 55 - 20 = 35px
                    // Отступ от верха положка: 553 - 514 = 39px
                    Positioned(
                      top: 39 * scaleY,
                      left: 35 * scaleX,
                      child: SizedBox(
                        width: 303 * scaleX,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Google Login Button (высота: 70px из макета)
                            _buildWelcomeButton(
                              context: context,
                              text: 'Вход с Google',
                              onPressed: () {
                                // TODO: Implement Google authentication
                              },
                              icon: Container(
                                width: 30 * scaleX,
                                height: 30 * scaleY,
                                decoration: BoxDecoration(
                                  image: DecorationImage(
                                    image: AssetImage('assets/images/figma/google_logo.png'),
                                    fit: BoxFit.contain,
                                    onError: (exception, stackTrace) {
                                      // Fallback to old path if new one doesn't exist
                                    },
                                  ),
                                ),
                              ),
                              scaleX: scaleX,
                              scaleY: scaleY,
                            ),
                            
                            SizedBox(height: 19 * scaleY),
                            
                            // Email Login Button
                            _buildWelcomeButton(
                              context: context,
                              text: 'Вход с email',
                              onPressed: () {
                                Navigator.pushNamed(context, '/auth-email');
                              },
                              scaleX: scaleX,
                              scaleY: scaleY,
                            ),
                            
                            SizedBox(height: 19 * scaleY),
                            
                            // Privacy Policy Link - button3 (из макета: padding: 10px, center aligned)
                            GestureDetector(
                              onTap: () {
                                PrivacyPolicyBottomSheet.show(context);
                              },
                              child: Container(
                                width: double.infinity,
                                padding: EdgeInsets.all(10 * scaleX),
                                alignment: Alignment.center,
                                child: Text(
                                  'Подробнее о конфиденциальности',
                                  style: GraniTheme.bodySmall.copyWith(
                                    fontSize: 14 * scaleX,
                                    height: 0.97,
                                    letterSpacing: 0.06 * 14 * scaleX,
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
            ),
            
            // Logo (из макета: x: 174, y: 42, размер: 65x39)
            // В Figma это последний слой (поверх всего) - должен быть последним в Stack
            Positioned(
              top: 42 * scaleY,
              left: 174 * scaleX,
              child: SizedBox(
                width: 65 * scaleX,
                height: 39 * scaleY,
                child: Image.asset(
                  'assets/images/figma/logo_grani_new.png',
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    // Fallback to SVG if PNG doesn't exist
                    return SvgPicture.asset(
                      'assets/images/logo_new.svg',
                      width: 65 * scaleX,
                      height: 39 * scaleY,
                      fit: BoxFit.contain,
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildWelcomeButton({
    required BuildContext context,
    required String text,
    required VoidCallback? onPressed,
    Widget? icon,
    required double scaleX,
    required double scaleY,
  }) {
    // Стиль кнопки из макета: высота 70px, borderRadius 28px
    return Container(
      height: 70 * scaleY,
      decoration: BoxDecoration(
        color: GraniTheme.cardBackground,
        borderRadius: BorderRadius.circular(28 * scaleX),
        boxShadow: GraniTheme.buttonShadowStandard, // Единые тени с inner shadow
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(28 * scaleX),
          onTap: onPressed,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 5 * scaleX, vertical: 4 * scaleY),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(25 * scaleX),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.15),
                  offset: Offset(2 * scaleX, 2 * scaleY),
                  blurRadius: 0,
                ),
                BoxShadow(
                  color: Colors.white.withOpacity(1),
                  offset: Offset(2 * scaleX, 2 * scaleY),
                  blurRadius: 0,
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  icon,
                  SizedBox(width: 14.73 * scaleX),
                ],
                // Текст кнопки: Montserrat, 556, 24px, lineHeight: 1.1, letterSpacing: 6%, цвет: #A4ACB5
                Text(
                  text,
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w600, // 556 ≈ w600
                    fontSize: 24 * scaleX,
                    height: 1.1,
                    letterSpacing: 0.06 * 24 * scaleX,
                    color: GraniTheme.secondaryText, // #A4ACB5
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}