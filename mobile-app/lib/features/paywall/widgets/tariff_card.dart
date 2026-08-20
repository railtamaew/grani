import 'package:flutter/material.dart';

import '../model/tariff_ui_model.dart';

class TariffCard extends StatelessWidget {
  const TariffCard({
    super.key,
    required this.plan,
    required this.selected,
    required this.enabled,
    required this.title,
    required this.perMonthLabel,
    required this.totalLabel,
    required this.bestValueLabel,
    required this.savingsLabel,
    required this.semanticsLabel,
    required this.onSelected,
    required this.reducedMotion,
  });

  final TariffUiModel plan;
  final bool selected;
  final bool enabled;
  final String title;
  final String perMonthLabel;
  final String totalLabel;
  final String bestValueLabel;
  final String? savingsLabel;
  final String semanticsLabel;
  final VoidCallback onSelected;
  final bool reducedMotion;

  @override
  Widget build(BuildContext context) {
    final duration = reducedMotion
        ? const Duration(milliseconds: 90)
        : const Duration(milliseconds: 210);
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      enabled: enabled,
      label: semanticsLabel,
      onTap: enabled ? onSelected : null,
      excludeSemantics: true,
      child: AnimatedScale(
        duration: duration,
        curve: Curves.easeOutCubic,
        scale: selected && !reducedMotion ? 1.006 : 1,
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: 116),
          decoration: BoxDecoration(
            color: const Color(0xFFFCFDFE),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color:
                  selected ? const Color(0xFFFF7A12) : const Color(0xFFDDE5EB),
              width: selected ? 1.8 : 1,
            ),
            boxShadow: [
              const BoxShadow(
                color: Color(0x120A2A40),
                offset: Offset(0, 8),
                blurRadius: 24,
              ),
              if (selected)
                const BoxShadow(
                  color: Color(0x38FF7A12),
                  offset: Offset(0, 7),
                  blurRadius: 24,
                  spreadRadius: 1,
                ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(22),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled ? onSelected : null,
              borderRadius: BorderRadius.circular(22),
              splashColor: const Color(0x18FF7A12),
              highlightColor: const Color(0x0DFF7A12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 16, 14, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(
                        child: AnimatedContainer(
                          duration: duration,
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selected
                                ? const Color(0xFFFF7A12)
                                : Colors.transparent,
                            border: Border.all(
                              color: selected
                                  ? const Color(0xFFFF7A12)
                                  : const Color(0xFF9DAEBB),
                              width: 1.5,
                            ),
                          ),
                          child: selected
                              ? const Icon(
                                  Icons.check_rounded,
                                  size: 17,
                                  color: Colors.white,
                                )
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                fontFamily: 'Montserrat',
                                fontSize: 19,
                                height: 1.15,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF0E2940),
                              ),
                            ),
                            const SizedBox(height: 8),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: plan.formattedMonthlyPrice,
                                      style: const TextStyle(
                                        fontSize: 30,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF091E35),
                                        letterSpacing: -0.8,
                                      ),
                                    ),
                                    TextSpan(
                                      text: ' $perMonthLabel',
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w400,
                                        color: Color(0xFF657487),
                                      ),
                                    ),
                                  ],
                                  style: const TextStyle(
                                    fontFamily: 'Montserrat',
                                    height: 1.05,
                                  ),
                                ),
                                maxLines: 1,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '$totalLabel ${plan.formattedTotalPrice}',
                              style: const TextStyle(
                                fontFamily: 'Montserrat',
                                fontSize: 15,
                                height: 1.2,
                                fontWeight: FontWeight.w400,
                                color: Color(0xFF657487),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 76,
                      height: 84,
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.center,
                        children: [
                          AnimatedSwitcher(
                            duration: duration,
                            switchInCurve: Curves.easeOutCubic,
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                              opacity: animation,
                              child: ScaleTransition(
                                scale: Tween<double>(
                                  begin: reducedMotion ? 1 : 0.97,
                                  end: selected && !reducedMotion ? 1.04 : 1,
                                ).animate(animation),
                                child: child,
                              ),
                            ),
                            child: Image.asset(
                              selected
                                  ? plan.illustrationSelected
                                  : plan.illustrationNeutral,
                              key: ValueKey<bool>(selected),
                              width: 68,
                              height: 68,
                              fit: BoxFit.contain,
                              excludeFromSemantics: true,
                              filterQuality: FilterQuality.high,
                              cacheWidth: 256,
                              cacheHeight: 256,
                            ),
                          ),
                          if (plan.isBestValue)
                            Positioned(
                              top: -7,
                              right: -8,
                              child: AnimatedContainer(
                                duration: duration,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? const Color(0xFFFF6B00)
                                      : const Color(0xFFFFE1CA),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Text(
                                  bestValueLabel,
                                  style: TextStyle(
                                    fontFamily: 'Montserrat',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: selected
                                        ? Colors.white
                                        : const Color(0xFFC64E00),
                                  ),
                                ),
                              ),
                            ),
                          if (savingsLabel != null)
                            Positioned(
                              right: -4,
                              bottom: -5,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE1F8DF),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  child: Text(
                                    savingsLabel!,
                                    style: const TextStyle(
                                      fontFamily: 'Montserrat',
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF237B2A),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
