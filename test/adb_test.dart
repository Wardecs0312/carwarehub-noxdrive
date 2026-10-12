import 'package:carwarehub_noxdrive/adb/adb_client.dart';
import 'package:carwarehub_noxdrive/adb/adb_status.dart';
import 'package:carwarehub_noxdrive/adb/adb_status_checker.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeClient implements AdbClient {
  _FakeClient(this.statuses);
  final List<AdbStatus> statuses;
  int i = 0;
  @override
  Future<AdbStatus> readStatus() async =>
      statuses[i < statuses.length ? i++ : statuses.length - 1];
}

void main() {
  group('parseAdbDevices', () {
    test('нет устройств', () {
      expect(
        parseAdbDevices('List of devices attached\n\n').connection,
        AdbConnection.disconnected,
      );
    });
    test('устройство подключено', () {
      final s = parseAdbDevices(
        'List of devices attached\r\n192.168.1.5:5555\tdevice product:x model:Changan_Q05 device:y\r\n',
      );
      expect(s.connection, AdbConnection.connected);
      expect(s.model, 'Changan_Q05');
    });
    test('не разрешена отладка', () {
      expect(
        parseAdbDevices('List of devices attached\nABC\tunauthorized\n')
            .connection,
        AdbConnection.unauthorized,
      );
    });
    test('offline считается отсутствием', () {
      expect(
        parseAdbDevices('List of devices attached\nABC\toffline\n').connection,
        AdbConnection.disconnected,
      );
    });
    test('игнорирует строки запуска демона', () {
      expect(
        parseAdbDevices(
          '* daemon not running; starting now *\n* daemon started *\nList of devices attached\nABC\tdevice\n',
        ).connection,
        AdbConnection.connected,
      );
    });
  });

  test('checker выдаёт только изменения статуса', () async {
    const off = AdbStatus(AdbConnection.disconnected);
    const on = AdbStatus(AdbConnection.connected, serial: 'A');
    final checker = AdbStatusChecker(
      _FakeClient([off, off, on, on, off]),
      interval: const Duration(milliseconds: 1),
    );
    final got = await checker.watch().take(3).toList();
    expect(got, [off, on, off]);
  });
}
