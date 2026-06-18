import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../theme.dart';

/// Единый заголовок секции профиля (иконка + title).
class GraniSectionHeader extends StatelessWidget {
  final String iconSvg;
  final String title;
  final double iconSize;

  const GraniSectionHeader({
    super.key,
    required this.iconSvg,
    required this.title,
    this.iconSize = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SvgPicture.asset(
          iconSvg,
          width: iconSize,
          height: iconSize,
          fit: BoxFit.contain,
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: GraniTheme.bodyMedium.copyWith(
            fontWeight: FontWeight.w700,
            fontSize: 16,
            color: GraniTheme.primaryText,
          ),
        ),
      ],
    );
  }
}

/// Единый контейнер карточки секции профиля.
/// Использует общие radius/shadow/fill из темы.
class GraniSectionCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final bool emphasized;

  const GraniSectionCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: padding,
      child: child,
    );

    final decorated = Container(
      decoration: BoxDecoration(
        gradient: emphasized
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFFFFFFF),
                  Color(0xFFF9FBFD),
                  Color(0xFFF3F6F9),
                ],
                stops: [0.0, 0.56, 1.0],
              )
            : GraniTheme.surfaceControlGradient,
        borderRadius: BorderRadius.circular(GraniTheme.profileCardRadius),
        border: Border.all(
          color: emphasized
              ? GraniTheme.surfaceControlBorder.withOpacity(0.96)
              : GraniTheme.surfaceControlBorder.withOpacity(0.78),
          width: 1,
        ),
        boxShadow: emphasized
            ? GraniTheme.surfaceRaisedShadow
            : GraniTheme.surfaceControlShadowStrong,
      ),
      child: onTap == null
          ? content
          : Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius:
                    BorderRadius.circular(GraniTheme.profileCardRadius),
                child: content,
              ),
            ),
    );

    return decorated;
  }
}

/// Унифицированная строка в секции профиля.
/// Поддерживает label/value схему и произвольные виджеты контента.
class GraniSectionRow extends StatelessWidget {
  final String iconSvg;
  final String? label;
  final Widget? labelWidget;
  final String? value;
  final Widget? valueWidget;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final bool enabled;
  final double iconSize;
  final double spacingAfterIcon;

  const GraniSectionRow({
    super.key,
    required this.iconSvg,
    this.label,
    this.labelWidget,
    this.value,
    this.valueWidget,
    this.onTap,
    this.semanticLabel,
    this.enabled = true,
    this.iconSize = 20,
    this.spacingAfterIcon = 10,
  });

  @override
  Widget build(BuildContext context) {
    final defaultLabelWidget = Text(
      label ?? '',
      style: GraniTheme.bodyMedium.copyWith(
        fontSize: 14.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
        color: GraniTheme.primaryText,
      ),
      overflow: TextOverflow.ellipsis,
    );

    final defaultValueWidget = Text(
      value ?? '—',
      style: GraniTheme.bodyMedium.copyWith(
        color: GraniTheme.primaryText,
        fontWeight: FontWeight.w600,
        fontSize: 14.5,
        letterSpacing: 0,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    final row = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 11,
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              gradient: GraniTheme.surfaceControlGradient,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: GraniTheme.surfaceControlBorder.withOpacity(0.72),
                width: 1,
              ),
            ),
            child: Center(
              child: SvgPicture.asset(
                iconSvg,
                width: iconSize,
                height: iconSize,
                fit: BoxFit.contain,
              ),
            ),
          ),
          SizedBox(width: spacingAfterIcon),
          Expanded(
            child: labelWidget ?? defaultLabelWidget,
          ),
          if (valueWidget != null || value != null) ...[
            const SizedBox(width: 8),
            valueWidget ?? defaultValueWidget,
          ],
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_right,
            size: 20,
            color:
                enabled ? const Color(0xFF8A96A3) : GraniTheme.surfaceVariant,
          ),
        ],
      ),
    );

    final tappable = InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(GraniTheme.profileCardRadius),
      child: row,
    );

    return Semantics(
      label: semanticLabel,
      button: true,
      child: tappable,
    );
  }
}
