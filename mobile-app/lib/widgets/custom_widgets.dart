import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme.dart';
import '../config/animations.dart';

class CustomButton extends StatefulWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isPrimary;
  final bool isLoading;
  final double? width;
  final double? height;
  final Widget? icon;
  final bool showError;
  final bool showSuccess;
  final ButtonAnimationType? animationType;

  const CustomButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isPrimary = true,
    this.isLoading = false,
    this.width,
    this.height,
    this.icon,
    this.showError = false,
    this.showSuccess = false,
    this.animationType,
  });

  @override
  State<CustomButton> createState() => _CustomButtonState();
}

class _CustomButtonState extends State<CustomButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _shakeAnimation;
  late Animation<double> _pulseAnimation;
  late Animation<double> _bounceAnimation;
  late Animation<double> _rotateAnimation;
  late Animation<double> _glowAnimation;
  late Animation<double> _slideXAnimation;
  late Animation<double> _slideYAnimation;
  late Animation<double> _elasticAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: AppAnimations.buttonPressDuration,
      vsync: this,
    );
    
    // Анимация масштабирования (по умолчанию)
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: AppAnimations.buttonPressScale,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: AppAnimations.buttonPressCurve,
    ));

    // Анимация тряски
    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 0, end: -AppAnimations.shakeOffset), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: -AppAnimations.shakeOffset, end: AppAnimations.shakeOffset), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: AppAnimations.shakeOffset, end: -AppAnimations.shakeOffset), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: -AppAnimations.shakeOffset, end: AppAnimations.shakeOffset), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: AppAnimations.shakeOffset, end: 0), weight: 1),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: AppAnimations.shakeCurve,
    ));

    // Анимация пульсации
    _pulseAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 1.0, end: AppAnimations.pulseScale), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: AppAnimations.pulseScale, end: 1.0), weight: 1),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: AppAnimations.pulseCurve,
    ));

    // Анимация отскока
    _bounceAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 1.0, end: AppAnimations.bounceScale), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: AppAnimations.bounceScale, end: 1.05), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: 1.05, end: 1.0), weight: 1),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: AppAnimations.bounceCurve,
    ));

    // Анимация вращения
    _rotateAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 0, end: AppAnimations.rotateAngle), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: AppAnimations.rotateAngle, end: -AppAnimations.rotateAngle), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: -AppAnimations.rotateAngle, end: 0), weight: 1),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: AppAnimations.rotateCurve,
    ));

    // Анимация свечения
    _glowAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 0, end: AppAnimations.glowIntensity), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: AppAnimations.glowIntensity, end: 0), weight: 1),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: AppAnimations.glowCurve,
    ));

    // Анимации скольжения
    _slideXAnimation = Tween<double>(
      begin: 0,
      end: AppAnimations.slideOffset,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: AppAnimations.slideCurve,
    ));

    _slideYAnimation = Tween<double>(
      begin: 0,
      end: AppAnimations.slideOffset,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: AppAnimations.slideCurve,
    ));

    // Эластичная анимация
    _elasticAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 1.0, end: AppAnimations.elasticScale), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: AppAnimations.elasticScale, end: 1.1), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: 1.1, end: 1.0), weight: 1),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: AppAnimations.elasticCurve,
    ));
  }

  @override
  void didUpdateWidget(CustomButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showError && !oldWidget.showError) {
      _controller.duration = AppAnimations.shakeDuration;
      _controller.forward(from: 0);
    } else if (widget.showSuccess && !oldWidget.showSuccess) {
      _controller.duration = AppAnimations.pulseDuration;
      _controller.forward(from: 0);
    }
  }

  Duration _getAnimationDuration() {
    if (widget.showError) return AppAnimations.shakeDuration;
    if (widget.showSuccess) return AppAnimations.pulseDuration;
    
    final animationType = widget.animationType ?? ButtonAnimationType.scale;
    switch (animationType) {
      case ButtonAnimationType.bounce:
        return AppAnimations.bounceDuration;
      case ButtonAnimationType.rotate:
        return AppAnimations.rotateDuration;
      case ButtonAnimationType.glow:
        return AppAnimations.glowDuration;
      case ButtonAnimationType.slide:
        return AppAnimations.slideDuration;
      case ButtonAnimationType.elastic:
        return AppAnimations.elasticDuration;
      default:
        return AppAnimations.buttonPressDuration;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails details) {
    if (!widget.isLoading && widget.onPressed != null) {
      _controller.duration = _getAnimationDuration();
      _controller.forward();
    }
  }

  void _handleTapUp(TapUpDetails details) {
    if (!widget.isLoading && widget.onPressed != null) {
      _controller.reverse();
    }
  }

  void _handleTapCancel() {
    if (!widget.isLoading && widget.onPressed != null) {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAnimating = widget.showError || widget.showSuccess;
    final animationType = widget.animationType ?? ButtonAnimationType.scale;
    
    // Определяем, какую анимацию использовать
    Animation<double> activeAnimation;
    if (widget.showError) {
      activeAnimation = _shakeAnimation;
    } else if (widget.showSuccess) {
      activeAnimation = _pulseAnimation;
    } else {
      switch (animationType) {
        case ButtonAnimationType.bounce:
          activeAnimation = _bounceAnimation;
          break;
        case ButtonAnimationType.rotate:
          activeAnimation = _rotateAnimation;
          break;
        case ButtonAnimationType.glow:
          activeAnimation = _glowAnimation;
          break;
        case ButtonAnimationType.slide:
          activeAnimation = _slideXAnimation;
          break;
        case ButtonAnimationType.elastic:
          activeAnimation = _elasticAnimation;
          break;
        case ButtonAnimationType.shake:
          activeAnimation = _shakeAnimation;
          break;
        case ButtonAnimationType.pulse:
          activeAnimation = _pulseAnimation;
          break;
        default:
          activeAnimation = _scaleAnimation;
      }
    }

    return GestureDetector(
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      onTap: widget.isLoading ? null : widget.onPressed,
      child: AnimatedBuilder(
        animation: activeAnimation,
        builder: (context, child) {
          double scale = 1.0;
          double translateX = 0.0;
          double translateY = 0.0;
          double rotation = 0.0;
          double glowOpacity = 0.0;

          if (isAnimating) {
            if (widget.showError) {
              translateX = _shakeAnimation.value;
            } else if (widget.showSuccess) {
              scale = _pulseAnimation.value;
            }
          } else {
            switch (animationType) {
              case ButtonAnimationType.scale:
                scale = _scaleAnimation.value;
                break;
              case ButtonAnimationType.bounce:
                scale = _bounceAnimation.value;
                break;
              case ButtonAnimationType.rotate:
                rotation = _rotateAnimation.value;
                break;
              case ButtonAnimationType.glow:
                glowOpacity = _glowAnimation.value;
                break;
              case ButtonAnimationType.slide:
                translateX = _slideXAnimation.value;
                translateY = _slideYAnimation.value;
                break;
              case ButtonAnimationType.elastic:
                scale = _elasticAnimation.value;
                break;
              default:
                scale = _scaleAnimation.value;
            }
          }

          return Transform.scale(
            scale: scale,
            child: Transform.rotate(
              angle: rotation,
              child: Transform.translate(
                offset: Offset(translateX, translateY),
                child: Container(
                  width: widget.width,
                  height: widget.height ?? GraniTheme.buttonHeight, // 62px
                  decoration: BoxDecoration(
                    color: GraniTheme.cardBackground, // #F4F6F8
                    borderRadius: BorderRadius.circular(GraniTheme.radiusButton), // 25px
                    boxShadow: [
                      // Единые тени с inner shadow из theme.dart
                      ...GraniTheme.buttonShadowStandard,
                      // Эффект свечения (если используется)
                      if (animationType == ButtonAnimationType.glow && glowOpacity > 0)
                        BoxShadow(
                          color: GraniTheme.xrayActive.withOpacity(glowOpacity),
                          blurRadius: 15,
                          spreadRadius: 2,
                        ),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: widget.isLoading ? null : widget.onPressed,
                      borderRadius: BorderRadius.circular(GraniTheme.radiusButton),
                      onTapDown: (_) {
                        // При нажатии: opacity 70%
                      },
                      child: Opacity(
                        opacity: widget.isLoading || widget.onPressed == null ? 0.7 : 1.0,
                        child: Container(
                          padding: EdgeInsets.only(
                            left: GraniTheme.buttonPaddingLeft, // 20px
                            right: GraniTheme.buttonPaddingRight, // 14px
                          ),
                          height: GraniTheme.buttonHeight, // 62px
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(GraniTheme.radiusButton),
                            // Inner shadow эмулируется через белый контейнер (если нужно)
                          ),
                          child: Center(
                            child: widget.isLoading
                                ? SizedBox(
                                    width: GraniTheme.buttonIconSize, // 20px
                                    height: GraniTheme.buttonIconSize,
                                    child: const CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(GraniTheme.secondaryText),
                                    ),
                                  )
                                : Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (widget.icon != null) ...[
                                        SizedBox(
                                          width: GraniTheme.buttonIconSize, // 20×20px
                                          height: GraniTheme.buttonIconSize,
                                          child: widget.icon!,
                                        ),
                                        SizedBox(width: GraniTheme.buttonIconGap), // 12px отступ от текста
                                      ],
                                      Flexible(
                                        child: Text(
                                          widget.text,
                                          style: GraniTheme.buttonTextSecondary,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class CustomInputField extends StatelessWidget {
  final String hintText;
  final TextEditingController? controller;
  final bool obscureText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;

  const CustomInputField({
    super.key,
    required this.hintText,
    this.controller,
    this.obscureText = false,
    this.prefixIcon,
    this.suffixIcon,
    this.keyboardType,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: GraniTheme.inputFieldWidth, // 348px
      height: GraniTheme.inputHeight, // 62px
      decoration: BoxDecoration(
        color: GraniTheme.cardBackground, // #F4F6F8
        borderRadius: BorderRadius.circular(GraniTheme.radiusButton), // 25px
        boxShadow: GraniTheme.inputFieldShadow, // Единые тени
      ),
      child: TextFormField(
        controller: controller,
        obscureText: obscureText,
        keyboardType: keyboardType,
        validator: validator,
        style: GraniTheme.emailInputText, // Стандартизированный стиль
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: GraniTheme.emailPlaceholder, // Стандартизированный placeholder
          prefixIcon: prefixIcon != null
              ? SizedBox(
                  width: GraniTheme.buttonIconSize, // 20px
                  height: GraniTheme.buttonIconSize,
                  child: prefixIcon,
                )
              : null,
          suffixIcon: suffixIcon,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: GraniTheme.paddingXLarge,
            vertical: GraniTheme.paddingLarge,
          ),
        ),
      ),
    );
  }
}

class ProtocolIndicator extends StatelessWidget {
  final String protocol;
  final bool isActive;
  final VoidCallback? onTap;

  const ProtocolIndicator({
    super.key,
    required this.protocol,
    this.isActive = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: GraniTheme.protocolIndicatorSize,
            height: GraniTheme.protocolIndicatorSize,
            decoration: BoxDecoration(
              color: isActive ? GraniTheme.xrayActive : GraniTheme.protocolInactive,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            protocol,
            style: GraniTheme.protocolText,
          ),
        ],
      ),
    );
  }
}

class LogoWidget extends StatelessWidget {
  const LogoWidget({super.key});

  @override
  Widget build(BuildContext context) {
    // Логотип из макета: layout_3TISGW
    // Размеры: width 301.52, height 24.92
    // Padding: 0px 57px, gap: 8px
    return Container(
      width: 301.52,
      height: 24.92,
      padding: const EdgeInsets.symmetric(horizontal: 57),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Иконка логотипа (готовый)
          Image.asset(
            'assets/images/figma/logo_grani_new.png',
            height: 24.92,
            width: 65,
            fit: BoxFit.contain,
          ),
          const SizedBox(width: 8),
          // Текст "GRANI"
          Text(
            'GRANI',
            style: GraniTheme.bodyMedium.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
