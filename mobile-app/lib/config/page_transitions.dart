import 'package:flutter/material.dart';
import 'animations.dart';

/// Кастомные переходы между экранами.
/// Наследует MaterialPageRoute для корректной поддержки predictive back
/// на Android 14+ и интерактивного pop gesture на iOS.
class SlideFadePageRoute<T> extends MaterialPageRoute<T> {
  final bool slideFromRight;

  SlideFadePageRoute({
    required Widget child,
    this.slideFromRight = true,
    super.settings,
  }) : super(builder: (_) => child);

  @override
  Duration get transitionDuration => AppAnimations.screenTransitionDuration;

  @override
  Duration get reverseTransitionDuration => AppAnimations.screenTransitionDuration;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final screenWidth = MediaQuery.of(context).size.width;
    final offsetValue = slideFromRight ? 1.0 : -1.0;
    final slideAnimation = Tween<Offset>(
      begin: Offset(offsetValue * AppAnimations.screenTransitionOffset / screenWidth, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: animation,
      curve: AppAnimations.screenTransitionCurve,
    ));

    final fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: animation,
      curve: AppAnimations.screenTransitionCurve,
    ));

    return SlideTransition(
      position: slideAnimation,
      child: FadeTransition(
        opacity: fadeAnimation,
        child: child,
      ),
    );
  }
}

/// Генератор маршрутов с анимациями
class AnimatedRouteGenerator {
  static Route<T>? generateRoute<T extends Object?>(
    RouteSettings settings,
    Widget Function(BuildContext) builder, {
    bool slideFromRight = true,
  }) {
    return SlideFadePageRoute<T>(
      child: Builder(
        builder: (context) => builder(context),
      ),
      slideFromRight: slideFromRight,
      settings: settings,
    );
  }
}

