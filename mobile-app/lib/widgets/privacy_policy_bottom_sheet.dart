import 'package:flutter/material.dart';

import '../theme.dart';
import 'privacy_policy_document.dart';

class PrivacyPolicyBottomSheet extends StatelessWidget {
  const PrivacyPolicyBottomSheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      enableDrag: true,
      barrierColor: Colors.black.withOpacity(0.36),
      builder: (context) => const PrivacyPolicyBottomSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.84,
      minChildSize: 0.52,
      maxChildSize: 0.94,
      builder: (context, scrollController) {
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: GraniTheme.startScreenBackgroundGradient,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(28),
            ),
            border: Border.all(
              color: GraniTheme.surfaceControlBorder.withOpacity(0.78),
            ),
            boxShadow: GraniTheme.surfaceRaisedShadow,
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(28),
            ),
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 54,
                  height: 4,
                  decoration: BoxDecoration(
                    color: GraniTheme.primaryText.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: scrollController,
                    padding: EdgeInsets.fromLTRB(
                      18,
                      18,
                      18,
                      media.padding.bottom + 30,
                    ),
                    child: const PrivacyPolicyDocument(compact: true),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
