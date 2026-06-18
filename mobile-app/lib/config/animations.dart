import 'package:flutter/material.dart';

/// Типы анимаций кнопок
enum ButtonAnimationType {
  scale,      // Масштабирование при нажатии (по умолчанию)
  shake,      // Тряска при ошибке
  pulse,      // Пульсация при успехе
  bounce,     // Отскок при нажатии
  rotate,     // Вращение при нажатии
  glow,       // Свечение при нажатии
  slide,      // Скольжение при нажатии
  elastic,    // Эластичная анимация
}

/// Константы для анимаций приложения
/// Централизованное управление длительностями и кривыми анимаций
class AppAnimations {
  // Длительности анимаций (в миллисекундах)
  static const Duration buttonPressDuration = Duration(milliseconds: 150);
  static const Duration cardAppearDuration = Duration(milliseconds: 300);
  static const Duration switchToggleDuration = Duration(milliseconds: 150);
  static const Duration modalAppearDuration = Duration(milliseconds: 300);
  static const Duration screenTransitionDuration = Duration(milliseconds: 350);
  static const Duration shakeDuration = Duration(milliseconds: 500);
  static const Duration pulseDuration = Duration(milliseconds: 400);
  static const Duration shimmerDuration = Duration(milliseconds: 1500);
  static const Duration bounceDuration = Duration(milliseconds: 300);
  static const Duration rotateDuration = Duration(milliseconds: 200);
  static const Duration glowDuration = Duration(milliseconds: 250);
  static const Duration slideDuration = Duration(milliseconds: 200);
  static const Duration elasticDuration = Duration(milliseconds: 400);
  
  // Задержки между элементами
  static const Duration staggerDelay = Duration(milliseconds: 50);
  static const Duration cardStaggerDelay = Duration(milliseconds: 100);
  
  // Кривые анимаций
  static const Curve buttonPressCurve = Curves.easeOutCubic;
  static const Curve cardAppearCurve = Curves.easeOut;
  static const Curve switchToggleCurve = Curves.easeInOut;
  static const Curve modalAppearCurve = Curves.easeOutBack;
  static const Curve screenTransitionCurve = Curves.easeInOutQuad;
  static const Curve shakeCurve = Curves.elasticIn;
  static const Curve pulseCurve = Curves.easeInOut;
  static const Curve bounceCurve = Curves.easeOutBack;
  static const Curve rotateCurve = Curves.easeInOut;
  static const Curve glowCurve = Curves.easeInOut;
  static const Curve slideCurve = Curves.easeOut;
  static const Curve elasticCurve = Curves.elasticOut;
  
  // Параметры анимаций
  static const double buttonPressScale = 0.95;
  static const double cardInitialOffset = 20.0;
  static const double screenTransitionOffset = 100.0;
  static const double modalInitialScale = 0.8;
  static const double pulseScale = 1.05;
  static const double shakeOffset = 10.0;
  static const double bounceScale = 0.9;
  static const double rotateAngle = 0.1; // в радианах
  static const double glowIntensity = 0.3;
  static const double slideOffset = 5.0;
  static const double elasticScale = 0.85;
  
  // Приватный конструктор для предотвращения создания экземпляров
  AppAnimations._();
}



