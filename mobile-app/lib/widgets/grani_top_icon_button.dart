import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme.dart';

class GraniTopIconButton extends StatelessWidget {
  const GraniTopIconButton({
    super.key,
    required this.assetName,
    required this.onTap,
    required this.width,
    required this.height,
    required this.iconWidth,
    required this.iconHeight,
    this.semanticLabel,
    this.fallbackIcon,
    this.surfaceSize,
  });

  final String assetName;
  final VoidCallback onTap;
  final double width;
  final double height;
  final double iconWidth;
  final double iconHeight;
  final String? semanticLabel;
  final IconData? fallbackIcon;
  final double? surfaceSize;

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        height: height,
        child: Center(
          child: Container(
            width: surfaceSize ?? width,
            height: surfaceSize ?? height,
            decoration: GraniTheme.graniSurfaceDecoration(
              radius: GraniTheme.radiusPill,
              borderOpacity: 0.72,
              shadows: GraniTheme.surfaceSoftShadow,
            ),
            child: Center(
              child: SizedBox(
                width: iconWidth,
                height: iconHeight,
                child: SvgPicture.asset(
                  assetName,
                  fit: BoxFit.contain,
                  placeholderBuilder: (_) => Icon(
                    fallbackIcon ?? Icons.circle,
                    size: iconWidth,
                    color: GraniTheme.primaryText,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (semanticLabel == null) return button;
    return Semantics(
      label: semanticLabel,
      button: true,
      child: button,
    );
  }
}
