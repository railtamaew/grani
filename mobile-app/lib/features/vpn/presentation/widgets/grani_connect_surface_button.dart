import 'dart:math' as math;

import 'package:flutter/material.dart';

enum VpnConnectionState {
  disconnected,
  connecting,
  disconnecting,
  connected,
  error,
}

class GraniConnectSurfaceButton extends StatefulWidget {
  final VpnConnectionState state;
  final VoidCallback? onPressed;
  final String title;
  final String subtitle;
  final double size;
  final String? semanticsLabel;
  final String? semanticsHint;

  const GraniConnectSurfaceButton({
    super.key,
    required this.state,
    required this.onPressed,
    required this.title,
    required this.subtitle,
    this.size = 330,
    this.semanticsLabel,
    this.semanticsHint,
  });

  @override
  State<GraniConnectSurfaceButton> createState() =>
      _GraniConnectSurfaceButtonState();
}

class _GraniConnectSurfaceButtonState extends State<GraniConnectSurfaceButton>
    with TickerProviderStateMixin {
  static const _bowlAsset = 'assets/images/grani_button_bowl_base_v3.png';
  static const _centerAsset = 'assets/images/grani_button_center_source_v3.png';
  static const _darkText = Color(0xFF06142E);
  static const _secondaryText = Color(0xFF6F8194);
  static const _orange = Color(0xFFFF7A00);
  static const _orangeSoft = Color(0xFFFFB066);
  static const _coral = Color(0xFFE46E61);
  static const _coralSoft = Color(0xFFFFC4BA);

  late final AnimationController _rotationController;
  late final AnimationController _pulseController;
  bool _pressed = false;

  bool get _usesRotatingArc =>
      widget.state == VpnConnectionState.connecting ||
      widget.state == VpnConnectionState.disconnecting;

  bool get _usesPulse =>
      widget.state == VpnConnectionState.connected ||
      widget.state == VpnConnectionState.error ||
      widget.state == VpnConnectionState.connecting ||
      widget.state == VpnConnectionState.disconnecting;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );
    _syncControllers();
  }

  @override
  void didUpdateWidget(GraniConnectSurfaceButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncControllers();
  }

  void _syncControllers() {
    if (_usesRotatingArc) {
      if (!_rotationController.isAnimating) {
        _rotationController.repeat();
      }
    } else {
      _rotationController.stop();
      _rotationController.value = 0;
    }

    if (_usesPulse) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else {
      _pulseController.stop();
      _pulseController.value = 0;
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final canTap = widget.onPressed != null;
    final size = widget.size;
    final hasSubtitle = widget.subtitle.trim().isNotEmpty;
    final isError = widget.state == VpnConnectionState.error;
    final contentWidth = size * (isError ? 0.48 : 0.54);
    final textWidth = size * (isError ? 0.44 : 0.50);
    final titleFontSize = size * (isError ? 0.050 : 0.058);
    final subtitleFontSize = size * (isError ? 0.029 : 0.032);
    final contentOffsetX = -size * 0.009;
    final contentOffsetY = hasSubtitle ? -size * 0.006 : 0.0;
    final iconTitleGap = size * 0.050;

    return Semantics(
      button: canTap,
      enabled: canTap,
      label: widget.semanticsLabel ?? widget.title,
      hint: widget.semanticsHint,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        onTapDown: canTap ? (_) => _setPressed(true) : null,
        onTapUp: canTap ? (_) => _setPressed(false) : null,
        onTapCancel: canTap ? () => _setPressed(false) : null,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: Duration(milliseconds: _pressed ? 90 : 160),
          curve: Curves.easeOutCubic,
          child: SizedBox.square(
            dimension: size,
            child: AnimatedBuilder(
              animation: Listenable.merge([
                _rotationController,
                _pulseController,
              ]),
              builder: (context, child) {
                final pulse = Curves.easeInOutCubic.transform(
                  _pulseController.value,
                );
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    _ButtonSurface(
                      size: size,
                      state: widget.state,
                      pressed: _pressed,
                      pulse: pulse,
                      transitionTurns: Curves.easeInOutSine.transform(
                        _rotationController.value,
                      ),
                    ),
                    Transform.translate(
                      offset: Offset(contentOffsetX, contentOffsetY),
                      child: SizedBox(
                        width: contentWidth,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox.square(
                              dimension: size * 0.13,
                              child: CustomPaint(
                                painter: _GlyphPainter(
                                  error:
                                      widget.state == VpnConnectionState.error,
                                  color: _accentColor(widget.state),
                                ),
                              ),
                            ),
                            SizedBox(height: iconTitleGap),
                            _ScaleDownText(
                              text: widget.title,
                              width: textWidth,
                              maxLines: isError ? 2 : 1,
                              style: TextStyle(
                                fontFamily: 'Montserrat',
                                fontSize: titleFontSize,
                                fontWeight: FontWeight.w700,
                                height: 1.12,
                                letterSpacing: 0,
                                color: _darkText,
                              ),
                            ),
                            if (hasSubtitle) ...[
                              SizedBox(height: size * 0.022),
                              _ScaleDownText(
                                text: widget.subtitle,
                                width: textWidth,
                                maxLines: 2,
                                style: TextStyle(
                                  fontFamily: 'Montserrat',
                                  fontSize: subtitleFontSize,
                                  fontWeight: FontWeight.w400,
                                  height: 1.18,
                                  letterSpacing: 0,
                                  color: _secondaryText,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  static Color _accentColor(VpnConnectionState state) {
    if (state == VpnConnectionState.error) return _coral;
    return _orange;
  }
}

class _ScaleDownText extends StatelessWidget {
  final String text;
  final double width;
  final int maxLines;
  final TextStyle style;

  const _ScaleDownText({
    required this.text,
    required this.width,
    required this.maxLines,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    if (maxLines > 1) {
      return SizedBox(
        width: width,
        child: Text(
          text,
          maxLines: maxLines,
          softWrap: true,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: style,
        ),
      );
    }
    return SizedBox(
      width: width,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.center,
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
          textAlign: TextAlign.center,
          style: style,
        ),
      ),
    );
  }
}

class _ButtonSurface extends StatelessWidget {
  final double size;
  final VpnConnectionState state;
  final bool pressed;
  final double pulse;
  final double transitionTurns;

  const _ButtonSurface({
    required this.size,
    required this.state,
    required this.pressed,
    required this.pulse,
    required this.transitionTurns,
  });

  @override
  Widget build(BuildContext context) {
    final isTransition = state == VpnConnectionState.connecting ||
        state == VpnConnectionState.disconnecting;
    final isActive = state == VpnConnectionState.connected || isTransition;
    final isError = state == VpnConnectionState.error;

    return Stack(
      alignment: Alignment.center,
      children: [
        Transform.translate(
          offset: Offset(0, size * 0.085),
          child: Container(
            width: size * 0.58,
            height: size * 0.18,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF102235).withOpacity(0.050),
                  blurRadius: size * 0.11,
                  spreadRadius: -size * 0.012,
                ),
              ],
            ),
          ),
        ),
        IgnorePointer(
          child: CustomPaint(
            size: Size.square(size),
            painter: _ContainedButtonHaloPainter(
              state: state,
              pulse: pulse,
              enabled: isActive || isError,
            ),
          ),
        ),
        RepaintBoundary(
          child: Image.asset(
            _GraniConnectSurfaceButtonState._bowlAsset,
            width: size,
            height: size,
            fit: BoxFit.contain,
            color: Colors.white.withOpacity(0.075),
            colorBlendMode: BlendMode.srcATop,
            filterQuality: FilterQuality.high,
            isAntiAlias: true,
          ),
        ),
        IgnorePointer(
          child: CustomPaint(
            size: Size.square(size),
            painter: _GrooveGlowPainter(
              state: state,
              pulse: pulse,
              transitionTurns: transitionTurns,
            ),
          ),
        ),
        RepaintBoundary(
          child: AnimatedOpacity(
            opacity: pressed ? 0.96 : 1.0,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            child: Image.asset(
              _GraniConnectSurfaceButtonState._centerAsset,
              width: size,
              height: size,
              fit: BoxFit.contain,
              color: Colors.white.withOpacity(0.065),
              colorBlendMode: BlendMode.srcATop,
              filterQuality: FilterQuality.high,
              isAntiAlias: true,
            ),
          ),
        ),
      ],
    );
  }
}

class _ContainedButtonHaloPainter extends CustomPainter {
  final VpnConnectionState state;
  final double pulse;
  final bool enabled;

  const _ContainedButtonHaloPainter({
    required this.state,
    required this.pulse,
    required this.enabled,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!enabled) return;

    final shortest = size.shortestSide;
    final center = size.center(Offset.zero);
    final isError = state == VpnConnectionState.error;
    final isTransition = state == VpnConnectionState.connecting ||
        state == VpnConnectionState.disconnecting;
    final accent = isError
        ? _GraniConnectSurfaceButtonState._coral
        : _GraniConnectSurfaceButtonState._orange;
    final warm = isError
        ? _GraniConnectSurfaceButtonState._coralSoft
        : _GraniConnectSurfaceButtonState._orangeSoft;
    final strength = isError
        ? 0.34 + pulse * 0.06
        : isTransition
            ? 0.46 + pulse * 0.08
            : 0.50 + pulse * 0.10;

    final clipPath = Path()
      ..addOval(Rect.fromCircle(center: center, radius: shortest * 0.475));
    canvas.save();
    canvas.clipPath(clipPath);

    final outerShellRect = Rect.fromCircle(
      center:
          Offset(center.dx - shortest * 0.004, center.dy + shortest * 0.018),
      radius: shortest * 0.452,
    );
    canvas.drawOval(
      outerShellRect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withOpacity(0.00),
            warm.withOpacity(0.010 * strength),
            accent.withOpacity(0.040 * strength),
            warm.withOpacity(0.070 * strength),
            Colors.white.withOpacity(0.00),
          ],
          stops: const [0.50, 0.68, 0.80, 0.90, 1.00],
        ).createShader(outerShellRect),
    );

    final outerLipRect = Rect.fromCircle(
      center:
          Offset(center.dx - shortest * 0.006, center.dy + shortest * 0.012),
      radius: shortest * 0.395,
    );
    canvas.drawOval(
      outerLipRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = shortest * 0.060
        ..color = warm.withOpacity(0.075 * strength)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, shortest * 0.018),
    );
    canvas.drawOval(
      outerLipRect.deflate(shortest * 0.018),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = shortest * 0.018
        ..color = accent.withOpacity(0.050 * strength)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, shortest * 0.006),
    );

    final outerRect = Rect.fromCircle(
      center:
          Offset(center.dx - shortest * 0.006, center.dy + shortest * 0.010),
      radius: shortest * 0.400,
    );
    canvas.drawOval(
      outerRect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            warm.withOpacity(0.00),
            warm.withOpacity(0.022 * strength),
            accent.withOpacity(0.072 * strength),
            warm.withOpacity(0.00),
          ],
          stops: const [0.48, 0.62, 0.74, 1.00],
        ).createShader(outerRect),
    );

    final lowerRect = Rect.fromCircle(
      center: Offset(center.dx, center.dy + shortest * 0.090),
      radius: shortest * 0.310,
    );
    canvas.drawOval(
      lowerRect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withOpacity(0.00),
            Colors.white.withOpacity(0.030 * strength),
            accent.withOpacity(0.050 * strength),
            Colors.white.withOpacity(0.00),
          ],
          stops: const [0.24, 0.56, 0.73, 1.00],
        ).createShader(lowerRect),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ContainedButtonHaloPainter oldDelegate) {
    return oldDelegate.state != state ||
        oldDelegate.pulse != pulse ||
        oldDelegate.enabled != enabled;
  }
}

