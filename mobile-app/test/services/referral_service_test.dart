import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_app/services/referral_service.dart';
import 'package:mobile_app/core/storage/shared_preferences_holder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => SharedPreferences.setMockInitialValues({}));
  setUp(() async => (await getSharedPreferences()).clear());

  test('only exact owned HTTPS invitation links are accepted', () {
    expect(
      ReferralService.codeFromUri(
        Uri.parse('https://granilink.com/r/abcd2345efgh'),
      ),
      'ABCD2345EFGH',
    );
    expect(
      ReferralService.codeFromUri(
        Uri.parse(
          'https://granilink.com/open/invite?referral_code=ABCD2345EFGH',
        ),
      ),
      'ABCD2345EFGH',
    );
    for (final url in [
      'https://evil.test/r/ABCD2345EFGH',
      'http://granilink.com/r/ABCD2345EFGH',
      'https://granilink.com/r/ABCD2345EFGH/extra',
      'https://granilink.com/r/bad',
    ]) {
      expect(ReferralService.codeFromUri(Uri.parse(url)), isNull);
    }
  });
  test(
    'first valid code persists through restart and rejected formats do not erase it',
    () async {
      final first = ReferralService.test(
        MockClient((_) async => http.Response('{}', 200)),
      );
      await first.capture('bad');
      await first.capture('abcd2345efgh');
      await first.capture('OTHER2345ABC');
      final restarted = ReferralService.test(
        MockClient((_) async => http.Response('{}', 200)),
      );
      expect(await restarted.pendingCode(), 'ABCD2345EFGH');
    },
  );
  test(
    'successful server claim removes pending code and is single-flight',
    () async {
      var count = 0;
      final service = ReferralService.test(
        MockClient((request) async {
          count++;
          expect(request.headers['Authorization'], 'Bearer test');
          expect(jsonDecode(request.body)['code'], 'ABCD2345EFGH');
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return http.Response('{"received":{"status":"pending"}}', 200);
        }),
      );
      await service.capture('ABCD2345EFGH');
      expect(
        await Future.wait([
          service.claimPending('test'),
          service.claimPending('test'),
        ]),
        [true, true],
      );
      expect(count, 1);
      expect(await service.pendingCode(), isNull);
    },
  );
  test(
    'manual replacement overrides a link and clears its rejection',
    () async {
      final service = ReferralService.test(
        MockClient(
          (_) async => http.Response('{"detail":"self_referral"}', 409),
        ),
      );
      await service.capture('ABCD2345EFGH');
      await service.claimPending('test');
      expect(await service.claimNotice('test'), 'self_referral');
      await service.replacePendingCode('OTHER2345ABC');
      await service.capture('PASSIVE2345');
      expect(await service.pendingCode(), 'OTHER2345ABC');
      expect(await service.claimNotice('test'), isNull);
      expect(await service.needsGiftReturn(), true);
      await expectLater(
        service.replacePendingCode('bad'),
        throwsA(isA<ReferralFailure>()),
      );
      expect(await service.pendingCode(), 'OTHER2345ABC');
    },
  );
  test(
    'temporary network error keeps code, permanent ineligibility clears it',
    () async {
      var status = 503;
      final service = ReferralService.test(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'detail': status == 503
                  ? 'campaign_unavailable'
                  : 'claim_window_expired',
            }),
            status,
          ),
        ),
      );
      await service.capture('ABCD2345EFGH');
      expect(await service.claimPending('test'), false);
      expect(await service.pendingCode(), 'ABCD2345EFGH');
      status = 409;
      expect(await service.claimPending('test'), false);
      expect(await service.pendingCode(), isNull);
    },
  );
  test(
    'production error envelope clears rejected code and preserves useful reason',
    () async {
      final service = ReferralService.test(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {'code': 'CONFLICT', 'message': 'claim_window_expired'},
            }),
            409,
          ),
        ),
      );
      await service.capture('ABCD2345EFGH');
      expect(await service.claimPending('test'), false);
      expect(await service.pendingCode(), isNull);
      await expectLater(
        service.claim('test', 'ABCD2345EFGH'),
        throwsA(
          isA<ReferralFailure>().having(
            (e) => e.code,
            'code',
            'claim_window_expired',
          ),
        ),
      );
    },
  );
  test(
    'automatic result survives restart and is scoped to the account',
    () async {
      String token(String id) =>
          'header.${base64Url.encode(utf8.encode(jsonEncode({'sub': id})))}.signature';
      final service = ReferralService.test(
        MockClient(
          (_) async => http.Response('{"detail":"existing_customer"}', 409),
        ),
      );
      await service.capture('ABCD2345EFGH');
      expect(await service.claimPending(token('1')), false);
      final restarted = ReferralService.test(
        MockClient((_) async => http.Response('{}', 200)),
      );
      expect(await restarted.claimNotice(token('1')), 'existing_customer');
      expect(await restarted.claimNotice(token('2')), isNull);
      expect(await restarted.needsGiftReturn(), true);
      await restarted.finishGiftView();
      expect(await restarted.needsGiftReturn(), false);
    },
  );
  test('new client asks for v2 and still accepts v1 server terms', () async {
    final service = ReferralService.test(
      MockClient((request) async {
        expect(request.url.queryParameters['client_version'], '2');
        return http.Response(
          '{"reward_days":3,"claim_policy":"24_hours"}',
          200,
        );
      }),
    );
    expect((await service.summary('test'))['reward_days'], 3);
  });
}
