import 'package:flutter/material.dart';
import '../theme.dart';

/// Экран успешной регистрации
/// Показывается после успешной верификации email кода
class AuthRegisterSuccessScreen extends StatelessWidget {
  const AuthRegisterSuccessScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    // Размеры из макета (базовый экран 412x917)
    final designWidth = 412.0;
    final designHeight = 917.0;
    final scaleX = screenWidth / designWidth;
    final scaleY = screenHeight / designHeight;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(
          gradient: GraniTheme.startScreenBackgroundGradient,
        ),
        child: SafeArea(
          child: Stack(
            children: [
              // Logo - из Figma: x: 173, y: 64, width: 65, height: 39
              // layout_FY2YPY
              Positioned(
                top: 64 * scaleY,
                left: 173 * scaleX,
                child: SizedBox(
                  width: 65 * scaleX,
                  height: 39 * scaleY,
                  child: Image.asset(
                    'assets/images/figma/logo_grani_new.png',
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        width: 65 * scaleX,
                        height: 39 * scaleY,
                        color: Colors.grey[300],
                      );
                    },
                  ),
                ),
              ),

              // Illustration - из Figma: x: 78, y: 192, width: 250, height: 250
              // layout_LXD7B5, pic_success
              Positioned(
                top: 192 * scaleY,
                left: 78 * scaleX,
                child: SizedBox(
                  width: 250 * scaleX,
                  height: 250 * scaleY,
                  child: Image.asset(
                    'assets/images/figma/pic_success.png',
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        color: Colors.grey[300],
                        child: const Icon(Icons.check_circle,
                            size: 100, color: Colors.green),
                      );
                    },
                  ),
                ),
              ),

              // Text Block - из Figma: x: 38, y: 472, width: 341, gap: 26px
              // layout_1UDCWA, style_C964TI (title), style_U79CAS (subtitle)
              Positioned(
                top: 472 * scaleY,
                left: 38 * scaleX,
                child: SizedBox(
                  width: 341 * scaleX,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Заголовок "Спасибо за регистрацию" - style_C964TI
                      Text(
                        'Спасибо за регистрацию',
                        style: GraniTheme.headingMedium,
                        textAlign: TextAlign.left,
                      ),

                      SizedBox(height: 26 * scaleY),

                      // Описание - style_U79CAS
                      SizedBox(
                        width: 343 * scaleX,
                        child: Text(
                          'Вы успешно подтвердили email.\nТеперь вы можете пользоваться сервисом.',
                          style: GraniTheme.bodyLarge,
                          textAlign: TextAlign.left,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Кнопка "Перейти к подключению" - из Figma: x: 29, y: 658, width: 348, height: 62
              // layout_ANIHXQ, fill_7YBJAW (#182D3D), effect_6B9GU5, style_QHS048
              Positioned(
                top: 658 * scaleY,
                left: 29 * scaleX,
                child: GestureDetector(
                  onTap: () {
                    Navigator.pushReplacementNamed(context, '/main');
                  },
                  child: Container(
                    width: 348 * scaleX,
                    height: GraniTheme.buttonHeight * scaleY,
                    padding: EdgeInsets.symmetric(
                      horizontal: 28 * scaleX,
                      vertical: 18 * scaleY,
                    ),
                    decoration: BoxDecoration(
                      color: GraniTheme.buttonPrimary, // #182D3D
                      borderRadius: BorderRadius.circular(
                          GraniTheme.radiusButton * scaleX),
                      boxShadow: GraniTheme.primaryButtonShadowWithInset,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'Перейти к подключению',
                      style: GraniTheme.buttonTextMedium.copyWith(
                        fontSize: 22 * scaleX,
                        letterSpacing: 0.06 * 22 * scaleX,
                        color: GraniTheme.white,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