class _GrooveGlowPainter extends CustomPainter {
  final VpnConnectionState state;
  final double pulse;
  final double transitionTurns;

  const _GrooveGlowPainter({
    required this.state,
    required this.pulse,
    required this.transitionTurns,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (state == VpnConnectionState.disconnected) return;

    final center = size.center(Offset.zero);
    final shortest = size.shortestSide;
    final isError = state == VpnConnectionState.error;
    final isTransition = state == VpnConnectionState.connecting ||
        state == VpnConnectionState.disconnecting;
    final color = isError
        ? _GraniConnectSurfaceButtonState._coral
        : _GraniConnectSurfaceButtonState._orange;

    final railCenter = Offset(
      center.dx - shortest * 0.010,
      center.dy + shortest * 0.004,
    );
    final railRect = Rect.fromCenter(
      center: railCenter,
      width: shortest * 0.626,
      height: shortest * 0.620,
    );

    if (isTransition) {
      final direction = state == VpnConnectionState.connecting ? 1.0 : -1.0;
      final start = -math.pi * 0.16 + transitionTurns * math.pi * 2 * direction;
      final sweep = math.pi * 0.52 * direction;
      _drawGrooveArc(
        canvas,
        railRect,
        color,
        start,
        sweep,
        shortest,
        0.72,
      );
      _drawGrooveArc(
        canvas,
        railRect,
        color,
        start + math.pi * 1.04 * direction,
        sweep * 0.82,
        shortest,
        0.48,
        secondary: true,
      );
      return;
    }

    final base = isError ? 0.44 + pulse * 0.045 : 0.50 + pulse * 0.065;
    _drawGrooveCircle(
      canvas,
      railRect,
      color,
      shortest,
      base,
    );
  }

  void _drawGrooveCircle(
    Canvas canvas,
    Rect rect,
    Color color,
    double shortest,
    double opacity,
  ) {
    const layers = [
      _GlowStrokeSpec(width: 0.070, opacity: 0.16, blur: 0.020),
      _GlowStrokeSpec(width: 0.042, opacity: 0.34, blur: 0.010),
      _GlowStrokeSpec(width: 0.020, opacity: 0.72, blur: 0.002),
      _GlowStrokeSpec(width: 0.007, opacity: 0.92, blur: 0.000),
    ];
    for (final spec in layers) {
      _drawOvalStroke(
        canvas,
        rect,
        color,
        shortest,
        opacity,
        spec,
      );
    }
  }

  void _drawGrooveArc(
    Canvas canvas,
    Rect rect,
    Color color,
    double start,
    double sweep,
    double shortest,
    double opacity, {
    bool secondary = false,
  }) {
    final layers = secondary
        ? const [
            _GlowStrokeSpec(width: 0.052, opacity: 0.13, blur: 0.018),
            _GlowStrokeSpec(width: 0.027, opacity: 0.28, blur: 0.008),
            _GlowStrokeSpec(width: 0.013, opacity: 0.66, blur: 0.002),
            _GlowStrokeSpec(width: 0.005, opacity: 0.82, blur: 0.000),
          ]
        : const [
            _GlowStrokeSpec(width: 0.074, opacity: 0.18, blur: 0.020),
            _GlowStrokeSpec(width: 0.038, opacity: 0.42, blur: 0.010),
            _GlowStrokeSpec(width: 0.017, opacity: 0.84, blur: 0.002),
            _GlowStrokeSpec(width: 0.006, opacity: 0.98, blur: 0.000),
          ];
    for (final spec in layers) {
      _drawArcStroke(
        canvas,
        rect,
        start,
        sweep,
        color,
        shortest,
        opacity,
        spec,
      );
    }
  }

  void _drawOvalStroke(
    Canvas canvas,
    Rect rect,
    Color color,
    double shortest,
    double opacity,
    _GlowStrokeSpec spec,
  ) {
    canvas.drawOval(
      rect,
      _strokePaint(color, shortest, opacity, spec),
    );
  }

  void _drawArcStroke(
    Canvas canvas,
    Rect rect,
    double start,
    double sweep,
    Color color,
    double shortest,
    double opacity,
    _GlowStrokeSpec spec,
  ) {
    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      _strokePaint(color, shortest, opacity, spec),
    );
  }

