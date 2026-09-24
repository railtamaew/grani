import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/simple_vpn/vpn_network_notice.dart';
import 'package:mobile_app/l10n/app_localizations_en.dart';
import 'package:mobile_app/l10n/app_localizations_ru.dart';
import 'package:mobile_app/screens/main/vpn_shell_ui_helpers.dart';

Map<String, dynamic> failed({String network = 'wifi-1'}) => {
      'check_completed': true,
      'network_available': true,
      'network_id': network,
      'probe_attempts': 2,
      'probe_successes': 0,
      'validated': false,
    };
const absent = <String, dynamic>{
  'check_completed': true,
  'network_available': false,
  'network_id': 'none',
};

void main() {
  test('does not call diagnostics on the successful fast connection path', () {
    fakeAsync((clock) {
      var calls = 0;
      final monitor = VpnNetworkNoticeMonitor(
          check: () async {
            calls++;
            return failed();
          },
          onChanged: () {});
      monitor.start();
      clock.elapse(const Duration(seconds: 4));
      monitor.reset(); // Native data-plane verified.
      clock.elapse(const Duration(minutes: 2));
      expect(calls, 0);
      expect(monitor.notice, isNull);
      monitor.dispose();
    });
  });

  test('requires two rounds, remains bounded, and expires stale notice', () {
    fakeAsync((clock) {
      var calls = 0;
      final monitor = VpnNetworkNoticeMonitor(
          check: () async {
            calls++;
            return failed();
          },
          onChanged: () {});
      monitor.start();
      clock.elapse(const Duration(seconds: 8));
      clock.flushMicrotasks();
      expect(calls, 1);
      expect(monitor.notice, isNull);
      clock.elapse(const Duration(seconds: 3));
      clock.flushMicrotasks();
      expect(calls, 2);
      expect(monitor.notice, VpnNetworkNotice.internetUnconfirmed);
      clock.elapse(const Duration(minutes: 2));
      expect(calls, 2);
      expect(monitor.notice, isNull);
      monitor.dispose();
    });
  });

  test('network change between rounds cannot establish an outage', () {
    expect(
        VpnNetworkNoticeMonitor.classify(failed(), failed(network: 'cell-2')),
        isNull);
    expect(VpnNetworkNoticeMonitor.classify(absent, failed()), isNull);
  });

  test('positive evidence never becomes a no-internet notice', () {
    expect(
        VpnNetworkNoticeMonitor.classify(
            failed(), {...failed(), 'probe_successes': 1}),
        VpnNetworkNotice.vpnUnconfirmed);
    expect(
        VpnNetworkNoticeMonitor.classify(
            {...failed(), 'validated': true}, failed()),
        VpnNetworkNotice.vpnUnconfirmed);
  });

  test(
      'missing diagnostics, unsupported version and partial rounds are unknown',
      () {
    expect(VpnNetworkNoticeMonitor.classify({}, failed()), isNull);
    expect(VpnNetworkNoticeMonitor.classify({'check_completed': false}, absent),
        isNull);
    expect(
        VpnNetworkNoticeMonitor.classify(
            {...failed(), 'probe_attempts': 1}, failed()),
        isNull);
  });

  test('only two explicit absent-network observations show no-network', () {
    expect(VpnNetworkNoticeMonitor.classify(absent, absent),
        VpnNetworkNotice.noNetwork);
    expect(
        VpnNetworkNoticeMonitor.classify({'network_available': false}, absent),
        isNull);
  });

  test('repeated portal indication suggests sign-in without asserting a cause',
      () {
    final portal = {
      ...failed(),
      'captive_portal': true,
      'network_type': 'wifi'
    };
    expect(VpnNetworkNoticeMonitor.classify(portal, portal),
        VpnNetworkNotice.signIn);
    expect(
        VpnNetworkNoticeMonitor.classify(
            portal, {...portal, 'probe_successes': 1}),
        VpnNetworkNotice.vpnUnconfirmed);
    expect(
        VpnNetworkNoticeMonitor.classify(
            portal, {...portal, 'validated': true}),
        VpnNetworkNotice.vpnUnconfirmed);
    final mobile = {...portal, 'network_type': 'mobile'};
    expect(VpnNetworkNoticeMonitor.classify(mobile, mobile),
        VpnNetworkNotice.internetUnconfirmed);
  });

  for (final dispose in [false, true]) {
    test('late result ignored after ${dispose ? 'dispose' : 'success/cancel'}',
        () {
      fakeAsync((clock) {
        final pending = Completer<Map<String, dynamic>>();
        var changes = 0;
        var calls = 0;
        final monitor = VpnNetworkNoticeMonitor(check: () {
          calls++;
          return pending.future;
        }, onChanged: () {
          changes++;
        });
        monitor.start(immediately: true);
        clock.elapse(Duration.zero);
        if (dispose) {
          monitor.dispose();
        } else {
          monitor.reset();
        }
        pending.complete(failed());
        clock.flushMicrotasks();
        clock.elapse(const Duration(minutes: 1));
        expect(monitor.notice, isNull);
        expect(changes, 0);
        expect(calls, 1);
        monitor.dispose();
      });
    });
  }

  test('a diagnostics timeout is not an offline result', () {
    fakeAsync((clock) {
      final monitor = VpnNetworkNoticeMonitor(
          check: () => Completer<Map<String, dynamic>>().future,
          onChanged: () {});
      monitor.start(immediately: true);
      clock.elapse(const Duration(seconds: 40));
      expect(monitor.notice, isNull);
      monitor.dispose();
    });
  });

  test('all notice variants have localized user messages', () {
    for (final notice in VpnNetworkNotice.values) {
      final en =
          VpnShellUiHelpers.networkNoticeBody(notice, AppLocalizationsEn());
      final ru =
          VpnShellUiHelpers.networkNoticeBody(notice, AppLocalizationsRu());
      expect(en, isNotEmpty);
      expect(ru, isNotEmpty);
      expect(en, isNot(ru));
      expect(en.toLowerCase(), isNot(contains('whitelist')));
      expect(ru.toLowerCase(), isNot(contains('белые списки')));
    }
  });
}
