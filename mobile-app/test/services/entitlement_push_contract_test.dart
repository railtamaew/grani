import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/entitlement_push_contract.dart';

void main() {
  group('EntitlementPushContract', () {
    test('mapRequestsVpnStop true when grani_action is stop_vpn', () {
      expect(
        EntitlementPushContract.mapRequestsVpnStop({'grani_action': 'stop_vpn'}),
        isTrue,
      );
      expect(
        EntitlementPushContract.mapRequestsVpnStop({'grani_action': '  stop_vpn  '}),
        isTrue,
      );
    });

    test('mapRequestsVpnStop false otherwise', () {
      expect(EntitlementPushContract.mapRequestsVpnStop({}), isFalse);
      expect(
        EntitlementPushContract.mapRequestsVpnStop({'grani_action': 'other'}),
        isFalse,
      );
    });
  });
}
