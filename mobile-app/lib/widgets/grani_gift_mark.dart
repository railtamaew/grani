import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A quiet gift animation, shared by the referral button and its entry point.
class GraniGiftMark extends StatefulWidget {
  const GraniGiftMark({super.key, this.size = 44});
  final double size;

  @override
  State<GraniGiftMark> createState() => _GraniGiftMarkState();
}

class _GraniGiftMarkState extends State<GraniGiftMark>
    with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 4000));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) || !TickerMode.of(context)) {
      _motion.stop();
      _motion.value = 0;
    } else if (!_motion.isAnimating) {
      _motion.repeat();
    }
  }

  @override
  void dispose() { _motion.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RepaintBoundary(child: SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(animation: _motion, builder: (context, child) =>
        CustomPaint(painter: _GiftPainter(_motion.value))),
    )),
  );
}

class _GiftPainter extends CustomPainter {
  const _GiftPainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 32, size.height / 32);
    final lift = progress < .3 ? math.sin(progress / .3 * math.pi) : 0.0;
    final ink = Paint()
      ..color = const Color(0xffff7a00)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(RRect.fromRectAndRadius(
      const Rect.fromLTWH(7, 16, 18, 12), const Radius.circular(2)), ink);
    canvas.drawLine(const Offset(16, 16), const Offset(16, 28), ink);
    canvas.save();
    canvas.translate(0, -lift * 2.4);
    canvas.drawRRect(RRect.fromRectAndRadius(
      const Rect.fromLTWH(5, 11, 22, 5), const Radius.circular(1.5)), ink);
    canvas.drawPath(Path()..moveTo(16, 11)
      ..cubicTo(10, 11, 6, 5, 10, 4)
      ..cubicTo(13, 3, 16, 7, 16, 11)
      ..cubicTo(16, 7, 19, 3, 22, 4)
      ..cubicTo(26, 5, 22, 11, 16, 11), ink);
    canvas.drawLine(const Offset(16, 11), const Offset(16, 16), ink);
    canvas.restore();
    if (lift > 0) {
      final sparkle = Paint()..color = const Color(0xffffa34d).withOpacity(lift)
        ..strokeWidth = 1.2..strokeCap = StrokeCap.round;
      canvas.drawLine(const Offset(28, 5), const Offset(28, 9), sparkle);
      canvas.drawLine(const Offset(26, 7), const Offset(30, 7), sparkle);
      canvas.drawLine(const Offset(3, 18), const Offset(3, 21), sparkle);
      canvas.drawLine(const Offset(1.5, 19.5), const Offset(4.5, 19.5), sparkle);
    }
  }

  @override
  bool shouldRepaint(_GiftPainter oldDelegate) => oldDelegate.progress != progress;
}
