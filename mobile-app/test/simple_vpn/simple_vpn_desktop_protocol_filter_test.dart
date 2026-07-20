import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_api.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('desktop runtimes expose only protocols they can start', () {
    for (final desktopRuntime in <SimpleVpnRuntime>[
      const WindowsSimpleVpnRuntime(),
      const MacOSSimpleVpnRuntime(),
    ]) {
      final controller = SimpleVpnController(runtime: desktopRuntime);
      addTearDown(controller.dispose);

      expect(
        controller.protocols.map((protocol) => protocol.id),
        orderedEquals(<String>['graniwg']),
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
    }
  });
}
