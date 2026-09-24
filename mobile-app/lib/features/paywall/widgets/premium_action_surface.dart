import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PremiumActionSurface extends StatefulWidget {
  const PremiumActionSurface({
    super.key,
    required this.label,
    required this.enabled,
    required this.loading,
    required this.success,
    required this.onPressed,
    required this.pulseKey,
    required this.reducedMotion,
  });

  final String label;
  final bool enabled;
  final bool loading;
  final bool success;
  final VoidCallback onPressed;
  final int pulseKey;
  final bool reducedMotion;

  @override
  State<PremiumActionSurface> createState() => _PremiumActionSurfaceState();
}

class _PremiumActionSurfaceState extends State<PremiumActionSurface>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
  }

  @override
  void didUpdateWidget(covariant PremiumActionSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.reducedMotion && oldWidget.pulseKey != widget.pulseKey) {
      _pulseController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _setPressed(bool value) {
    if (!widget.enabled || widget.loading || widget.success) return;
    if (_pressed == value) return;
    setState(() => _pressed = value);
    if (value) HapticFeedback.selectionClick();
  }

  void _activate() {
    if (!widget.enabled || widget.loading || widget.success) return;
    if (!widget.reducedMotion) _pulseController.forward(from: 0);
    HapticFeedback.mediumImpact();
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final pressDuration = _pressed
        ? const Duration(milliseconds: 80)
        : const Duration(milliseconds: 130);
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      onTap: widget.enabled && !widget.loading && !widget.success
          ? _activate
          : null,
      excludeSemantics: true,
      child: SizedBox(
        height: 96,
        child: AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) => CustomPaint(
            painter: _PulseRingsPainter(
              progress: widget.reducedMotion ? 0 : _pulseController.value,
              idleOpacity: widget.enabled ? 0.12 : 0.05,
            ),
            child: child,
          ),
          child: Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => _setPressed(true),
              onTapCancel: () => _setPressed(false),
              onTapUp: (_) {
                _setPressed(false);
                _activate();
              },
              child: AnimatedScale(
                duration: widget.reducedMotion
                    ? const Duration(milliseconds: 60)
                    : pressDuration,
                curve: Curves.easeOutCubic,
                scale: _pressed && !widget.reducedMotion ? 0.985 : 1,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  height: 64,
                  width: double.infinity,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(32),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: widget.success
                          ? const [
                              Color(0xFF48D98A),
                              Color(0xFF24B96C),
                              Color(0xFF129A55),
                            ]
                          : widget.enabled
                              ? const [
                                  Color(0xFFFFA623),
                                  Color(0xFFFF7108),
                                  Color(0xFFFF5A00),
                                ]
                              : const [
                                  Color(0xFFD5DBDF),
                                  Color(0xFFC8D0D5),
                                  Color(0xFFAEB9C1),
                                ],
                      stops: const [0, 0.48, 1],
                    ),
                    border: Border.all(
                      color: widget.enabled
                          ? const Color(0xFFFFC463)
                          : const Color(0xFFD4DADE),
                      width: 1.4,
                    ),
                    boxShadow: widget.enabled
                        ? [
                            const BoxShadow(
                              color: Color(0x66FF6B00),
                              offset: Offset(0, 9),
                              blurRadius: 23,
                              spreadRadius: 1,
                            ),
                            const BoxShadow(
                              color: Color(0x66FFB444),
                              offset: Offset(0, 2),
                              blurRadius: 10,
                            ),
                          ]
                        : const [],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(32),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned.fill(
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(32),
                                gradient: const LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.center,
                                  colors: [
                                    Color(0x66FFFFFF),
                                    Color(0x00FFFFFF),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 58),
                          child: AnimatedSwitcher(
                            duration: widget.reducedMotion
                                ? const Duration(milliseconds: 80)
                                : const Duration(milliseconds: 145),
                            child: FittedBox(
                              key: ValueKey<String>(widget.label),
                              fit: BoxFit.scaleDown,
                              child: Text(
                                widget.label,
                                maxLines: 1,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontFamily: 'Montserrat',
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                  shadows: [
                                    Shadow(
                                      color: Color(0x66000000),
                                      offset: Offset(0, 1),
                                      blurRadius: 2,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 8,
                          child: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0x22FFFFFF),
                              border: Border.all(
                                color: const Color(0x99FFFFFF),
                                width: 1.2,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x22000000),
                                  offset: Offset(0, 2),
                                  blurRadius: 5,
                                ),
                              ],
                            ),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 140),
                              child: widget.loading
                                  ? const Padding(
                                      key: ValueKey('loading'),
                                      padding: EdgeInsets.all(13),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                          Colors.white,
                                        ),
                                      ),
                                    )
                                  : widget.success
                                      ? const Icon(
                                          Icons.check_rounded,
                                          key: ValueKey('success'),
                                          size: 28,
                                          color: Colors.white,
                                        )
                                      : const Icon(
                                          Icons.arrow_forward_rounded,
                                          key: ValueKey('arrow'),
                                          size: 28,
                                          color: Colors.white,
                                        ),
                            ),
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
    );
  }
}

class _PulseRingsPainter extends CustomPainter {
  const _PulseRingsPainter({
    required this.progress,
    required this.idleOpacity,
  });

  final double progress;
  final double idleOpacity;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseWidth = math.max(0, size.width - 42);
    for (var index = 0; index < 4; index++) {
      final idleExpansion = index * 9.0;
      final activeExpansion = progress * (18 + index * 4);
      final opacity =
          (idleOpacity + (1 - progress) * progress * (0.28 - index * 0.045))
              .clamp(0.0, 0.35);
      final rect = Rect.fromCenter(
        center: center,
        width: baseWidth + idleExpansion + activeExpansion,
        height: 58 + idleExpansion * 0.42 + activeExpansion * 0.25,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xFFFF7A12).withOpacity(opacity),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PulseRingsPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.idleOpacity != idleOpacity;
}
