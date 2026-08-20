import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/native_vpn_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const vpnChannel = MethodChannel('com.granivpn.mobile/vpn');
  final binding = TestDefaultBinaryMessengerBinding.instance;
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    NativeVpnService.resetChannelCallCountsForTests();
    calls.clear();
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(vpnChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('takeQuickTileAction normalizes toggle and empty values', () async {
    Object? response = ' toggle ';
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      vpnChannel,
      (call) async {
        calls.add(call);
        return response;
      },
    );

    expect(await NativeVpnService.takeQuickTileAction(), 'toggle');
    response = '   ';
    expect(await NativeVpnService.takeQuickTileAction(), isNull);
    response = null;
    expect(await NativeVpnService.takeQuickTileAction(), isNull);

    expect(
      calls.map((call) => call.method),
      ['takeQuickTileAction', 'takeQuickTileAction', 'takeQuickTileAction'],
    );
  });

  test('setAllowTileConnect sends the explicit allow flag', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      vpnChannel,
      (call) async {
        calls.add(call);
        return null;
      },
    );

    await NativeVpnService.setAllowTileConnect(false);
    await NativeVpnService.setAllowTileConnect(true);

    expect(calls.length, 2);
    expect(calls[0].method, 'setAllowTileConnect');
    expect(calls[0].arguments, <String, dynamic>{'allow': false});
    expect(calls[1].arguments, <String, dynamic>{'allow': true});
  });

  test('disconnect forwards reason source and session id to native layer',
      () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      vpnChannel,
      (call) async {
        calls.add(call);
        return true;
      },
    );

    final result = await NativeVpnService.disconnect(
      reason: 'user_disconnect',
      source: 'quick_tile',
      connectionSessionId: 'sid-1',
    );

    expect(result, isTrue);
    expect(calls.single.method, 'disconnect');
    expect(calls.single.arguments, <String, dynamic>{
      'reason': 'user_disconnect',
      'source': 'quick_tile',
      'connection_session_id': 'sid-1',
    });
  });

  test('disconnectAmneziaWg forwards reason source and session id', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      vpnChannel,
      (call) async {
        calls.add(call);
        return true;
      },
    );

    final result = await NativeVpnService.disconnectAmneziaWg(
      reason: 'subscription_revoked',
      source: 'system_panel',
      connectionSessionId: 'sid-awg',
    );

    expect(result, isTrue);
    expect(calls.single.method, 'disconnectAmneziaWg');
    expect(calls.single.arguments, <String, dynamic>{
      'reason': 'subscription_revoked',
      'source': 'system_panel',
      'connection_session_id': 'sid-awg',
    });
  });

  test('getNativeConnectionStatus returns nullable status and tracks polling',
      () async {
    Object? response = <String, dynamic>{'connected': true};
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      vpnChannel,
      (call) async {
        calls.add(call);
        return response;
      },
    );

    expect(await NativeVpnService.getNativeConnectionStatus(), isTrue);
    response = <String, dynamic>{'connected': false};
    expect(await NativeVpnService.getNativeConnectionStatus(), isFalse);
    response = <String, dynamic>{'connected': 'unknown'};
    expect(await NativeVpnService.getNativeConnectionStatus(), isNull);

    expect(NativeVpnService.getStatusCallCount, 3);
    expect(NativeVpnService.channelCallSnapshot()['getStatus'], 3);
  });

  test('getSplitTunnelPolicyState exposes pending app policy revision',
      () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      vpnChannel,
      (call) async {
        calls.add(call);
        return <String, dynamic>{
          'mode': NativeVpnService.splitTunnelModeExclude,
          'packages': <String>['com.example.browser'],
          'revision': 4,
          'applied_revision': 3,
          'pending_reconnect': true,
        };
      },
    );

    final state = await NativeVpnService.getSplitTunnelPolicyState();

    expect(calls.single.method, 'getSplitTunnelPolicyState');
    expect(state['revision'], 4);
    expect(state['applied_revision'], 3);
    expect(state['pending_reconnect'], isTrue);
  });

  test('connectAmneziaWg attaches split tunnel preferences on Android',
      () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      vpnChannel,
      (call) async {
        calls.add(call);
        switch (call.method) {
          case 'getSplitTunnelMode':
            return NativeVpnService.splitTunnelModeExclude;
          case 'getSplitTunnelExcludedApps':
            return <String>['com.google.android.youtube'];
          case 'getSplitTunnelDirectDomains':
            return <String>['api.granilink.com'];
          case 'connectAmneziaWg':
            return true;
        }
        fail('Unexpected native method: ${call.method}');
      },
    );

    final result = await NativeVpnService.connectAmneziaWg(
      '[Interface]\nPrivateKey = x',
      connectionSessionId: 'sid-connect',
      source: 'quick_tile',
    );

    expect(result, isTrue);
    expect(
      calls.map((call) => call.method),
      [
        'getSplitTunnelMode',
        'getSplitTunnelExcludedApps',
        'getSplitTunnelDirectDomains',
        'connectAmneziaWg',
      ],
    );
    expect(calls.last.arguments, <String, dynamic>{
      'config': '[Interface]\nPrivateKey = x',
      'connection_session_id': 'sid-connect',
      'source': 'quick_tile',
      'split_tunnel_mode': NativeVpnService.splitTunnelModeExclude,
      'split_tunnel_packages': <String>['com.google.android.youtube'],
      'split_tunnel_direct_domains': <String>['api.granilink.com'],
    });
  });
}
