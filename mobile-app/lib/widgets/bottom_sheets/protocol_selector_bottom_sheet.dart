import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../theme.dart';
import '../../models/vpn_protocol.dart';
import '../../widgets/snackbar_utils.dart';
import '../../services/vpn_service.dart';
import '../../l10n/app_localizations.dart';

/// Bottom sheet для выбора протокола
/// Макет: https://www.figma.com/design/TZYqJZyQtl31Zao6JC8GSl/GRANI?node-id=755-361&m=dev
class ProtocolSelectorBottomSheet extends StatelessWidget {
  const ProtocolSelectorBottomSheet({super.key});

  static const Map<String, int> _protocolDisplayPriority = <String, int>{
    'xray_vless': 0,
    'xray_vless_ws_tls': 1,
    'xray_vless_grpc_tls': 2,
    'xray_reality': 3,
    'xray_vmess': 4,
  };

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      enableDrag: true,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => const ProtocolSelectorBottomSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screenWidth = media.size.width;
    final screenHeight = media.size.height;

    // Размеры из макета (базовый экран 412x917)
    const designWidth = 412.0;
    const designHeight = 917.0;
    final scaleX = screenWidth / designWidth;
    final scaleY = screenHeight / designHeight;

    return DraggableScrollableSheet(
      initialChildSize: 0.60,
      minChildSize: 0.45,
      maxChildSize: 0.90,
      builder: (context, scrollController) {
        final l10n = AppLocalizations.of(context)!;
        return ClipRRect(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(18 * scaleX),
            topRight: Radius.circular(18 * scaleX),
          ),
          child: Container(
            decoration: const BoxDecoration(
              gradient: GraniTheme.startScreenBackgroundGradient,
            ),
            child: Stack(
              children: [
                // Grabber - из макета: y=31px, width=69px
                Positioned(
                  top: 31 * scaleY,
                  left: (screenWidth - 69 * scaleX) / 2,
                  child: Container(
                    width: 69 * scaleX,
                    height: 4 * scaleY,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // Заголовок "Протоколы" - из макета: y=58px, x=31px, fontSize=24px, color=#192f3f
                Positioned(
                  top: 58 * scaleY,
                  left: 31 * scaleX,
                  child: Text(
                    l10n.protocolsTitle,
                    style: GraniTheme.headingSmall.copyWith(
                      fontSize: 24 * scaleX,
                      letterSpacing: -0.96 * scaleX, // -0.96px tracking
                      height: 0.9, // line-height
                      color: GraniTheme.primaryText, // #192f3f
                    ),
                  ),
                ),
                // Список протоколов - из макета: начинается с y=107px, width=312px
                Positioned(
                  top: 107 * scaleY,
                  left: (screenWidth - 312 * scaleX) / 2,
                  right: (screenWidth - 312 * scaleX) / 2,
                  bottom: media.padding.bottom + 32 * scaleY,
                  child: Consumer<VpnService>(
                    builder: (context, vpnService, child) {
                      final selectedProtocol = vpnService.selectedProtocol;
                      final selectedServer = vpnService.selectedServer;

                      // Протоколы берём из supportedProtocols сервера (управляется из админки)
                      final displayProtocols = <VpnProtocol>[];
                      if (selectedServer != null &&
                          selectedServer.supportedProtocols != null) {
                        for (final code in selectedServer.supportedProtocols!) {
                          final match = VpnProtocol.values
                              .where((p) => p.apiValue == code);
                          if (match.isNotEmpty && match.first.isImplemented) {
                            displayProtocols.add(match.first);
                          }
                        }
                      }
                      if (displayProtocols.isEmpty) {
                        for (final p in VpnProtocol.values) {
                          if (!p.isImplemented) continue;
                          if (p.isXray && !vpnService.isXrayAvailable) continue;
                          displayProtocols.add(p);
                        }
                      }

                      displayProtocols.sort((a, b) {
                        final pa = _protocolDisplayPriority[a.apiValue] ?? 999;
                        final pb = _protocolDisplayPriority[b.apiValue] ?? 999;
                        if (pa != pb) return pa.compareTo(pb);
                        return a.name.compareTo(b.name);
                      });

                      if (displayProtocols.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.settings_backup_restore,
                                size: 48 * scaleX,
                                color: GraniTheme.secondaryText,
                              ),
                              SizedBox(height: 16 * scaleY),
                              Text(
                                l10n.protocolsUnavailable,
                                style: GraniTheme.bodyMedium.copyWith(
                                  fontSize: 16 * scaleX,
                                  color: GraniTheme.secondaryText,
                                ),
                              ),
                              if (selectedServer == null)
                                Padding(
                                  padding: EdgeInsets.only(top: 8 * scaleY),
                                  child: Text(
                                    l10n.protocolsSelectServer,
                                    style: TextStyle(
                                      fontSize: 12 * scaleX,
                                      color: GraniTheme.secondaryText,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      }

                      return ListView.separated(
                        controller: scrollController,
                        itemCount: displayProtocols.length,
                        separatorBuilder: (context, index) =>
                            SizedBox(height: 10 * scaleY), // gap=10px
                        itemBuilder: (context, index) {
                          final protocol = displayProtocols[index];
                          final isSelected = selectedProtocol == protocol;

                          return _ProtocolListItem(
                            protocol: protocol,
                            isSelected: isSelected,
                            scaleX: scaleX,
                            scaleY: scaleY,
                            onTap: () async {
                              // Проверяем, поддерживает ли сервер протокол
                              if (selectedServer != null &&
                                  selectedServer.supportedProtocols != null) {
                                final protocolString = protocol.apiValue;
                                if (!selectedServer.supportedProtocols!
                                    .contains(protocolString)) {
                                  showErrorSnackBar(
                                    context,
                                    l10n.errorServerProtocolNotSupported,
                                    duration: const Duration(seconds: 2),
                                  );
                                  return;
                                }
                              }
                              await vpnService.selectProtocol(protocol);
                              if (context.mounted) {
                                Navigator.of(context).pop();
                              }
                            },
                          );
                        },
                      );
                    },
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

/// Элемент списка протокола в GRANI molecule surface.
class _ProtocolListItem extends StatelessWidget {
  final VpnProtocol protocol;
  final bool isSelected;
  final double scaleX;
  final double scaleY;
  final VoidCallback onTap;

  const _ProtocolListItem({
    required this.protocol,
    required this.isSelected,
    required this.scaleX,
    required this.scaleY,
    required this.onTap,
  });

  String _getProtocolName() {
    return protocol.name;
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius:
          BorderRadius.circular(GraniTheme.profileCardRadius * scaleX),
      child: Container(
        height: 60 * scaleY,
        padding: EdgeInsets.only(
          left: 14 * scaleX,
          right: 14 * scaleX,
          top: 10 * scaleY,
          bottom: 10 * scaleY,
        ),
        decoration: BoxDecoration(
          gradient: GraniTheme.surfaceControlGradient,
          borderRadius:
              BorderRadius.circular(GraniTheme.profileCardRadius * scaleX),
          border: Border.all(
            color: GraniTheme.surfaceControlBorder.withOpacity(0.88),
            width: 1,
          ),
          boxShadow: GraniTheme.surfaceControlShadowStrong,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                _getProtocolName(),
                style: TextStyle(
                  fontFamily: 'Montserrat',
                  fontWeight: FontWeight.w600,
                  fontSize: 14.5 * scaleX,
                  letterSpacing: 0,
                  height: 1.1,
                  color: GraniTheme.primaryText,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Индикатор выбора как в split tunnel: круглый чекбокс справа.
            SizedBox(
              width: 24 * scaleX,
              height: 20 * scaleY,
              child: Icon(
                isSelected ? Icons.check_circle : Icons.circle_outlined,
                color: isSelected
                    ? GraniTheme.connectedStatus
                    : GraniTheme.secondaryText,
                size: 20 * scaleX,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
