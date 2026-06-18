import 'package:flutter/material.dart';
import '../config/animations.dart';

/// Анимированное модальное окно с эффектом scale + opacity
class AnimatedModal extends StatefulWidget {
  final Widget child;

  const AnimatedModal({
    super.key,
    required this.child,
  });

  @override
  State<AnimatedModal> createState() => _AnimatedModalState();
}

class _AnimatedModalState extends State<AnimatedModal>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: AppAnimations.modalAppearDuration,
      vsync: this,
    );

    _scaleAnimation = Tween<double>(
      begin: AppAnimations.modalInitialScale,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: AppAnimations.modalAppearCurve,
    ));

    _opacityAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: AppAnimations.modalAppearCurve,
    ));

    _controller.forward();
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
          child: Transform.scale(
            scale: _scaleAnimation.value,
            child: widget.child,
          ),
        );
      },
    );
  }
}



