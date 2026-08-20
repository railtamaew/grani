import 'package:flutter/material.dart';

class TrustItems extends StatelessWidget {
  const TrustItems({
    super.key,
    required this.googlePlay,
    required this.noRenewals,
    required this.restore,
  });

  final String googlePlay;
  final String noRenewals;
  final String restore;

  @override
  Widget build(BuildContext context) {
    final items = <({IconData icon, String label})>[
      (icon: Icons.verified_user_outlined, label: googlePlay),
      (icon: Icons.event_available_outlined, label: noRenewals),
      (icon: Icons.restore_rounded, label: restore),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 370;
        if (narrow) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < items.length; index++) ...[
                if (index > 0) const SizedBox(height: 7),
                _TrustItem(
                  icon: items[index].icon,
                  label: items[index].label,
                ),
              ],
            ],
          );
        }
        return Row(
          children: [
            for (var index = 0; index < items.length; index++) ...[
              if (index > 0) const SizedBox(width: 12),
              Expanded(
                child: _TrustItem(
                  icon: items[index].icon,
                  label: items[index].label,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _TrustItem extends StatelessWidget {
  const _TrustItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: const Color(0xFF61778A)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Montserrat',
                fontSize: 11.5,
                height: 1.25,
                fontWeight: FontWeight.w500,
                color: Color(0xFF61778A),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
