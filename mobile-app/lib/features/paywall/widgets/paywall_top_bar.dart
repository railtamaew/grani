import 'package:flutter/material.dart';

class PaywallTopBar extends StatelessWidget {
  const PaywallTopBar({
    super.key,
    required this.onBack,
  });

  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (onBack != null)
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                onPressed: onBack,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                icon: const Icon(
                  Icons.arrow_back_ios_new_rounded,
                  size: 22,
                  color: Color(0xFF163041),
                ),
              ),
            ),
          ExcludeSemantics(
            child: Image.asset(
              'assets/images/figma/logo_grani_new.png',
              width: 40,
              height: 48,
              fit: BoxFit.contain,
            ),
          ),
        ],
      ),
    );
  }
}
