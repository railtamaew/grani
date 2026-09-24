import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../utils/flag_emoji.dart';

/// Windows' emoji font displays regional indicators as letters. Draw the
/// supported server flags locally, with no font or network dependency.
class CountryFlag extends StatelessWidget {
  const CountryFlag({super.key, required this.country, this.size = 20});
  final String? country;
  final double size;

  @override
  Widget build(BuildContext context) {
    final code = FlagEmoji.isoCountryCode(country);
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return Text(FlagEmoji.getFlagEmoji(country), style: TextStyle(fontSize: size));
    }
    if (!const {'FI', 'NO', 'SE', 'US', 'SG'}.contains(code)) {
      return Icon(Icons.public, size: size, semanticLabel: country);
    }
    return Semantics(
      label: country,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: CustomPaint(size: Size(size, size * 2 / 3), painter: _FlagPainter(code!)),
      ),
    );
  }
}

class _FlagPainter extends CustomPainter {
  const _FlagPainter(this.code);
  final String code;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 30, size.height / 20);
    final p = Paint();
    void rect(double x, double y, double w, double h, Color c) =>
        canvas.drawRect(Rect.fromLTWH(x, y, w, h), p..color = c);
    void star(double x, double y, double radius) {
      final path = Path();
      for (var i = 0; i < 10; i++) {
        final a = i * math.pi / 5 - math.pi / 2;
        final r = i.isEven ? radius : radius * .382;
        final px = x + math.cos(a) * r, py = y + math.sin(a) * r;
        if (i == 0) { path.moveTo(px, py); } else { path.lineTo(px, py); }
      }
      canvas.drawPath(path..close(), p..color = Colors.white);
    }
    const red = Color(0xFFCE1126), blue = Color(0xFF003580);
    rect(0, 0, 30, 20, Colors.white);
    switch (code) {
      case 'FI':
        rect(8, 0, 5, 20, blue); rect(0, 8, 30, 5, blue);
      case 'SE':
        rect(0, 0, 30, 20, const Color(0xFF006AA7));
        rect(9, 0, 4, 20, const Color(0xFFFECC00));
        rect(0, 8, 30, 4, const Color(0xFFFECC00));
      case 'NO':
        rect(0, 0, 30, 20, red);
        rect(8, 0, 6, 20, Colors.white); rect(0, 7, 30, 6, Colors.white);
        rect(9.5, 0, 3, 20, const Color(0xFF00205B));
        rect(0, 8.5, 30, 3, const Color(0xFF00205B));
      case 'US':
        for (var i = 0; i < 13; i += 2) { rect(0, i * 20 / 13, 30, 20 / 13, red); }
        rect(0, 0, 12, 20 * 7 / 13, const Color(0xFF3C3B6E));
        for (var row = 0; row < 9; row++) {
          for (var col = 0; col < (row.isEven ? 6 : 5); col++) {
            star((row.isEven ? 1 : 2) + col * 2, 0.7 + row * 1.17, .55);
          }
        }
      case 'SG':
        rect(0, 0, 30, 10, red);
        canvas.drawCircle(const Offset(6, 5), 3.7, p..color = Colors.white);
        canvas.drawCircle(const Offset(7.5, 4.6), 3.3, p..color = red);
        for (var i = 0; i < 5; i++) {
          final a = i * 2 * math.pi / 5 - math.pi / 2;
          star(11 + math.cos(a) * 2.4, 5 + math.sin(a) * 2.4, .95);
        }
    }
    canvas.restore();
  }
  @override
  bool shouldRepaint(_FlagPainter oldDelegate) => oldDelegate.code != code;
}
