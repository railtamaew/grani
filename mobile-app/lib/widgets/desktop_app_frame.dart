import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/desktop_integration.dart';
import '../theme.dart';

/// Keeps the same design coordinates on Windows when the window is resized.
/// Navigator and modal routes share this MediaQuery, so menus do not inflate.
class DesktopAppFrame extends StatelessWidget {
  const DesktopAppFrame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(
          412.0,
          math.min(constraints.maxWidth, constraints.maxHeight * 412 / 917),
        );
        final size = Size(width, width * 917 / 412);
        return ColoredBox(
          color: GraniTheme.surfaceBase,
          child: Center(
            child: SizedBox.fromSize(
              size: size,
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(size: size),
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(
                      LogicalKeyboardKey.space,
                      control: true,
                    ): DesktopIntegration.toggle,
                  },
                  child: Focus(autofocus: true, child: child),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
