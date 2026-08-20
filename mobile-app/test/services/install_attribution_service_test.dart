import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/install_attribution_service.dart';

void main() {
  test('lifecycle attribution stays compact for Firebase events', () {
    final parameters =
        InstallAttributionService.lifecycleAttributionParameters(const {
      'utm_source': 'google',
      'utm_medium': 'cpc',
      'utm_campaign': 'launch',
      'utm_content': 'video',
      'utm_term': 'vpn',
      'landing': '/ru',
      'locale': 'ru',
      'variant': 'control',
      'campaign': 'duplicate-name',
      'ad_group': 'group-1',
      'keyword_cluster': 'vpn',
      'attribution_id': '00000000-0000-0000-0000-000000000000',
      'click_time': '1775332800',
      'gclid': 'gclid-value',
      'gbraid': 'gbraid-value',
      'wbraid': 'wbraid-value',
    });

    expect(parameters, {
      'utm_source': 'google',
      'utm_medium': 'cpc',
      'utm_campaign': 'launch',
      'attribution_id': '00000000-0000-0000-0000-000000000000',
      'has_gclid': 1,
      'has_gbraid': 1,
      'has_wbraid': 1,
    });
    expect(parameters.length, lessThanOrEqualTo(7));
  });
}
