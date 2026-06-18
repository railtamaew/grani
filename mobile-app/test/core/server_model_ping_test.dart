import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/models/server.dart';

void main() {
  test('Server.withPing сохраняет поля и задаёт ping', () {
    final s = Server(
      id: '1',
      name: 'A',
      country: 'RU',
      city: 'M',
      ip: '1.1.1.1',
      port: 51820,
      isActive: true,
      currentLoad: 1,
      maxLoad: 10,
      ping: null,
      xrayPort: 4443,
    );
    final u = s.withPing(42.0);
    expect(u.ping, 42.0);
    expect(u.id, s.id);
    expect(u.xrayPort, 4443);
  });
}
