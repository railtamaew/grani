import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/config/app_config.dart';
import 'package:mobile_app/core/api/endpoint_router.dart';

void main() {
  group('EndpointRouter.resolveKind', () {
    test('maps auth, bootstrap, logging prefix, vpn paths', () {
      expect(EndpointRouter.resolveKind('/auth/login'), RequestKind.auth);
      expect(EndpointRouter.resolveKind('/vpn/bootstrap'), RequestKind.bootstrap);
      expect(EndpointRouter.resolveKind('/vpn/logs/send'), RequestKind.logging);
      expect(EndpointRouter.resolveKind('/vpn/logs/other'), RequestKind.logging);
      expect(EndpointRouter.resolveKind('/vpn/servers'), RequestKind.vpnControl);
      expect(EndpointRouter.resolveKind('/payments/x'), RequestKind.vpnControl);
      expect(EndpointRouter.inferRequestKind('/auth/me'), RequestKind.auth);
    });
  });

  group('EndpointRouter.resolve', () {
    test('auth: single base, one attempt (не refresh)', () async {
      final d = await EndpointRouter.resolve(
        path: '/auth/x',
        kind: RequestKind.auth,
      );
      expect(d.maxAttempts, 1);
      expect(d.bases.length, 1);
      expect(d.bases.first.toString(), AppConfig.apiBaseUrl);
    });

    test('auth refresh-token: два origin как запас к домену', () async {
      final d = await EndpointRouter.resolve(
        path: '/auth/refresh-token',
        kind: RequestKind.auth,
      );
      expect(d.maxAttempts, 2);
      expect(d.bases.length, 2);
      expect(d.bases[0].toString(), AppConfig.apiBaseUrl);
      expect(d.bases[1].toString(), AppConfig.apiDirectIpUrl);
    });

    test('logging: single base, one attempt', () async {
      final d = await EndpointRouter.resolve(
        path: '/vpn/logs/send',
        kind: RequestKind.logging,
      );
      expect(d.maxAttempts, 1);
      expect(d.bases.length, 1);
    });

    test('bootstrap hostname: single base (api.granilink.com)', () async {
      final d = await EndpointRouter.resolve(
        path: '/vpn/bootstrap',
        kind: RequestKind.bootstrap,
        wave: BootstrapWave.hostname,
      );
      expect(d.maxAttempts, 1);
      expect(d.bases.length, 1);
      expect(d.bases.first.toString(), AppConfig.apiBaseUrl);
    });

    test('bootstrap direct: тот же единственный origin', () async {
      final d = await EndpointRouter.resolve(
        path: '/vpn/bootstrap',
        kind: RequestKind.bootstrap,
        wave: BootstrapWave.direct,
      );
      expect(d.maxAttempts, 1);
      expect(d.bases.length, 1);
      expect(d.bases.first.toString(), AppConfig.apiBaseUrl);
    });
  });
}
