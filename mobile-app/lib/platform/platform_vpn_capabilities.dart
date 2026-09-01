import 'package:flutter/foundation.dart';

enum GraniClientPlatform { android, ios, windows, macos, unsupported }

/// Single source of truth for platform VPN capabilities.
///
/// Apple clients intentionally expose only WireGuard obf until VLESS/Hysteria
/// have a Packet Tunnel engine and physical-device acceptance coverage.
class PlatformVpnCapabilities {
  const PlatformVpnCapabilities({
    required this.platform,
    required this.nativeVpnChannel,
    required this.wireGuardObf,
    required this.vlessWs,
    required this.hysteria2,
    required this.appSplitTunnel,
    required this.nativeStoreBilling,
    required this.androidPaymentHandoff,
  });

  final GraniClientPlatform platform;
  final bool nativeVpnChannel;
  final bool wireGuardObf;
  final bool vlessWs;
  final bool hysteria2;
  final bool appSplitTunnel;
  final bool nativeStoreBilling;
  final bool androidPaymentHandoff;

  bool supportsProtocol(String? protocolId) {
    switch (protocolId) {
      case 'graniwg':
        return wireGuardObf;
      case 'vless_ws':
        return vlessWs;
      case 'hysteria2':
        return hysteria2;
      default:
        return false;
    }
  }

  static PlatformVpnCapabilities forTargetPlatform(
    TargetPlatform targetPlatform, {
    bool isWeb = false,
  }) {
    if (isWeb) return unsupported;
    switch (targetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return unsupported;
    }
  }

  static PlatformVpnCapabilities get current => forTargetPlatform(
        defaultTargetPlatform,
        isWeb: kIsWeb,
      );

  static const android = PlatformVpnCapabilities(
    platform: GraniClientPlatform.android,
    nativeVpnChannel: true,
    wireGuardObf: true,
    vlessWs: true,
    hysteria2: true,
    appSplitTunnel: true,
    nativeStoreBilling: true,
    androidPaymentHandoff: false,
  );

  static const ios = PlatformVpnCapabilities(
    platform: GraniClientPlatform.ios,
    nativeVpnChannel: true,
    wireGuardObf: true,
    vlessWs: false,
    hysteria2: false,
    appSplitTunnel: false,
    nativeStoreBilling: false,
    androidPaymentHandoff: false,
  );

  static const windows = PlatformVpnCapabilities(
    platform: GraniClientPlatform.windows,
    nativeVpnChannel: true,
    wireGuardObf: true,
    vlessWs: true,
    hysteria2: true,
    appSplitTunnel: true,
    nativeStoreBilling: false,
    androidPaymentHandoff: true,
  );

  static const macos = PlatformVpnCapabilities(
    platform: GraniClientPlatform.macos,
    nativeVpnChannel: true,
    wireGuardObf: true,
    vlessWs: false,
    hysteria2: false,
    appSplitTunnel: false,
    nativeStoreBilling: false,
    androidPaymentHandoff: true,
  );

  static const unsupported = PlatformVpnCapabilities(
    platform: GraniClientPlatform.unsupported,
    nativeVpnChannel: false,
    wireGuardObf: false,
    vlessWs: false,
    hysteria2: false,
    appSplitTunnel: false,
    nativeStoreBilling: false,
    androidPaymentHandoff: false,
  );
}
