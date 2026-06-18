import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme.dart';

/// Единый компонент логотипа для экранов авторизации
/// По умолчанию: 37×48 px, 65px от SafeArea. Для стартового экрана можно передать размер и topOffset.
class AuthLogo extends StatelessWidget {
  const AuthLogo({
    super.key,
    this.logoWidth,
    this.logoHeight,
    this.topOffset,
  });

  final double? logoWidth;
  final double? logoHeight;
  final double? topOffset;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    const designWidth = 412.0;
    const designHeight = 917.0;
    final scaleX = size.width / designWidth;
    final scaleY = size.height / designHeight;
    final safeAreaTop = MediaQuery.of(context).padding.top;

    final w = logoWidth ?? GraniTheme.logoWidth * scaleX;
    final h = logoHeight ?? GraniTheme.logoHeight * scaleY;
    final top = topOffset ?? (safeAreaTop + 65.0);
    
    final leftOffset = (size.width - w) / 2;
    
    return Positioned(
      top: top,
      left: leftOffset,
      child: SizedBox(
        width: w,
        height: h,
        child: Image.asset(
          'assets/images/figma/logo_grani_new.png', // экспорт из Figma: python3 scripts/figma_export_logo.py
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return SvgPicture.asset(
              'assets/images/logo_new.svg',
              width: w,
              height: h,
              fit: BoxFit.contain,
            );
          },
        ),
      ),
    );
  }
}

