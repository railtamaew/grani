import 'package:flutter/material.dart';

import '../theme.dart';

/// SnackBar с красным текстом на розовом фоне (ошибки, предупреждения).
SnackBar _buildErrorSnackBar(String message, {Duration? duration}) {
  return SnackBar(
    content: Text(
      message,
      style: const TextStyle(
        color: GraniTheme.errorText,
        fontFamily: 'Montserrat',
        fontSize: 14,
      ),
    ),
    backgroundColor: GraniTheme.errorBackground,
    behavior: SnackBarBehavior.floating,
    duration: duration ?? const Duration(seconds: 3),
  );
}

/// Показывает SnackBar с красным текстом на розовом фоне (ошибки, предупреждения).
void showErrorSnackBar(BuildContext context, String message, {Duration? duration}) {
  ScaffoldMessenger.of(context).showSnackBar(_buildErrorSnackBar(message, duration: duration));
}

/// Показывает SnackBar ошибки через [ScaffoldMessengerState] (для вызова после навигации, когда context может быть недействителен).
void showErrorSnackBarWithMessenger(ScaffoldMessengerState messenger, String message, {Duration? duration}) {
  messenger.showSnackBar(_buildErrorSnackBar(message, duration: duration));
}

/// Показывает SnackBar с нейтральным стилем (успех, информация).
/// Фон #F4F6F8, текст #192F3F.
void showInfoSnackBar(BuildContext context, String message, {Duration? duration}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        message,
        style: const TextStyle(
          color: GraniTheme.primaryText,
          fontFamily: 'Montserrat',
          fontSize: 14,
        ),
      ),
      backgroundColor: GraniTheme.cardBackground,
      behavior: SnackBarBehavior.floating,
      duration: duration ?? const Duration(seconds: 3),
    ),
  );
}
