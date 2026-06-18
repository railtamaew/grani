import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/custom_widgets.dart';
import '../widgets/privacy_policy_document.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);

    return Scaffold(
      backgroundColor: GraniTheme.surfaceBase,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: GraniTheme.startScreenBackgroundGradient,
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
                child: Row(
                  children: [
                    _SurfaceIconButton(
                      icon: Icons.arrow_back_rounded,
                      onTap: () => Navigator.maybePop(context),
                    ),
                    const Expanded(
                      child: Center(
                        child: SizedBox(
                          width: 170,
                          height: 34,
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: LogoWidget(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 44),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    10,
                    16,
                    media.padding.bottom + 34,
                  ),
                  child: const PrivacyPolicyDocument(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SurfaceIconButton extends StatelessWidget {
  const _SurfaceIconButton({
    required this.icon,
    required this.onTap,
  });

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(GraniTheme.radiusPill),
        child: Container(
          width: 44,
          height: 44,
          decoration: GraniTheme.graniSurfaceDecoration(
            radius: GraniTheme.radiusPill,
            shadows: GraniTheme.surfaceControlShadow,
          ),
          child: Icon(
            icon,
            color: GraniTheme.primaryText,
            size: 24,
          ),
        ),
      ),
    );
  }
}
