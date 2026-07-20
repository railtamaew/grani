import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/entitlement_push_contract.dart';

void main() {
  group('EntitlementPushContract', () {
    test('mapRequestsVpnStop true for stop_vpn with terminal reason', () {
      expect(
        EntitlementPushContract.mapRequestsVpnStop({
          'grani_action': 'stop_vpn',
          'reason': 'subscription_expired',
        }),
        isTrue,
      );
      expect(
        EntitlementPushContract.mapRequestsVpnStop({
          'grani_action': '  stop_vpn  ',
          'reason': '  device_revoked  ',
        }),
        isTrue,
      );
    });

    test('mapRequestsVpnStop false without an allowed terminal reason', () {
      expect(
        EntitlementPushContract.mapRequestsVpnStop({
          'grani_action': 'stop_vpn',
        }),
        isFalse,
      );
      expect(
        EntitlementPushContract.mapRequestsVpnStop({
          'grani_action': 'stop_vpn',
          'reason': 'subscription_required',
        }),
        isFalse,
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