  Paint _strokePaint(
    Color color,
    double shortest,
    double opacity,
    _GlowStrokeSpec spec,
  ) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = shortest * spec.width
      ..strokeCap = StrokeCap.round
      ..color = color.withOpacity(opacity * spec.opacity);
    if (spec.blur > 0) {
      paint.maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        shortest * spec.blur,
      );
    }
    return paint;
  }

  @override
  bool shouldRepaint(_GrooveGlowPainter oldDelegate) {
    return oldDelegate.state != state ||
        oldDelegate.pulse != pulse ||
        oldDelegate.transitionTurns != transitionTurns;
  }
}

class _GlowStrokeSpec {
  final double width;
  final double opacity;
  final double blur;

  const _GlowStrokeSpec({
    required this.width,
    required this.opacity,
    required this.blur,
  });
}

class _GlyphPainter extends CustomPainter {
  final bool error;
  final Color color;

  const _GlyphPainter({
    required this.error,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (error) {
      _paintWarning(canvas, size);
    } else {
      _paintPower(canvas, size);
    }
  }

  void _paintPower(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.095;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    final center = size.center(Offset.zero);
    final radius = size.shortestSide * 0.30;
    final rect = Rect.fromCircle(
      center: Offset(center.dx, center.dy + size.height * 0.06),
      radius: radius,
    );
    canvas.drawArc(rect, math.pi * 1.75, math.pi * 1.50, false, paint);
    canvas.drawLine(
      Offset(center.dx, size.height * 0.08),
      Offset(center.dx, size.height * 0.38),
      paint,
    );
  }

  void _paintWarning(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.075;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    final path = Path()
      ..moveTo(size.width * 0.50, size.height * 0.10)
      ..lineTo(size.width * 0.90, size.height * 0.84)
      ..lineTo(size.width * 0.10, size.height * 0.84)
      ..close();
    canvas.drawPath(path, paint);
    canvas.drawLine(
      Offset(size.width * 0.50, size.height * 0.36),
      Offset(size.width * 0.50, size.height * 0.58),
      paint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.50, size.height * 0.72),
      stroke * 0.42,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) {
    return oldDelegate.error != error || oldDelegate.color != color;
  }
}
