import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_app/services/referral_service.dart';
import 'package:mobile_app/core/storage/shared_preferences_holder.dart';

void main() {
  final binding=TestWidgetsFlutterBinding.ensureInitialized();
  const channel=MethodChannel('com.granivpn.mobile/referrals');
  setUpAll(() => SharedPreferences.setMockInitialValues({}));
  setUp(() async {
    debugDefaultTargetPlatformOverride=TargetPlatform.android;
    await (await getSharedPreferences()).clear();
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride=null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,null);
  });
  Future<void> prove(ReferralService service,{bool Function()? connected}) => service.proveConnection(
    token:'test',userId:'1',deviceId:'test-device',serverId:1,protocol:'vless',sessionId:'session',
    stillConnected:connected ?? () => true);

  test('failed proof can retry in same session after cooldown; success is deduplicated',() async {
    var now=DateTime.utc(2026,9,25);var calls=0;
    final service=ReferralService.test(MockClient((_) async => http.Response('{"received":{"status":"pending"}}',200)),now:()=>now);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call) async {
      expect(call.method,'proveConnectionPair');calls++;
      return {'status':calls==1?'unavailable':'rewarded'};
    });
    await prove(service);await prove(service);expect(calls,1);
    now=now.add(const Duration(seconds:31));await prove(service);expect(calls,2);
    now=now.add(const Duration(minutes:1));await prove(service);expect(calls,2);
  });
  test('concurrent UI callbacks launch one native pair that survives leaving screen',() async {
    var calls=0;var connected=true;final started=Completer<void>();final result=Completer<Map<String,dynamic>>();
    final service=ReferralService.test(MockClient((_) async => http.Response('{"received":{"status":"pending"}}',200)));
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call) async {
      calls++;started.complete();return result.future;
    });
    final first=prove(service,connected:()=>connected);await started.future;
    await prove(service);connected=false;result.complete({'status':'rewarded'});await first;
    expect(calls,1);
  });
  test('temporary summary failure is retried without reconnect',() async {
    var now=DateTime.utc(2026,9,25);var reads=0;var calls=0;
    final service=ReferralService.test(MockClient((_) async => ++reads==1
      ? http.Response('{}',503) : http.Response('{"received":{"status":"pending"}}',200)),now:()=>now);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,(_) async {calls++;return {'status':'rewarded'};});
    await prove(service);expect(calls,0);now=now.add(const Duration(seconds:31));await prove(service);expect(calls,1);
  });
}
