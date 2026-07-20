import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_api.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows exposes GRANIwg and Hysteria2 with GRANIwg as default', () {
    final controller = SimpleVpnController(
      runtime: const WindowsSimpleVpnRuntime(),
    );
    addTearDown(controller.dispose);

    expect(
      controller.protocols.map((protocol) => protocol.id),
      orderedEquals(<String>['hysteria2', 'graniwg']),
    );
    expect(controller.selectedProtocol.id, 'graniwg');

    controller.selectProtocol(
      SimpleVpnProtocol(
        id: 'vless_ws',
        engine: 'xray',
        status: 'active',
        role: 'fallback',
      ),
    );
    expect(controller.selectedProtocol.id, 'graniwg');

    controller.selectProtocol(controller.protocols.first);
    expect(controller.selectedProtocol.id, 'hysteria2');
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
