import 'dart:async';
import 'dart:io';

import 'package:carwarehub_noxdrive/adb/adb_client.dart';
import 'package:carwarehub_noxdrive/adb/adb_executor.dart';
import 'package:carwarehub_noxdrive/adb/hu_mirror.dart';
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
  group('lastLines: причина падения scrcpy для мастера и админа', () {
    test('берутся строки с ошибкой', () {
      const out =
          'scrcpy 5.0.1 <https://github.com/Genymobile/scrcpy>\r\n'
          'INFO: ADB device found\r\n'
          'ERROR: Could not find any H.264 encoder\r\n'
          'ERROR: Server connection failed\r\n';
      expect(
        lastLines(out),
        'ERROR: Could not find any H.264 encoder / ERROR: Server connection failed',
      );
    });
    test('пустой вывод', () => expect(lastLines(''), 'вывода нет'));
  });

  group('pipeFailed: как понимать ответ adb exec-in', () {
    // adb exec-in не возвращает вывод команды на ГУ: при успешной установке ответ пустой.
    test('пустой ответ и код 0: успех (так выглядит любая установка APK)', () {
      expect(pipeFailed(0, ''), isFalse);
    });
    test('Success: успех', () => expect(pipeFailed(0, 'Success'), isFalse));
    test('явный отказ установщика: ошибка', () {
      expect(
        pipeFailed(0, 'Failure [INSTALL_FAILED_VERSION_DOWNGRADE]'),
        isTrue,
      );
    });
    test('ненулевой код: ошибка', () => expect(pipeFailed(1, ''), isTrue));
    test('слово error в обычном выводе не ошибка', () {
      expect(pipeFailed(0, 'loading error_icon.png'), isFalse);
    });
  });

  test(
    'зависший процесс убивается по таймауту, а не остаётся в системе',
    () async {
      // ping -n 30 висит ~30 секунд; ждём всего 1 секунду.
      final sw = Stopwatch()..start();
      await expectLater(
        runWithTimeout('ping', [
          '-n',
          '30',
          '127.0.0.1',
        ], const Duration(seconds: 1)),
        throwsA(isA<TimeoutException>()),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    },
    skip: !Platform.isWindows ? 'только Windows' : false,
  );

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
