import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme.dart';
import '../models/vpn_protocol.dart';
import '../services/vpn_service.dart';
import 'bottom_sheets/protocol_selector_bottom_sheet.dart';

/// Кнопка выбора протокола (Figma 562:732)
class ProtocolSelectorButton extends StatelessWidget {
  final double scaleX;
  final double scaleY;

  const ProtocolSelectorButton({
    super.key,
    required this.scaleX,
    required this.scaleY,
  });

  String _getProtocolName(VpnProtocol protocol) {
    return protocol.name;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<VpnService>(
      builder: (context, vpnService, child) {
        final protocol = vpnService.selectedProtocol;

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              // Haptic feedback для лучшей интерактивности
              // HapticFeedback.lightImpact(); // Раскомментировать если нужно
              ProtocolSelectorBottomSheet.show(context);
            },
            borderRadius:
                BorderRadius.circular(GraniTheme.selectorButtonRadius * scaleX),
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
                    GraniTheme.selectorButtonRadius * scaleX),
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
                    child: Icon(
                      Icons.tune,
                      size: GraniTheme.selectorButtonIconSize * scaleX * 0.92,
                      color: GraniTheme.selectorButtonIconProtocol,
                    ),
                  ),
                  SizedBox(width: GraniTheme.selectorButtonIconGap * scaleX),
                  Flexible(
                    child: Text(
                      _getProtocolName(protocol),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(
                        fontFamily: 'Montserrat',
                        fontWeight: FontWeight.w600,
                        fontSize: GraniTheme.selectorButtonTextSize * scaleX,
                        letterSpacing: 0,
                        height: 1.1,
                        color: GraniTheme.primaryText,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
