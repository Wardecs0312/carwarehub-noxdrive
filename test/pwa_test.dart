import 'package:carwarehub_noxdrive/adb/adb_status.dart';
import 'package:carwarehub_noxdrive/adb/adb_status_checker.dart';
import 'package:carwarehub_noxdrive/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Кабинет мастера в браузере телефона (PWA): узкий экран, USB недоступен.
Future<void> _pumpPhone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 780);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        adbStatusProvider.overrideWith(
          (_) => Stream.value(const AdbStatus(AdbConnection.unsupported)),
        ),
      ],
      child: const NoxDriveApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('телефон: шапка помещается, вместо ADB «Кабинет мастера»', (
    tester,
  ) async {
    await _pumpPhone(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Кабинет мастера'), findsOneWidget);
    expect(find.text('nox.drive'), findsOneWidget);
  });

  testWidgets('телефон: услуги видны, но запуск только на ПК или Android', (
    tester,
  ) async {
    await _pumpPhone(tester);
    await tester.enterText(
      find.byKey(const Key('vin-field')),
      'LS5A3ABC4NA000123',
    );
    await tester.tap(find.text('Changan Q05'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final cards = tester.widgetList<InkWell>(
      find.descendant(of: find.byType(Card), matching: find.byType(InkWell)),
    );
    expect(cards, isNotEmpty);
    expect(cards.every((c) => c.onTap == null), isTrue);
    expect(
      find.byTooltip('Услуги запускаются в программе для Windows или Android'),
      findsWidgets,
    );
  });
}
