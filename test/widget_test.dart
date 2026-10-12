import 'package:carwarehub_noxdrive/adb/adb_status.dart';
import 'package:carwarehub_noxdrive/adb/adb_status_checker.dart';
import 'package:carwarehub_noxdrive/app/theme.dart';
import 'package:carwarehub_noxdrive/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _vin = 'LS5A3ABC1NA000123';

Future<void> _pump(WidgetTester tester, AdbStatus status, {String? vin}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [adbStatusProvider.overrideWith((_) => Stream.value(status))],
      child: const NoxDriveApp(),
    ),
  );
  await tester.pumpAndSettle();
  if (vin != null) {
    await tester.enterText(find.byKey(const Key('vin-field')), vin);
  }
  await tester.tap(find.text('Changan Q05'));
  await tester.pumpAndSettle();
}

Color _dotColor(WidgetTester tester) =>
    ((tester.widget<Container>(find.byKey(const Key('adb-dot')))).decoration
            as BoxDecoration)
        .color!;

Iterable<InkWell> _cards(WidgetTester tester) => tester.widgetList<InkWell>(
  find.descendant(of: find.byType(Card), matching: find.byType(InkWell)),
);

void main() {
  testWidgets('шапка: бренд и контакт поддержки', (tester) async {
    await _pump(tester, const AdbStatus(AdbConnection.disconnected));
    expect(find.text('nox.drive'), findsOneWidget);
    expect(find.text('AUTOMOTIVE TECHNOLOGY'), findsOneWidget);
    expect(find.text('ДЛЯ АДБ ДОСТУПА ПИСАТЬ В ТГ @wiqqq99'), findsOneWidget);
  });

  testWidgets('нет ADB: красный индикатор, услуги заблокированы с подсказкой', (
    tester,
  ) async {
    await _pump(tester, const AdbStatus(AdbConnection.disconnected), vin: _vin);

    expect(find.text('ADB: Не подключено'), findsOneWidget);
    expect(_dotColor(tester), NoxColors.bad);
    expect(find.byTooltip('Подключите автомобиль по USB/ADB'), findsWidgets);
    expect(_cards(tester), isNotEmpty);
    expect(_cards(tester).every((w) => w.onTap == null), isTrue);
  });

  testWidgets('ADB есть, но VIN не введён: услуги заблокированы', (
    tester,
  ) async {
    await _pump(tester, const AdbStatus(AdbConnection.connected, serial: 'A'));

    expect(find.text('ADB: Подключено (Устройство активно)'), findsOneWidget);
    expect(_dotColor(tester), NoxColors.ok);
    expect(find.byTooltip('Введите VIN (17 символов)'), findsWidgets);
    expect(_cards(tester).every((w) => w.onTap == null), isTrue);
  });

  testWidgets('«Назад» возвращает к выбору модели', (tester) async {
    await _pump(tester, const AdbStatus(AdbConnection.connected, serial: 'A'));
    expect(_cards(tester), isNotEmpty);
    await tester.tap(find.byKey(const Key('back-to-models')));
    await tester.pumpAndSettle();
    expect(_cards(tester), isEmpty);
    expect(find.text('Выберите модель автомобиля'), findsOneWidget);
  });

  testWidgets('ADB и VIN готовы: услуги активны', (tester) async {
    await _pump(
      tester,
      const AdbStatus(AdbConnection.connected, serial: 'A'),
      vin: _vin,
    );

    expect(find.text('Русификация и установка приложений'), findsOneWidget);
    expect(_cards(tester).length, 6);
    expect(_cards(tester).every((w) => w.onTap != null), isTrue);
  });

  testWidgets('VIN с буквой O считается неверным', (tester) async {
    await _pump(
      tester,
      const AdbStatus(AdbConnection.connected, serial: 'A'),
      vin: 'LS5A3ABC1NO000123',
    );
    expect(find.text('В VIN нет букв I, O, Q'), findsOneWidget);
    expect(_cards(tester).every((w) => w.onTap == null), isTrue);
  });
}
