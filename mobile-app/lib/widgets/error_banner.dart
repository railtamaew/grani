import 'package:flutter/material.dart';

/// Компонент баннера ошибки для показа внизу экрана.
/// Текст переносится на несколько строк (до 5), чтобы длинные сообщения были читаемы.
///
/// Параметры:
/// - Минимальная высота: 48px (растёт при многострочном тексте)
/// - Радиус: 12px
/// - Фон: #FFDEDE
/// - Текст: #B40000
/// - Иконка: Warning 18px
/// - Расположение: внизу экрана
/// - Анимация: Fade In 150ms
class ErrorBanner extends StatefulWidget {
  final String message;
  final bool visible;
  final VoidCallback? onDismiss;

  const ErrorBanner({
    super.key,
    required this.message,
    this.visible = true,
    this.onDismiss,
  });

  /// Убирает технический префикс "VpnException: " для более понятного отображения.
  static String _displayMessage(String raw) {
    if (raw.startsWith('VpnException: ')) {
      return raw.replaceFirst('VpnException: ', '');
    }
    return raw;
  }

  @override
  State<ErrorBanner> createState() => _ErrorBannerState();
}

class _ErrorBannerState extends State<ErrorBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

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
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0.0, 1.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));
    
    if (widget.visible) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(ErrorBanner oldWidget) {
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

    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          decoration: BoxDecoration(
            color: const Color(0xFFFFDEDE), // #FFDEDE
            borderRadius: BorderRadius.circular(12.0),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 4.0,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2.0),
                child: Icon(
                  Icons.warning_amber_rounded,
                  size: 18.0,
                  color: const Color(0xFFB40000), // #B40000
                ),
              ),
              const SizedBox(width: 8.0),
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 24.0),
                  child: Text(
                    ErrorBanner._displayMessage(widget.message),
                    style: const TextStyle(
                      fontFamily: 'Montserrat',
                      fontWeight: FontWeight.w400,
                      fontSize: 14.0,
                      color: Color(0xFFB40000), // #B40000
                      height: 1.3,
                    ),
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (widget.onDismiss != null) ...[
                const SizedBox(width: 4.0),
                IconButton(
                  icon: const Icon(
                    Icons.close,
                    size: 18.0,
                    color: Color(0xFFB40000),
                  ),
                  onPressed: widget.onDismiss,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}






