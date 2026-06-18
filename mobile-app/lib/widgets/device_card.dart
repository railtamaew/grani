import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../theme.dart';

/// Общая карточка устройства для DevicesScreen и device_limit_sheet.
/// Отображает: platform icon, название (bold), подпись, «Это устройство» chip или кнопку «Удалить».
class DeviceCard extends StatelessWidget {
  final Map<String, dynamic> device;
  final bool isCurrentDevice;
  final bool isConfirming;
  final bool isDeleting;
  final String? inlineError;
  final bool otherButtonsBlocked;
  final String lastActivityLabel;
  final void Function(String deviceId, String name) onDeleteTap;
  final VoidCallback onCancelConfirm;
  final Future<void> Function(String deviceId, String name) onPerformDelete;

  const DeviceCard({
    super.key,
    required this.device,
    required this.isCurrentDevice,
    required this.isConfirming,
    required this.isDeleting,
    this.inlineError,
    required this.otherButtonsBlocked,
    required this.lastActivityLabel,
    required this.onDeleteTap,
    required this.onCancelConfirm,
    required this.onPerformDelete,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final deviceId = device['device_id'] as String? ?? '';
    final rawName =
        (device['name'] ?? device['device_name'] ?? '').toString().trim();
    final platform =
        (device['platform'] ?? device['device_type'] ?? '').toString();
    final name = normalizeDeviceName(rawName, platform, deviceId, l10n);
    final platformCap = platform.isNotEmpty
        ? platform[0].toUpperCase() + platform.substring(1).toLowerCase()
        : '';

    final String subtitleText;
    if (isCurrentDevice) {
      subtitleText = platformCap.isNotEmpty
          ? '$platformCap ${l10n.deviceActiveNow}'
          : l10n.deviceActiveNow;
    } else {
      final parts = [
        if (platformCap.isNotEmpty) platformCap,
        if (lastActivityLabel.isNotEmpty) lastActivityLabel,
      ];
      subtitleText =
          parts.isNotEmpty ? parts.join(' • ') : l10n.deviceRecentlyActive;
    }

    final borderColor = isConfirming
        ? GraniTheme.deviceLimitErrorText
        : (isCurrentDevice
            ? GraniTheme.connectedStatus
            : GraniTheme.surfaceControlBorder);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: GraniTheme.graniSurfaceDecoration(
        radius: GraniTheme.profileCardRadius,
        borderColor: borderColor,
        borderOpacity: isConfirming ? 0.22 : (isCurrentDevice ? 0.28 : 0.86),
        borderWidth: isCurrentDevice ? 1.2 : 1,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: GraniTheme.surfaceControlGradient,
                    borderRadius: BorderRadius.circular(25),
                    border: Border.all(
                      color: GraniTheme.surfaceControlBorder.withOpacity(0.72),
                    ),
                  ),
                  child: Icon(
                    _platformIcon(platform),
                    color: GraniTheme.secondaryText,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              style: GraniTheme.bodyMedium.copyWith(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: GraniTheme.primaryText,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      isCurrentDevice
                          ? RichText(
                              text: TextSpan(
                                style: GraniTheme.bodySmall.copyWith(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w300,
                                  color: GraniTheme.primaryText,
                                ),
                                children: [
                                  if (platformCap.isNotEmpty)
                                    TextSpan(text: '$platformCap '),
                                  TextSpan(
                                    text: l10n.deviceActiveNow,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                      color: GraniTheme.devicesActiveNowGreen,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : Text(
                              subtitleText,
                              style: GraniTheme.bodySmall.copyWith(
                                fontSize: 10,
                                fontWeight: FontWeight.w300,
                                color: GraniTheme.primaryText,
                              ),
                            ),
                    ],
                  ),
                ),
                if (isCurrentDevice) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      gradient: GraniTheme.surfaceControlGradient,
                      border: Border.all(
                        color: GraniTheme.deviceLimitThisDeviceBorder
                            .withOpacity(0.72),
                        width: 1,
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      l10n.deviceThisDevice,
                      style: GraniTheme.bodySmall.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: GraniTheme.deviceLimitBadgeCurrent,
                      ),
                    ),
                  ),
                ] else ...[
                  const SizedBox(width: 8),
                  _DeviceCardActions(
                    deviceId: deviceId,
                    name: name,
                    isConfirming: isConfirming,
                    isDeleting: isDeleting,
                    otherButtonsBlocked: otherButtonsBlocked,
                    onDeleteTap: onDeleteTap,
                    onCancelConfirm: onCancelConfirm,
                    onPerformDelete: onPerformDelete,
                  ),
                ],
              ],
            ),
            if (inlineError != null) ...[
              const SizedBox(height: 12),
              Text(
                inlineError!,
                style: GraniTheme.bodySmall.copyWith(
                  color: GraniTheme.deviceLimitErrorText,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static IconData _platformIcon(String platform) {
    final s = platform.toLowerCase();
    if (s.contains('android')) return Icons.android;
    if (s.contains('ios') || s.contains('iphone')) return Icons.apple;
    if (s.contains('windows')) return Icons.desktop_windows;
    return Icons.devices_other;
  }

  static String normalizeDeviceName(
    String rawName,
    String platform,
    String fallbackId,
    AppLocalizations l10n,
  ) {
    final lower = rawName.toLowerCase();
    if (rawName.isEmpty ||
        lower == 'unknown' ||
        lower == 'null' ||
        lower == 'device') {
      final p = platform.toLowerCase();
      if (p.contains('android')) return l10n.deviceAndroidGeneric;
      if (p.contains('ios') || p.contains('iphone')) return l10n.deviceIphone;
      if (p.contains('windows')) return l10n.deviceWindowsPc;
      final shortIdLen = fallbackId.length > 6 ? 6 : fallbackId.length;
      return fallbackId.isNotEmpty
          ? l10n.deviceFallbackName(fallbackId.substring(0, shortIdLen))
          : l10n.deviceGenericName;
    }
    return rawName;
  }
}

class _DeviceCardActions extends StatelessWidget {
  final String deviceId;
  final String name;
  final bool isConfirming;
  final bool isDeleting;
  final bool otherButtonsBlocked;
  final void Function(String deviceId, String name) onDeleteTap;
  final VoidCallback onCancelConfirm;
  final Future<void> Function(String deviceId, String name) onPerformDelete;

  const _DeviceCardActions({
    required this.deviceId,
    required this.name,
    required this.isConfirming,
    required this.isDeleting,
    required this.otherButtonsBlocked,
    required this.onDeleteTap,
    required this.onCancelConfirm,
    required this.onPerformDelete,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (isDeleting) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: GraniTheme.deviceLimitErrorText,
        ),
      );
    }

    if (isConfirming) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: onCancelConfirm,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              l10n.deviceCancel,
              style: GraniTheme.bodySmall.copyWith(
                color: GraniTheme.secondaryText,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _outlineDeleteButton(
            label: l10n.deviceConfirm,
            onTap: () => onPerformDelete(deviceId, name),
          ),
        ],
      );
    }

    return _outlineDeleteButton(
      label: l10n.deviceRemove,
      onTap: otherButtonsBlocked ? null : () => onDeleteTap(deviceId, name),
      disabled: otherButtonsBlocked,
    );
  }

  Widget _outlineDeleteButton({
    required String label,
    VoidCallback? onTap,
    bool disabled = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        splashColor: GraniTheme.deviceLimitErrorBg,
        highlightColor: GraniTheme.deviceLimitErrorBg,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            gradient: GraniTheme.surfaceControlGradient,
            border: Border.all(
              color: GraniTheme.deviceLimitDeleteBorder.withOpacity(0.72),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: GraniTheme.surfaceControlShadow,
          ),
          child: Text(
            label,
            style: GraniTheme.bodyMedium.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color:
                  disabled ? GraniTheme.secondaryText : GraniTheme.primaryText,
            ),
          ),
        ),
      ),
    );
  }
}
