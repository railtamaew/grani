import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../theme.dart';
import '../../models/server.dart';
import '../../models/vpn_protocol.dart';
import '../../services/vpn_service.dart';
import '../../utils/flag_emoji.dart';
import '../../core/errors/error_handler.dart';
import '../../widgets/snackbar_utils.dart';
import '../../l10n/app_localizations.dart';

/// Bottom sheet для выбора сервера
/// Макет: https://www.figma.com/design/TZYqJZyQtl31Zao6JC8GSl/GRANI?node-id=750-477&m=dev
///
/// Network: не вызываем refreshServers внутри show(). Загрузку выполняет вызывающий код
/// до открытия sheet или через кнопку «Обновить» внутри sheet (см. [show] с [loadServersFirst]).
class ServerSelectorBottomSheet extends StatefulWidget {
  const ServerSelectorBottomSheet({super.key});

  /// Показывает sheet. Если [loadServersFirst] true, сначала загружает серверы (один вызов API),
  /// при ошибке возвращает сообщение для баннера, иначе null. Серверы не загружаются внутри UI sheet.
  static Future<String?> show(BuildContext context,
      {bool loadServersFirst = false}) async {
    final vpnService = Provider.of<VpnService>(context, listen: false);
    if (loadServersFirst) {
      try {
        await vpnService.refreshServers();
        if (vpnService.servers.isEmpty) {
          if (!context.mounted) return null;
          return AppLocalizations.of(context)!.serversLoadFailed;
        }
      } catch (e) {
        debugPrint('ServerSelectorBottomSheet.show: $e');
        return ErrorHandler().userMessageForConnectionError(e);
      }
    }
    if (!context.mounted) return null;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      enableDrag: true,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => const ServerSelectorBottomSheet(),
    );
    return null;
  }

  @override
  State<ServerSelectorBottomSheet> createState() =>
      _ServerSelectorBottomSheetState();
}

class _ServerSelectorBottomSheetState extends State<ServerSelectorBottomSheet> {
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
                // Заголовок "Серверы" - из макета: y=58px, x=31px, fontSize=24px, color=#192f3f
                Positioned(
                  top: 58 * scaleY,
                  left: 31 * scaleX,
                  child: Text(
                    l10n.serversTitle,
                    style: GraniTheme.headingSmall.copyWith(
                      fontSize: 24 * scaleX,
                      letterSpacing: -0.96 * scaleX, // -0.96px tracking
                      height: 0.9, // line-height
                      color: GraniTheme.primaryText, // #192f3f
                    ),
                  ),
                ),
                // Список серверов - из макета: начинается с y=107px, width=350px
                Positioned(
                  top: 107 * scaleY,
                  left: (screenWidth - 350 * scaleX) / 2,
                  width: 350 * scaleX,
                  bottom: media.padding.bottom + 32 * scaleY,
                  child: Consumer<VpnService>(
                    builder: (context, vpnService, child) {
                      final servers = vpnService.servers;
                      final selectedServer = vpnService.selectedServer;

                      if (servers.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.cloud_off,
                                size: 48 * scaleX,
                                color: GraniTheme.secondaryText,
                              ),
                              SizedBox(height: 16 * scaleY),
                              Text(
                                l10n.serversNotLoaded,
                                style: GraniTheme.bodyMedium.copyWith(
                                  fontSize: 16 * scaleX,
                                  color: GraniTheme.secondaryText,
                                ),
                              ),
                              SizedBox(height: 8 * scaleY),
                              TextButton(
                                onPressed: () async {
                                  // Показываем индикатор загрузки
                                  showDialog(
                                    context: context,
                                    barrierDismissible: false,
                                    builder: (context) => const Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  );

                                  // Загружаем серверы
                                  await vpnService.refreshServers();

                                  // Закрываем индикатор загрузки
                                  if (context.mounted) {
                                    Navigator.of(context).pop();
                                  }
                                },
                                child: Text(
                                  l10n.serversRefresh,
                                  style: TextStyle(
                                    fontSize: 14 * scaleX,
                                    color: GraniTheme.connectedStatus,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      return ListView.separated(
                        controller: scrollController,
                        itemCount: servers.length,
                        separatorBuilder: (context, index) =>
                            SizedBox(height: 10 * scaleY), // gap=10px
                        itemBuilder: (context, index) {
                          final server = servers[index];
                          final isSelected = selectedServer?.id == server.id;

                          return _ServerListItem(
                            server: server,
                            isSelected: isSelected,
                            scaleX: scaleX,
                            scaleY: scaleY,
                            countryLabel: FlagEmoji.localizedCountryName(
                              server.country,
                              Localizations.localeOf(context),
                            ),
                            onTap: () async {
                              // Проверяем совместимость протокола с сервером
                              final currentProtocol =
                                  vpnService.selectedProtocol;
                              final protocolString = currentProtocol.apiValue;

                              if (server.supportedProtocols != null &&
                                  !server.supportedProtocols!
                                      .contains(protocolString)) {
                                // Показываем предупреждение
                                showErrorSnackBar(
                                  context,
                                  AppLocalizations.of(context)!
                                      .errorServerProtocolNotSupported,
                                  duration: const Duration(seconds: 3),
                                );
                                // Не закрываем bottom sheet, чтобы пользователь мог выбрать другой сервер
                                return;
                              }

                              await vpnService.selectServer(server);
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

/// Элемент списка сервера в GRANI molecule surface.
class _ServerListItem extends StatelessWidget {
  final Server server;
  final bool isSelected;
  final double scaleX;
  final double scaleY;

  /// Уже локализованное имя страны для текущего языка приложения.
  final String countryLabel;
  final VoidCallback onTap;

  const _ServerListItem({
    required this.server,
    required this.isSelected,
    required this.scaleX,
    required this.scaleY,
    required this.countryLabel,
    required this.onTap,
  });

  /// Строит виджет флага с эмодзи
  Widget _buildFlagWidget(Server server, double scaleX, double scaleY) {
    debugPrint(
        '_ServerListItem: server.id=${server.id}, server.country=${server.country}');

    final flagEmoji = FlagEmoji.getFlagEmoji(server.country);
    debugPrint('_ServerListItem: Flag emoji for ${server.country}: $flagEmoji');

    return Container(
      width: 32 * scaleX,
      height: 32 * scaleY,
      alignment: Alignment.center,
      child: Text(
        flagEmoji,
        style:
            TextStyle(fontSize: 20 * scaleX), // Уменьшен размер пропорционально
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius:
          BorderRadius.circular(GraniTheme.profileCardRadius * scaleX),
      child: Container(
        height: 66 * scaleY,
        padding: EdgeInsets.symmetric(
          horizontal: 14 * scaleX,
          vertical: 10 * scaleY,
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
          children: [
            Container(
              width: 42 * scaleX,
              height: 42 * scaleY,
              decoration: BoxDecoration(
                gradient: GraniTheme.surfaceControlGradient,
                borderRadius: BorderRadius.circular(16 * scaleX),
                border: Border.all(
                  color: GraniTheme.surfaceControlBorder.withOpacity(0.72),
                  width: 1,
                ),
              ),
              child: Center(
                child: Container(
                  width: 32 * scaleX,
                  height: 32 * scaleY,
                  decoration: BoxDecoration(
                    borderRadius:
                        BorderRadius.circular(40 * scaleX), // rounded-40px
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(40 * scaleX),
                    child: _buildFlagWidget(server, scaleX, scaleY),
                  ),
                ),
              ),
            ),
            SizedBox(width: 12 * scaleX),
            Expanded(
              child: Text(
                '$countryLabel ${server.ip}',
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
