import 'package:flutter/material.dart';
import '../theme.dart';

/// Единый компонент текстового блока (Title + Subtitle) для экранов авторизации
/// 
/// Параметры:
/// - Ширина: 348px (по макету Figma)
/// - Gap между заголовком и подзаголовком: 22px
/// - Отступ слева: 32px (по макету Figma)
/// - Отступ от иллюстрации: 55px
/// 
/// Типографика:
/// - Title: Montserrat 400, 40px, line-height 0.9, letter-spacing -4%, color #192F3F, align left
/// - Subtitle: Montserrat 300, 16px, line-height 0.97, letter-spacing +6%, color #192F3F, align left
class AuthTextBlock extends StatelessWidget {
  final String title;
  final String subtitle;
  final double topOffset;
  final double? titleFontSize;
  final double? titleLetterSpacing;
  final double? subtitleFontSize;
  final double? subtitleLetterSpacing;
  final double? titleSubtitleGap;
  final double? leftOffset;

  const AuthTextBlock({
    super.key,
    required this.title,
    required this.subtitle,
    required this.topOffset,
    this.titleFontSize,
    this.titleLetterSpacing,
    this.subtitleFontSize,
    this.subtitleLetterSpacing,
    this.titleSubtitleGap,
    this.leftOffset,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    const designWidth = 412.0;
    const designHeight = 917.0;
    final scaleX = size.width / designWidth;
    final scaleY = size.height / designHeight;

    final textBlockWidth = GraniTheme.inputFieldWidth * scaleX;
    final left = leftOffset ?? (GraniTheme.authScreenHorizontalPadding * scaleX);
    final gap = titleSubtitleGap ?? (GraniTheme.titleSubtitleGap * scaleY);
    final titleSize = titleFontSize ?? (40 * scaleX);
    final titleSpacing = titleLetterSpacing ?? (-0.04 * 40 * scaleX);
    final subSize = subtitleFontSize ?? (16 * scaleX);
    final subSpacing = subtitleLetterSpacing;

    return Positioned(
      top: topOffset,
      left: left,
      child: SizedBox(
        width: textBlockWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: GraniTheme.headingLarge.copyWith(
                fontSize: titleSize,
                letterSpacing: titleSpacing,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: gap),
            Text(
              subtitle,
              style: GraniTheme.bodyLarge.copyWith(
                fontSize: subSize,
                letterSpacing: subSpacing,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

