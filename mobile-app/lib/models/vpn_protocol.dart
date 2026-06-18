import 'package:flutter/foundation.dart';

/// Поддерживаемые VPN протоколы.
/// GraniWG (AmneziaWG) — основной мобильный MVP. Xray оставлен архивным/R&D путем.
enum VpnProtocol {
  xrayVless,
  xrayVlessWsTls,
  xrayVlessGrpcTls,
  xrayVmess,
  xrayReality,

  /// AmneziaWG — обфусцированный WireGuard, основной рабочий протокол
  graniwg,
}

extension VpnProtocolExtension on VpnProtocol {
  String get name {
    switch (this) {
      case VpnProtocol.xrayVless:
        return 'VLESS';
      case VpnProtocol.xrayVlessWsTls:
        return 'VLESS WS+TLS';
      case VpnProtocol.xrayVlessGrpcTls:
        return 'VLESS gRPC+TLS';
      case VpnProtocol.xrayVmess:
        return 'VMESS';
      case VpnProtocol.xrayReality:
        return 'REALITY';
      case VpnProtocol.graniwg:
        return 'WireGuard obf';
    }
  }

  String get apiValue {
    switch (this) {
      case VpnProtocol.xrayVless:
        return 'xray_vless';
      case VpnProtocol.xrayVlessWsTls:
        return 'xray_vless_ws_tls';
      case VpnProtocol.xrayVlessGrpcTls:
        return 'xray_vless_grpc_tls';
      case VpnProtocol.xrayVmess:
        return 'xray_vmess';
      case VpnProtocol.xrayReality:
        return 'xray_reality';
      case VpnProtocol.graniwg:
        return 'graniwg';
    }
  }

  /// Xray archived by default; enable only for explicit R&D builds.
  static const bool _enableArchivedXray = bool.fromEnvironment(
    'GRANI_ENABLE_ARCHIVED_XRAY',
    defaultValue: false,
  );

  bool get isImplemented {
    switch (this) {
      case VpnProtocol.xrayVless:
      case VpnProtocol.xrayVlessWsTls:
      case VpnProtocol.xrayVlessGrpcTls:
      case VpnProtocol.xrayVmess:
      case VpnProtocol.xrayReality:
        return _enableArchivedXray &&
            defaultTargetPlatform == TargetPlatform.android;
      case VpnProtocol.graniwg:
        return defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS;
    }
  }

  bool get isArchived => isXray;

  bool get isXray =>
      this == VpnProtocol.xrayVless ||
      this == VpnProtocol.xrayVlessWsTls ||
      this == VpnProtocol.xrayVlessGrpcTls ||
      this == VpnProtocol.xrayVmess ||
      this == VpnProtocol.xrayReality;
}
