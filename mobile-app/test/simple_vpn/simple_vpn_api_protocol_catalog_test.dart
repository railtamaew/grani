import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/simple_vpn/simple_vpn_api.dart';

import '../support/fake_api_client.dart';

void main() {
  for (final body in <Map<String, dynamic>>[
    {
      'detail': {'code': 'SERVER_UNAVAILABLE', 'server_id': 12}
    },
    {
      'error': {
        'code': 'HTTP_CONFLICT',
        'message': "{'code': 'SERVER_UNAVAILABLE', 'server_id': 12}"
      }
    },
  ]) {
    test('retired node error is recognized in backend envelope $body',
        () async {
      final request = RequestOptions(path: '/simple-vpn/session/start');
      final client = FakeApiClient()
        ..postException = DioException(
          requestOptions: request,
          type: DioExceptionType.badResponse,
          response: Response<dynamic>(
              requestOptions: request, statusCode: 409, data: body),
        );
      expect(SimpleVpnApi(apiClient: client).startSession(serverId: 12),
          throwsA(isA<SimpleVpnServerUnavailableException>()));
    });
  }

  test('backend protocol catalog remains authoritative when AWG is omitted',
      () async {
    final apiClient = FakeApiClient()
      ..stubGetResponse = Response<dynamic>(
        requestOptions: RequestOptions(path: '/simple-vpn/protocols'),
        data: <String, dynamic>{
          'success': true,
          'default_protocol': 'vless_ws',
          'protocols': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'vless_ws',
              'engine': 'xray',
              'status': 'active',
              'role': 'fallback',
            },
            <String, dynamic>{
              'id': 'hysteria2',
              'engine': 'hysteria2',
              'status': 'active',
              'role': 'fallback',
            },
          ],
        },
      );

    final protocols = await SimpleVpnApi(apiClient: apiClient).fetchProtocols();

    expect(protocols.map((protocol) => protocol.id), <String>[
      'vless_ws',
      'hysteria2',
    ]);
  });

  test('malformed protocol catalog fails instead of enabling local protocols',
      () async {
    final apiClient = FakeApiClient()
      ..stubGetResponse = Response<dynamic>(
        requestOptions: RequestOptions(path: '/simple-vpn/protocols'),
        data: <String, dynamic>{'success': true},
      );

    expect(
      SimpleVpnApi(apiClient: apiClient).fetchProtocols(),
      throwsA(isA<StateError>()),
    );
  });
}
