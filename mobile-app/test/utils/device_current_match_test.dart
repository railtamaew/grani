import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/utils/device_current_match.dart';

void main() {
  group('isCurrentDeviceCard', () {
    test('only highest id among same device_id', () {
      const uuid = '8bb58947-384a-40b9-bff2-765ab2bc4d6f';
      final all = <Map<String, dynamic>>[
        {'id': 90, 'device_id': uuid},
        {'id': 164, 'device_id': uuid},
        {'id': 166, 'device_id': uuid},
      ];
      expect(isCurrentDeviceCard(all[0], uuid, all), false);
      expect(isCurrentDeviceCard(all[1], uuid, all), false);
      expect(isCurrentDeviceCard(all[2], uuid, all), true);
    });

    test('empty current id is false', () {
      final d = <String, dynamic>{'id': 1, 'device_id': 'a'};
      expect(isCurrentDeviceCard(d, '', [d]), false);
      expect(isCurrentDeviceCard(d, null, [d]), false);
    });

    test('trims ids', () {
      const uuid = 'aa';
      final d = <String, dynamic>{'id': 1, 'device_id': '  aa  '};
      expect(isCurrentDeviceCard(d, 'aa', [d]), true);
    });
  });
}
