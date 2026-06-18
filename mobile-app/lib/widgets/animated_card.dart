import 'package:flutter/material.dart';
import '../config/animations.dart';

/// Анимированная карточка с эффектом появления
class AnimatedCard extends StatefulWidget {
  final Widget child;
  final int index;
  final Duration? delay;
  final EdgeInsets? margin;
  final EdgeInsets? padding;
  final Color? color;
  final BorderRadius? borderRadius;
  final List<BoxShadow>? boxShadow;

  const AnimatedCard({
    super.key,
    required this.child,
    this.index = 0,
    this.delay,
    this.margin,
    this.padding,
    this.color,
    this.borderRadius,
    this.boxShadow,
  });

  @override
  State<AnimatedCard> createState() => _AnimatedCardState();
}

class _AnimatedCardState extends State<AnimatedCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacityAnimation;
  late Animation<double> _translateAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: AppAnimations.cardAppearDuration,
      vsync: this,
    );

    _opacityAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: AppAnimations.cardAppearCurve,
    ));

    _translateAnimation = Tween<double>(
      begin: AppAnimations.cardInitialOffset,
      end: 0.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: AppAnimations.cardAppearCurve,
    ));

    // Запускаем анимацию с задержкой
    final delay = widget.delay ??
        Duration(
          milliseconds: (widget.index * AppAnimations.cardStaggerDelay.inMilliseconds),
        );
    Future.delayed(delay, () {
      if (mounted) {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: _opacityAnimation.value,
          child: Transform.translate(
            offset: Offset(0, _translateAnimation.value),
            child: Container(
              margin: widget.margin,
              padding: widget.padding,
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: widget.borderRadius,
                boxShadow: widget.boxShadow,
              ),
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}

/// Виджет для анимированного списка карточек
class AnimatedCardList extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsets? itemMargin;
  final EdgeInsets? itemPadding;
  final Color? itemColor;
  final BorderRadius? itemBorderRadius;
  final List<BoxShadow>? itemBoxShadow;

  const AnimatedCardList({
    super.key,
    required this.children,
    this.itemMargin,
    this.itemPadding,
    this.itemColor,
    this.itemBorderRadius,
    this.itemBoxShadow,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: children.asMap().entries.map((entry) {
        final index = entry.key;
        final child = entry.value;
        return AnimatedCard(
          key: ValueKey(index),
          index: index,
          margin: itemMargin,
          padding: itemPadding,
          color: itemColor,
          borderRadius: itemBorderRadius,
          boxShadow: itemBoxShadow,
          child: child,
        );
      }).toList(),
    );
  }
}



