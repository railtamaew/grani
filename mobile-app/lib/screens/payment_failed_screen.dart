import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme.dart';
import '../l10n/l10n.dart';

/// Bottom sheet «Оплата не прошла» (Figma 958:444).
/// Показывается при отмене или ошибке покупки подписки.
class PaymentFailedBottomSheet extends StatelessWidget {
  const PaymentFailedBottomSheet({super.key});

  /// Показать модальный bottom sheet. По нажатию «Повторить оплату» sheet закрывается.
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const PaymentFailedBottomSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    const designWidth = 412.0;
    const designHeight = 917.0;
    final scaleX = screenWidth / designWidth;
    final scaleY = screenHeight / designHeight;

    return Container(
      decoration: BoxDecoration(
        gradient: GraniTheme.startScreenBackgroundGradient,
        borderRadius: BorderRadius.vertical(
            top: Radius.circular(GraniTheme.radiusLarge * scaleX)),
        border: Border.all(
          color: GraniTheme.surfaceControlBorder.withOpacity(0.82),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 24 * scaleY),
            _buildDragIndicator(scaleX, scaleY),
            SizedBox(height: 48 * scaleY),
            Center(child: _PaymentFailedIcon(scaleX: scaleX, scaleY: scaleY)),
            SizedBox(height: 32 * scaleY),
            Text(
              context.l10n.paymentFailedTitle,
              style: TextStyle(
                fontFamily: 'Montserrat',
                fontWeight: FontWeight.w400,
                fontSize: 30 * scaleX,
                height: 27 / 30,
                letterSpacing: -1.2 * scaleX,
                color: const Color(0xFF192F3F),
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 12 * scaleY),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 32 * scaleX),
              child: Text(
                context.l10n.paymentFailedBody,
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontWeight: FontWeight.w300,
                  fontSize: 16 * scaleX,
                  height: 15.52 / 16,
                  letterSpacing: 0.96 * scaleX,
                  color: const Color(0xFF192F3F),
                ),
                textAlign: TextAlign.center,
              ),
            ),
            SizedBox(height: 40 * scaleY),
            Padding(
              padding: EdgeInsets.fromLTRB(20 * scaleX, 0, 20 * scaleX,
                  24 * scaleY + MediaQuery.of(context).padding.bottom),
              child: _buildRetryButton(context, scaleX, scaleY),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDragIndicator(double scaleX, double scaleY) {
    return Center(
      child: Container(
        width: 40 * scaleX,
        height: 4 * scaleY,
        decoration: BoxDecoration(
          color: GraniTheme.tariffTeal,
          borderRadius: BorderRadius.circular(2 * scaleX),
        ),
      ),
    );
  }

  Widget _buildRetryButton(BuildContext context, double scaleX, double scaleY) {
    return SizedBox(
      width: double.infinity,
      height: GraniTheme.buttonHeight * scaleY,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => Navigator.of(context).pop(),
          borderRadius: BorderRadius.circular(GraniTheme.radiusButton * scaleX),
          child: Container(
            decoration: BoxDecoration(
              color: GraniTheme.buttonPrimary,
              borderRadius:
                  BorderRadius.circular(GraniTheme.radiusButton * scaleX),
              border: Border.all(
                color: GraniTheme.tariffTeal,
                width: 1.5 * scaleX,
              ),
              boxShadow: GraniTheme.primaryButtonShadowWithInset
                  .map((s) => BoxShadow(
                        color: s.color,
                        offset:
                            Offset(s.offset.dx * scaleX, s.offset.dy * scaleY),
                        blurRadius: s.blurRadius * scaleX,
                        spreadRadius: s.spreadRadius * scaleX,
                      ))
                  .toList(),
            ),
            alignment: Alignment.center,
            child: Text(
              context.l10n.paymentFailedRetry,
              style: GraniTheme.buttonTextMedium.copyWith(
                fontSize: (GraniTheme.buttonTextMedium.fontSize ?? 22) * scaleX,
                color: GraniTheme.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Иконка ошибки оплаты: векторная иконка из Figma 958:444 (щит с «!»).
/// Экспорт: FIGMA_ACCESS_TOKEN=... python3 scripts/figma_export_payment_failed_icon.py
class _PaymentFailedIcon extends StatelessWidget {
  const _PaymentFailedIcon({required this.scaleX, required this.scaleY});

  final double scaleX;
  final double scaleY;

  /// Векторная иконка из макета (SVG).
  static const String assetPathSvg =
      'assets/images/figma/payment_failed_icon_only.svg';

  @override
  Widget build(BuildContext context) {
    const size = 120.0;
    final boxSize = Size(size * scaleX, size * scaleY);
    return SizedBox(
      width: boxSize.width,
      height: boxSize.height,
      child: SvgPicture.asset(
        assetPathSvg,
        fit: BoxFit.contain,
        width: boxSize.width,
        height: boxSize.height,
        excludeFromSemantics: true,
        errorBuilder: (_, __, ___) => CustomPaint(
          painter: _ShieldExclamationPainter(),
          size: boxSize,
        ),
      ),
    );
  }
}

class _ShieldExclamationPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.5, 0)
      ..lineTo(w, h * 0.25)
      ..lineTo(w, h * 0.6)
      ..quadraticBezierTo(w * 0.5, h * 0.95, 0, h * 0.6)
      ..lineTo(0, h * 0.25)
      ..close();
    canvas.drawShadow(path, const Color(0x40000000), 4, true);
    canvas.drawPath(
      path,
      Paint()..color = GraniTheme.errorBorder,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = GraniTheme.errorBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final textPainter = TextPainter(
      text: TextSpan(
        text: '!',
        style: TextStyle(
          fontFamily: 'Montserrat',
          fontWeight: FontWeight.w700,
          fontSize: w * 0.45,
          color: GraniTheme.white,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(
        (w - textPainter.width) * 0.5,
        (h - textPainter.height) * 0.5 - h * 0.02,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
