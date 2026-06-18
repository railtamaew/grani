import 'package:flutter/material.dart';
import '../theme.dart';

/// Адаптивный виджет для заголовка с поддержкой maxLines, ellipsis и автоуменьшения шрифта
class AdaptiveTitleText extends StatelessWidget {
  final String text;
  final int maxLines;
  final double minScale;
  final TextStyle? style;
  final TextAlign? textAlign;

  const AdaptiveTitleText({
    super.key,
    required this.text,
    required this.maxLines,
    required this.minScale,
    this.style,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    final baseStyle = style ?? GraniTheme.headingLarge;

    return LayoutBuilder(
      builder: (context, constraints) {
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth),
          child: Text(
            text,
            style: baseStyle,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            softWrap: true,
            textAlign: textAlign,
          ),
        );
      },
    );
  }
}

/// Адаптивный виджет для подзаголовка с поддержкой maxLines и ellipsis
class AdaptiveSubtitleText extends StatelessWidget {
  final String text;
  final int maxLines;
  final TextStyle? style;
  final TextAlign? textAlign;

  const AdaptiveSubtitleText({
    super.key,
    required this.text,
    required this.maxLines,
    this.style,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    final baseStyle = style ?? GraniTheme.bodyMedium;

    return LayoutBuilder(
      builder: (context, constraints) {
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth),
          child: Text(
            text,
            style: baseStyle,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            softWrap: true,
            textAlign: textAlign,
          ),
        );
      },
    );
  }
}
