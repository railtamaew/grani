import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows exposes all implemented runtimes with GRANIwg as default',
      () async {
    final controller = SimpleVpnController(
      runtime: const WindowsSimpleVpnRuntime(),
    );
    addTearDown(controller.dispose);

    expect(
      controller.protocols.map((protocol) => protocol.id),
      orderedEquals(<String>['vless_ws', 'hysteria2', 'graniwg']),
    );
    expect(controller.selectedProtocol.id, 'graniwg');

    // Protocol controls are intentionally locked until the one-time native
    // state restore completes. Mirror the real screen lifecycle before
    // exercising user selection.
    await controller.restoreInitialNativeState(
      source: 'desktop_protocol_filter_test',
    );
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
