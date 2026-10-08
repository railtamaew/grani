import 'package:flutter/material.dart';
import '../theme.dart';

class GraniVpnSelectorChip extends StatelessWidget {
  const GraniVpnSelectorChip({
    required this.scaleX,
    required this.scaleY,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final double scaleX;
  final double scaleY;
  final Widget icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(
          GraniTheme.selectorButtonRadius * scaleX,
        ),
        splashColor: GraniTheme.primaryText.withOpacity(0.1),
        highlightColor: GraniTheme.primaryText.withOpacity(0.05),
        child: Container(
          width: GraniTheme.selectorButtonWidth * scaleX,
          height: GraniTheme.selectorButtonHeight * scaleY,
          padding: EdgeInsets.symmetric(
            horizontal: GraniTheme.selectorButtonPaddingH * scaleX,
            vertical: GraniTheme.selectorButtonPaddingV * scaleY,
          ),
          decoration: BoxDecoration(
            gradient: GraniTheme.surfaceControlGradient,
            borderRadius: BorderRadius.circular(
              GraniTheme.selectorButtonRadius * scaleX,
            ),
            border: Border.all(
              color: GraniTheme.selectorButtonBorder.withOpacity(0.96),
              width: 1,
            ),
            boxShadow: GraniTheme.selectorButtonShadow,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: GraniTheme.selectorButtonIconSize * scaleX,
                height: GraniTheme.selectorButtonIconSize * scaleY,
                child: Center(child: icon),
              ),
              SizedBox(width: GraniTheme.selectorButtonIconGap * scaleX),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w600,
                    fontSize: GraniTheme.selectorButtonTextSize * scaleX,
                    letterSpacing: 0,
                    height: 1.05,
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

