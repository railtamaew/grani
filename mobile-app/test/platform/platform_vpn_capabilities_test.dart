import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/platform/platform_vpn_capabilities.dart';

void main() {
  test('Android exposes the existing full mobile runtime', () {
    final value = PlatformVpnCapabilities.forTargetPlatform(
      TargetPlatform.android,
    );

    expect(value.wireGuardObf, isTrue);
    expect(value.vlessWs, isTrue);
    expect(value.hysteria2, isTrue);
    expect(value.appSplitTunnel, isTrue);
    expect(value.nativeStoreBilling, isTrue);
  });

  test('Windows keeps three protocols and Android payment handoff', () {
    final value = PlatformVpnCapabilities.forTargetPlatform(
      TargetPlatform.windows,
    );

    expect(value.supportsProtocol('graniwg'), isTrue);
    expect(value.supportsProtocol('vless_ws'), isTrue);
    expect(value.supportsProtocol('hysteria2'), isTrue);
    expect(value.androidPaymentHandoff, isTrue);
  });

  test('Apple first increment exposes only Packet Tunnel WireGuard obf', () {
    for (final target in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      final value = PlatformVpnCapabilities.forTargetPlatform(target);
      expect(value.nativeVpnChannel, isTrue);
      expect(value.supportsProtocol('graniwg'), isTrue);
      expect(value.supportsProtocol('vless_ws'), isFalse);
      expect(value.supportsProtocol('hysteria2'), isFalse);
      expect(value.appSplitTunnel, isFalse);
    }
  });

  test('Web never inherits host platform VPN capabilities', () {
    final value = PlatformVpnCapabilities.forTargetPlatform(
      TargetPlatform.android,
      isWeb: true,
    );

    expect(value.platform, GraniClientPlatform.unsupported);
    expect(value.nativeVpnChannel, isFalse);
  });
}
