import 'package:carwarehub_noxdrive/adb/adb_status.dart';
import 'package:carwarehub_noxdrive/adb/adb_status_checker.dart';
import 'package:carwarehub_noxdrive/adb/wifi_adb.dart';
import 'package:carwarehub_noxdrive/features/shell/adb_status_badge.dart';
import 'package:carwarehub_noxdrive/jobs/job_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  test('адрес Wi-Fi: wlan важнее точки доступа, eth и lo не берутся', () {
    const out =
        '1: lo    inet 127.0.0.1/8 scope host lo\n'
        '3: eth0    inet 192.168.100.110/24 scope global eth0\n'
        '7: ap0    inet 192.168.43.1/24 scope global ap0\n'
        '9: wlan0    inet 172.20.10.3/28 scope global wlan0\n';
    expect(wifiAddressFrom(out), '172.20.10.3');
    expect(
      wifiAddressFrom('7: ap0    inet 192.168.43.1/24 scope global ap0'),
      '192.168.43.1',
    );
    expect(wifiAddressFrom('3: eth0    inet 192.168.100.110/24'), isNull);
    expect(wifiAddressFrom(''), isNull);
  });

  test('адрес из поля ввода', () {
    expect(normalizeWifiAddress(' 172.20.10.3 '), '172.20.10.3:5555');
    expect(normalizeWifiAddress('172.20.10.3:5556'), '172.20.10.3:5556');
    expect(normalizeWifiAddress('300.1.1.1'), isNull);
    expect(normalizeWifiAddress('машина'), isNull);
    expect(normalizeWifiAddress('1.2.3.4:70000'), isNull);
  });

  test('ответ adb connect', () {
    expect(adbConnectSucceeded('connected to 172.20.10.3:5555'), isTrue);
    expect(
      adbConnectSucceeded('already connected to 172.20.10.3:5555'),
      isTrue,
    );
    expect(
      adbConnectSucceeded(
        'failed to connect to 172.20.10.3:5555: No connection could be made',
      ),
      isFalse,
    );
    expect(adbConnectSucceeded('cannot connect to 1.2.3.4:5555'), isFalse);
  });

  test('сетевое подключение отличается от кабеля', () {
    expect(isNetworkSerial('172.20.10.3:5555'), isTrue);
    expect(isNetworkSerial('a6635ca6'), isFalse);
  });

  testWidgets('нет машины: клик по значку ADB, ввод IP, подключение по Wi-Fi', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final exec = FakeExecutor();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adbExecutorProvider.overrideWithValue(exec),
          adbStatusProvider.overrideWith(
            (_) => Stream.value(const AdbStatus(AdbConnection.disconnected)),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: AdbStatusBadge())),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('adb-wifi-open')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('adb-wifi-address')), 'abc');
    await tester.tap(find.byKey(const Key('adb-wifi-connect')));
    await tester.pump();
    expect(find.textContaining('Введите IP машины'), findsOneWidget);
    expect(exec.calls, isEmpty);

    await tester.enterText(
      find.byKey(const Key('adb-wifi-address')),
      '172.20.10.3',
    );
    await tester.tap(find.byKey(const Key('adb-wifi-connect')));
    await tester.pumpAndSettle();
    expect(exec.calls, ['connect:172.20.10.3:5555']);
    expect(find.byType(AlertDialog), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
