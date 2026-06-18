import 'package:flutter/material.dart';

/// Режимы плотности UI для адаптации под разные размеры экранов
enum UiDensity {
  /// Нормальный режим - для экранов высотой >= 760px
  normal,
  
  /// Компактный режим - для экранов высотой 640-759px
  compact,
  
  /// Ультра-компактный режим - для экранов высотой < 640px или при открытой клавиатуре
  ultra,
}

/// Токены UI для разных режимов плотности
/// Содержит все значения отступов, размеров и ограничений для каждого режима
class UiTokens {
  /// Отступ логотипа сверху
  final double logoTop;
  
  /// Отступ между логотипом и иллюстрацией
  final double logoToIllustration;
  
  /// Масштаб иллюстрации (1.0 = 100%, 0.85 = 85%, 0.7 = 70%)
  final double illustrationScale;
  
  /// Отступ между иллюстрацией и текстом
  final double illustrationToText;
  
  /// Максимальное количество строк заголовка
  final int titleMaxLines;
  
  /// Минимальный масштаб шрифта заголовка (для автоуменьшения)
  final double titleMinScale;
  
  /// Максимальное количество строк подзаголовка
  final int subtitleMaxLines;
  
  /// Отступ между заголовком и подзаголовком
  final double textGap;
  
  /// Высота подложки (sheet) снизу
  final double sheetHeight;

  const UiTokens({
    required this.logoTop,
    required this.logoToIllustration,
    required this.illustrationScale,
    required this.illustrationToText,
    required this.titleMaxLines,
    required this.titleMinScale,
    required this.subtitleMaxLines,
    required this.textGap,
    required this.sheetHeight,
  });

  /// Получить токены для указанного режима плотности
  static UiTokens of(UiDensity density) {
    switch (density) {
      case UiDensity.normal:
        return const UiTokens(
          logoTop: 65.0,
          logoToIllustration: 25.0, // Синхронизировано с GraniTheme.logoToIllustrationGap
          illustrationScale: 0.6, // Уменьшено с 0.65 для большего пространства
          illustrationToText: 90.0, // Увеличено с 80.0 для предотвращения перекрытия
          titleMaxLines: 2,
          titleMinScale: 0.9,
          subtitleMaxLines: 3,
          textGap: 16.0,
          sheetHeight: 360.0,
        );
      
      case UiDensity.compact:
        return const UiTokens(
          logoTop: 50.0,
          logoToIllustration: 25.0, // Синхронизировано с GraniTheme.logoToIllustrationGap
          illustrationScale: 0.6, // Уменьшено с 0.65 для большего пространства
          illustrationToText: 90.0, // Увеличено с 80.0 для предотвращения перекрытия
          titleMaxLines: 2,
          titleMinScale: 0.85,
          subtitleMaxLines: 2,
          textGap: 16.0,
          sheetHeight: 340.0,
        );
      
      case UiDensity.ultra:
        return const UiTokens(
          logoTop: 40.0,
          logoToIllustration: 20.0, // Увеличено с 15.0 для лучшего отображения
          illustrationScale: 0.65, // Уменьшено с 0.7 для большего пространства
          illustrationToText: 40.0, // Увеличено с 30.0 для предотвращения перекрытия
          titleMaxLines: 1,
          titleMinScale: 0.8,
          subtitleMaxLines: 2,
          textGap: 12.0,
          sheetHeight: 320.0,
        );
    }
  }

  /// Определить режим плотности на основе размера экрана и состояния клавиатуры
  static UiDensity determineDensity(BuildContext context) {
    final mq = MediaQuery.of(context);
    final h = mq.size.height;
    final keyboardOpen = mq.viewInsets.bottom > 0;

    if (keyboardOpen || h < 640) {
      return UiDensity.ultra;
    } else if (h < 760) {
      return UiDensity.compact;
    } else {
      return UiDensity.normal;
    }
  }
}



