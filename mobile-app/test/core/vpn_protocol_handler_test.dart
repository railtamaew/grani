import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/vpn_protocol_handler/vpn_protocol_handler.dart';
import 'package:mobile_app/models/server.dart';
import 'package:mobile_app/models/vpn_protocol.dart';

/// Тесты контракта VpnProtocolHandler и ProtocolConnectParams.
void main() {
  group('ProtocolConnectParams', () {
    test('создаётся с обязательными полями', () {
      final server = Server(
        id: '1',
        name: 'Test',
        country: 'RU',
        city: 'Moscow',
        ip: '1.2.3.4',
        port: 443,
        isActive: true,
        currentLoad: 0,
        maxLoad: 100,
        ping: 10,
      );
      final params = ProtocolConnectParams(
        token: 'token',
        server: server,
        protocol: VpnProtocol.xrayReality,
        deviceId: 'device-1',
      );
      expect(params.token, 'token');
      expect(params.server.id, '1');
      expect(params.protocol, VpnProtocol.xrayReality);
      expect(params.deviceId, 'device-1');
    });

    test('deviceId может быть null', () {
      final server = Server(
        id: '2',
        name: 'S2',
        country: 'DE',
        city: 'Berlin',
        ip: '5.6.7.8',
        port: 443,
        isActive: true,
        currentLoad: 0,
        maxLoad: 100,
        ping: 20,
      );
      final params = ProtocolConnectParams(token: 't', server: server, protocol: VpnProtocol.xrayReality);
      expect(params.deviceId, isNull);
    });
  });

  group('VpnProtocolHandler (StubHandler)', () {
    test('StubHandler реализует контракт: connect возвращает false', () async {
      final handler = StubVpnProtocolHandler();
      final server = Server(
        id: '1',
        name: 'T',
        country: 'RU',
        city: 'M',
        ip: '1.1.1.1',
        port: 443,
        isActive: true,
        currentLoad: 0,
        maxLoad: 100,
        ping: 1,
      );
      final params = ProtocolConnectParams(token: 't', server: server, protocol: VpnProtocol.xrayVless);
      final result = await handler.connect(params);
      expect(result, isFalse);
    });

    test('StubHandler.applyConfig возвращает false', () async {
      final handler = StubVpnProtocolHandler();
      final result = await handler.applyConfig('{}', VpnProtocol.graniwg);
      expect(result, isFalse);
    });

    test('StubHandler.isConfigValid возвращает false', () {
      final handler = StubVpnProtocolHandler();
      expect(handler.isConfigValid('config', VpnProtocol.xrayVmess), isFalse);
    });
  });
}

/// Заглушка для тестов контракта.
class StubVpnProtocolHandler implements VpnProtocolHandler {
  @override
  Future<bool> connect(ProtocolConnectParams params) async => false;

  @override
  Future<bool> applyConfig(String config, VpnProtocol protocol) async => false;

  @override
  bool isConfigValid(String config, VpnProtocol protocol) => false;
}
