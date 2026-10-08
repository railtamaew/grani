import 'package:flutter/material.dart';
import '../simple_vpn/simple_vpn_controller.dart';
import '../theme.dart';
import '../utils/flag_emoji.dart';
import '../widgets/button_connection.dart';
import '../widgets/grani_top_icon_button.dart';
import '../widgets/grani_gift_art.dart';
import '../widgets/grani_vpn_selector_chip.dart';
import 'tv_ui.dart';

/// Uses the phone's connection artwork and selectors with the same controller.
class TvHomeView extends StatelessWidget {
  const TvHomeView(
      {super.key,
      required this.controller,
      required this.title,
      required this.subtitle,
      required this.onServer,
      required this.onProtocol,
      this.serverLabel,
      this.protocolLabel,
      this.protocolIcon,
      this.connectionTimeline});
  final SimpleVpnController controller;
  final String title, subtitle;
  final VoidCallback onServer, onProtocol;
  final String? serverLabel, protocolLabel;
  final IconData? protocolIcon;
  final Widget? connectionTimeline;

  @override
  Widget build(BuildContext context) {
    final busy = controller.isBusy || controller.isConnected;
    final restoring = controller.isRestoringNativeState;
    final state = switch (controller.state) {
      SimpleVpnState.connected => ButtonConnectionState.on,
      SimpleVpnState.connecting => ButtonConnectionState.connecting,
      SimpleVpnState.disconnecting => ButtonConnectionState.disconnecting,
      SimpleVpnState.error => ButtonConnectionState.error,
      SimpleVpnState.disconnected => ButtonConnectionState.off,
    };
    final VoidCallback? connect =
        restoring || (controller.isBusy && !controller.isConnecting)
            ? null
            : () {
                if (controller.isConnecting) {
                  controller.cancelConnect(source: 'tv_remote');
                } else {
                  controller.toggle(source: 'tv_remote');
                }
              };
    void account() => Navigator.pushNamed(context, '/profile');
    void gift() => showTvNotice(
        context,
        tvText(
            context,
            'Подарить другу 7 дней GRANI можно в мобильном приложении.',
            'Give a friend 7 days of GRANI from the mobile app.'));
    final server = controller.selectedServer;
    return TvPage(
      title: '',
      showBack: false,
      contentWidth: 600,
      leading: TvRemoteControl(
          onPressed: account,
          circular: true,
          label: tvText(context, 'Аккаунт', 'Account'),
          child: GraniTopIconButton(
              assetName: 'assets/images/figma/profile/menu_new.svg',
              onTap: account,
              width: 40,
              height: 40,
              iconWidth: 26,
              iconHeight: 20,
              surfaceSize: 38,
              fallbackIcon: Icons.menu)),
      actions: [
        TvRemoteControl(
            onPressed: gift,
            label: tvText(context, 'Подарить другу', 'Give a friend a gift'),
            child: GestureDetector(
                onTap: gift, child: const GraniGiftArt(size: 60)))
      ],
      child: LayoutBuilder(builder: (context, constraints) {
        // The phone timeline keeps its height even while hidden. Reserve it
        // before sizing the shared connection artwork, so remote focus on a
        // selector does not scroll the heading underneath the fixed header.
        final scaler = MediaQuery.textScalerOf(context);
        final scaledTextExtra =
            (scaler.scale(30) - 30).clamp(0.0, 100.0) * 1.12 +
                (scaler.scale(15) - 15).clamp(0.0, 100.0) * 1.3;
        final timelineHeight =
            connectionTimeline == null ? 0.0 : 18 + scaler.scale(11) * 1.5;
        final size =
            (constraints.maxHeight - 126 - timelineHeight - scaledTextExtra)
                .clamp(230.0, 330.0);
        return SingleChildScrollView(
            child: Column(children: [
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontFamily: 'Montserrat',
                  fontSize: 30,
                  height: 1.12,
                  fontWeight: FontWeight.w400,
                  color: GraniTheme.primaryText)),
          const SizedBox(height: 10),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 15,
                  height: 1.3,
                  fontWeight: FontWeight.w300,
                  color: GraniTheme.secondaryText)),
          const SizedBox(height: 8),
          TvRemoteControl(
              autofocus: true,
              circular: true,
              onPressed: connect,
              child: ButtonConnection(
                  state: restoring ? ButtonConnectionState.connecting : state,
                  onTap: connect,
                  size: size,
                  progressPercent: controller.connectionProgressPercent,
                  errorMessage: controller.networkNotice == null
                      ? controller.error
                      : null)),
          if (connectionTimeline != null) connectionTimeline!,
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            TvRemoteControl(
                onPressed: busy ? null : onServer,
                label: tvText(context, 'Сервер', 'Server'),
                child: GraniVpnSelectorChip(
                    scaleX: 1,
                    scaleY: 1,
                    icon: Text(
                        FlagEmoji.getFlagEmoji(
                            server?.countryCode ?? server?.country ?? ''),
                        style: const TextStyle(fontSize: 14)),
                    label: serverLabel ?? server?.name ?? '—',
                    onTap: busy ? null : onServer)),
            const SizedBox(width: GraniTheme.selectorButtonGap),
            TvRemoteControl(
                onPressed: busy ? null : onProtocol,
                label: tvText(context, 'Протокол', 'Protocol'),
                child: GraniVpnSelectorChip(
                    scaleX: 1,
                    scaleY: 1,
                    icon: Icon(protocolIcon ?? Icons.tune,
                        size: 18, color: GraniTheme.selectorButtonIconProtocol),
                    label: protocolLabel ?? controller.selectedProtocol.label,
                    onTap: busy ? null : onProtocol)),
          ]),
          if (controller.error != null && controller.networkNotice == null) ...[
            const SizedBox(height: 12),
            TvNotice(controller.error!, error: true)
          ],
        ]));
      }),
    );
  }
}
