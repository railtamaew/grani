import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme.dart';
import '../models/server.dart';
import '../services/vpn_service.dart';
import '../l10n/l10n.dart';
import '../utils/flag_emoji.dart';
import 'bottom_sheets/server_selector_bottom_sheet.dart';

/// Кнопка выбора сервера (Figma 562:732)
class ServerSelectorButton extends StatelessWidget {
  final double scaleX;
  final double scaleY;
  final void Function(String)? onServerLoadError;

  const ServerSelectorButton({
    super.key,
    required this.scaleX,
    required this.scaleY,
    this.onServerLoadError,
  });

  /// Строит виджет флага (Figma 562:732: иконка 20×20, без красного фона)
  Widget _buildFlagWidget(Server? server, double scaleX, double scaleY) {
    final flagEmoji =
        server != null ? FlagEmoji.getFlagEmoji(server.country) : '🌍';
    final s = GraniTheme.selectorButtonIconSize * scaleX;
    return SizedBox(
      width: s,
      height: s,
      child: Center(
        child: Text(
          flagEmoji,
          style: TextStyle(fontSize: (s * 0.7).clamp(12.0, 16.0)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context);
    return Consumer<VpnService>(
      builder: (context, vpnService, child) {
        final server = vpnService.selectedServer;
        final countryText = server == null
            ? context.l10n.serverLabelPlaceholder
            : FlagEmoji.localizedCountryName(server.country, locale);
        final titleText = server == null
            ? countryText
            : (server.city.isNotEmpty ? server.city : countryText);
        final subtitleText = server == null ? '' : countryText;

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () async {
              final error = await ServerSelectorBottomSheet.show(
                context,
                loadServersFirst: true,
              );
              if (error != null && context.mounted) {
                onServerLoadError?.call(error);
              }
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
                  _buildFlagWidget(server, scaleX, scaleY),
                  SizedBox(width: GraniTheme.selectorButtonIconGap * scaleX),
                  Flexible(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          titleText,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: TextStyle(
                            fontFamily: 'Montserrat',
                            fontWeight: FontWeight.w600,
                            fontSize:
                                GraniTheme.selectorButtonTextSize * scaleX,
                            letterSpacing: 0,
                            height: 1.05,
                            color: GraniTheme.primaryText,
                          ),
                        ),
                        if (subtitleText.isNotEmpty)
                          Text(
                            subtitleText,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: TextStyle(
                              fontFamily: 'Montserrat',
                              fontWeight: FontWeight.w400,
                              fontSize: 9.5 * scaleX,
                              letterSpacing: 0,
                              height: 1.05,
                              color: const Color(0xFF6F8194),
                            ),
                          ),
                      ],
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
