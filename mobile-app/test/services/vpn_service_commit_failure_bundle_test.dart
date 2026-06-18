import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/services/vpn_service.dart';

void main() {
  group('VpnService commit failure reason', () {
    test('classifies commit_failed_no_traffic first', () {
      final reason = VpnService.classifyCommitFailureReasonForTest(
        publicOk: true,
        apiOk: true,
        trafficSeen: false,
      );
      expect(reason, equals('commit_failed_no_traffic'));
    });

    test('classifies commit_failed_public_only', () {
      final reason = VpnService.classifyCommitFailureReasonForTest(
        publicOk: false,
        apiOk: true,
        trafficSeen: true,
      );
      expect(reason, equals('commit_failed_public_only'));
    });

    test('classifies commit_failed_api_only', () {
      final reason = VpnService.classifyCommitFailureReasonForTest(
        publicOk: true,
        apiOk: false,
        trafficSeen: true,
      );
      expect(reason, equals('commit_failed_api_only'));
    });
  });

  group('VpnService commit failure bundle', () {
    test('includes effective outbounds and runtime diag snapshot', () {
      final now = DateTime(2026, 5, 6, 12, 0, 10);
      final probeAt = DateTime(2026, 5, 6, 12, 0, 0);
      final runtimeDiagAt = DateTime(2026, 5, 6, 12, 0, 5);
      final bundle = VpnService.buildCommitFailureBundleForTest(
        reasonClass: 'commit_failed_public_only',
        trafficSeen: true,
        publicOk: false,
        apiOk: true,
        failedProbeCount: 3,
        connectionSessionId: 'sid-1',
        trigger: 'ui_tap',
        effectiveOutbounds: 'proxy/vless/45.12.132.94:4443/none',
        probeAt: probeAt,
        runtimeDiagAt: runtimeDiagAt,
        runtimeDiag: <String, dynamic>{
          'event_name': 'runtime_fail',
          'reason': 'tun2socks_exited',
        },
        now: now,
      );

      expect(bundle['reason_class'], equals('commit_failed_public_only'));
      expect(bundle['traffic_seen'], isTrue);
      expect(bundle['public_ok'], isFalse);
      expect(bundle['api_ok'], isTrue);
      expect(bundle['failed_probe_count'], equals(3));
      expect(bundle['connection_session_id'], equals('sid-1'));
      expect(bundle['trigger'], equals('ui_tap'));
      expect(bundle['effective_outbounds'],
          equals('proxy/vless/45.12.132.94:4443/none'));
      expect(bundle['probe_age_ms'], equals(10000));
      expect(bundle['last_native_runtime_diag_age_ms'], equals(5000));
      expect(bundle['last_native_runtime_diag'], isA<Map<String, dynamic>>());
      expect(
        (bundle['last_native_runtime_diag'] as Map<String, dynamic>)['reason'],
        equals('tun2socks_exited'),
      );
    });
  });
}
