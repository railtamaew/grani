import 'package:flutter/material.dart';
import '../theme.dart';

/// Shared bottom sheet for device limit: user picks a device to deactivate.
/// Returns the selected device_id to deactivate, or null if dismissed.
Future<String?> showDeviceLimitSheet(
  BuildContext context, {
  required List<dynamic> devices,
  required String message,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          decoration: BoxDecoration(
            gradient: GraniTheme.startScreenBackgroundGradient,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: GraniTheme.surfaceControlBorder.withOpacity(0.82),
            ),
            boxShadow: GraniTheme.surfaceRaisedShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 56,
                  height: 4,
                  decoration: BoxDecoration(
                    color: GraniTheme.surfaceControlBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Лимит устройств',
                style: GraniTheme.bodyMedium.copyWith(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: GraniTheme.primaryText,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                style: GraniTheme.bodyMedium.copyWith(
                  fontSize: 14,
                  color: GraniTheme.secondaryText,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: devices.length,
                  itemBuilder: (_, index) {
                    final device = devices[index] is Map
                        ? devices[index] as Map
                        : <String, dynamic>{};
                    final deviceId = device['device_id']?.toString() ?? '';
                    final deviceName = device['device_name']?.toString();
                    final deviceType = device['device_type']?.toString();
                    final isActive = device['is_active'] == true;
                    final parts = <String>[];
                    if (deviceType != null && deviceType.isNotEmpty)
                      parts.add(deviceType);
                    if (deviceId.isNotEmpty) parts.add(deviceId);
                    if (isActive) parts.add('подключено');
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: GraniTheme.graniSurfaceDecoration(
                          radius: GraniTheme.profileCardRadius,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    deviceName?.isNotEmpty == true
                                        ? deviceName!
                                        : deviceId,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GraniTheme.bodyMedium.copyWith(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                      color: GraniTheme.primaryText,
                                    ),
                                  ),
                                  if (parts.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      parts.join(' • '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: GraniTheme.bodySmall.copyWith(
                                        color: GraniTheme.secondaryText,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            _SheetSurfaceButton(
                              label: 'Выйти',
                              onTap: () =>
                                  Navigator.pop(sheetContext, deviceId),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: _SheetSurfaceButton(
                  label: 'Отмена',
                  onTap: () => Navigator.pop(sheetContext),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _SheetSurfaceButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _SheetSurfaceButton({
    required this.label,
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
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: GraniTheme.graniSurfaceDecoration(
            radius: 16,
            shadows: GraniTheme.surfaceControlShadow,
          ),
          child: Text(
            label,
            style: GraniTheme.bodySmall.copyWith(
              color: GraniTheme.primaryText,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
