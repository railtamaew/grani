import 'package:flutter/material.dart';
import '../../theme.dart';

/// Двухпозиционный переключатель разделов (например, Приложения/Домены).
class GraniSegmentedChoice extends StatelessWidget {
  final String firstLabel;
  final String secondLabel;
  final bool firstSelected;
  final VoidCallback? onFirstTap;
  final VoidCallback? onSecondTap;

  const GraniSegmentedChoice({
    super.key,
    required this.firstLabel,
    required this.secondLabel,
    required this.firstSelected,
    this.onFirstTap,
    this.onSecondTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: GraniSplitModeButton(
            label: firstLabel,
            selected: firstSelected,
            icon: null,
            onTap: onFirstTap,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GraniSplitModeButton(
            label: secondLabel,
            selected: !firstSelected,
            icon: null,
            onTap: onSecondTap,
          ),
        ),
      ],
    );
  }
}

/// Кнопка выбора режима split tunnel.
class GraniSplitModeButton extends StatelessWidget {
  final String label;
  final bool selected;
  final IconData? icon;
  final VoidCallback? onTap;

  const GraniSplitModeButton({
    super.key,
    required this.label,
    required this.selected,
    this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: GraniTheme.graniSurfaceDecoration(
            radius: 16,
            borderColor: selected
                ? GraniTheme.buttonPrimary
                : GraniTheme.surfaceControlBorder,
            borderOpacity: selected ? 0.32 : 0.82,
            shadows: selected
                ? GraniTheme.surfaceControlShadowStrong
                : GraniTheme.surfaceControlShadow,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 16,
                  color: selected
                      ? GraniTheme.buttonPrimary
                      : GraniTheme.primaryText,
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GraniTheme.bodySmall.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: GraniTheme.primaryText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Строка приложения в списке split tunnel.
class GraniSplitAppRow extends StatelessWidget {
  final String label;
  final String packageName;
  final bool selected;
  final VoidCallback onTap;

  const GraniSplitAppRow({
    super.key,
    required this.label,
    required this.packageName,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: GraniTheme.graniSurfaceDecoration(
            radius: 18,
            borderColor: selected
                ? GraniTheme.buttonPrimary
                : GraniTheme.surfaceControlBorder,
            borderOpacity: selected ? 0.32 : 0.82,
            borderWidth: selected ? 1.2 : 1,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GraniTheme.bodyMedium.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: GraniTheme.primaryText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      packageName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GraniTheme.bodySmall.copyWith(
                        fontSize: 11,
                        color: GraniTheme.secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 20,
                color: selected
                    ? GraniTheme.connectedStatus
                    : GraniTheme.secondaryText,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
