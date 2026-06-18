import 'package:flutter/material.dart';

/// Компонент сообщения об ошибке для экранов авторизации
/// 
/// Параметры:
/// - Высота: 48px
/// - Радиус: 12px
/// - Фон: #FFDEDE
/// - Текст: #B40000
/// - Иконка: Warning 18px
/// - Расположение: над инпутом, отступ 8px
/// - Анимация: Fade In 150ms
class ErrorMessage extends StatefulWidget {
  final String message;
  final bool visible;

  const ErrorMessage({
    super.key,
    required this.message,
    this.visible = true,
  });

  @override
  State<ErrorMessage> createState() => _ErrorMessageState();
}

class _ErrorMessageState extends State<ErrorMessage>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeIn,
    ));
    
    if (widget.visible) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(ErrorMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) {
      _controller.forward(from: 0);
    } else if (!widget.visible && oldWidget.visible) {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible && _fadeAnimation.value == 0) {
      return const SizedBox.shrink();
    }

    return FadeTransition(
      opacity: _fadeAnimation,
      child: Container(
        height: 48.0,
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        decoration: BoxDecoration(
          color: const Color(0xFFFFDEDE), // #FFDEDE
          borderRadius: BorderRadius.circular(12.0),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.warning_amber_rounded,
              size: 18.0,
              color: const Color(0xFFB40000), // #B40000
            ),
            const SizedBox(width: 8.0),
            Expanded(
              child: Text(
                widget.message,
                style: const TextStyle(
                  fontFamily: 'Montserrat',
                  fontWeight: FontWeight.w400,
                  fontSize: 14.0,
                  color: Color(0xFFB40000), // #B40000
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

