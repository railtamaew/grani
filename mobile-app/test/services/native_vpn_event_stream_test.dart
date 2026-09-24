import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/native_vpn_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'disposing an overlapping screen cannot cancel the remaining native listener',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const name = 'com.granivpn.mobile/vpn_state';
    const channel = MethodChannel(name);
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    final first = <Map<dynamic, dynamic>>[];
    final second = <Map<dynamic, dynamic>>[];
    final a = NativeVpnService.nativeVpnStateEvents.listen(first.add);
    final b = NativeVpnService.nativeVpnStateEvents.listen(second.add);
    addTearDown(() async {
      await a.cancel();
      await b.cancel();
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((c) => c == 'listen'), hasLength(1));
    await a.cancel();
    expect(calls.where((c) => c == 'cancel'), isEmpty);
    final delivered = Completer<void>();
    // Exercise the codec/channel boundary, not just the controller callback.
    messenger.handlePlatformMessage(
        name,
        codec.encodeSuccessEnvelope({
          'emit_type': 'connectivity_probe',
          'public_ok': true,
          'runtime_session_id': 'current-runtime',
          'public_probe_route': 'local_tunnel_proxy',
        }),
        (_) => delivered.complete());
    await delivered.future;
    await Future<void>.delayed(Duration.zero);
    expect(first, isEmpty);
    expect(second.single['emit_type'], 'connectivity_probe');
    expect(second.single['runtime_session_id'], 'current-runtime');
    await b.cancel();
    expect(calls.where((c) => c == 'cancel'), hasLength(1));
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
}
