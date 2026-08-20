import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/cache/cache_service.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_api.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CacheService().initialize();
  });

  test('Windows exposes all implemented runtimes with GRANIwg as default',
      () async {
    final controller = SimpleVpnController(
      api: _NoopSimpleVpnApi(),
      runtime: const _TestWindowsSimpleVpnRuntime(),
      subscribeNativeState: false,
    );
    addTearDown(controller.dispose);

    await controller.restoreInitialNativeState(source: 'desktop_filter_test');

    expect(
      controller.protocols.map((protocol) => protocol.id),
      orderedEquals(<String>['vless_ws', 'hysteria2', 'graniwg']),
    );
    expect(controller.selectedProtocol.id, 'graniwg');

    controller.selectProtocol(controller.protocols.first);
    expect(controller.selectedProtocol.id, 'vless_ws');
  });

  test('macOS keeps unsupported fallback protocols hidden', () {
    final controller = SimpleVpnController(
      runtime: const MacOSSimpleVpnRuntime(),
    );
    addTearDown(controller.dispose);

    expect(
      controller.protocols.map((protocol) => protocol.id),
      orderedEquals(<String>['graniwg']),
    );
    expect(controller.selectedProtocol.id, 'graniwg');
  });
}

class _TestWindowsSimpleVpnRuntime extends WindowsSimpleVpnRuntime {
  const _TestWindowsSimpleVpnRuntime();

  @override
  Future<bool?> getAmneziaWgStatus() async => false;

  @override
  Future<bool?> getNativeConnectionStatus() async => false;
}

class _NoopSimpleVpnApi extends SimpleVpnApi {
  @override
  Future<void> log({
    required String event,
    String level = 'info',
    String? sessionId,
    String? deviceId,
    Map<String, dynamic>? details,
  }) async {}
}
