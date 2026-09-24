import 'package:flutter/material.dart';

class PaywallHeader extends StatelessWidget {
  const PaywallHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Montserrat',
                fontSize: 28,
                height: 1.12,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.7,
                color: Color(0xFF10293B),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Montserrat',
                fontSize: 16,
                height: 1.35,
                fontWeight: FontWeight.w400,
                color: Color(0xFF657487),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
