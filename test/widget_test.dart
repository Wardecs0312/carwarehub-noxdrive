import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:carwarehub_noxdrive/adb/adb_status.dart';
import 'package:carwarehub_noxdrive/adb/adb_status_checker.dart';
import 'package:carwarehub_noxdrive/main.dart';

Future<void> _pump(WidgetTester tester, AdbStatus status) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [adbStatusProvider.overrideWith((_) => Stream.value(status))],
      child: const NoxDriveApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Changan Q05'));
  await tester.pumpAndSettle();
}

Color _dotColor(WidgetTester tester) =>
    ((tester.widget<Container>(find.byKey(const Key('adb-dot')))).decoration
            as BoxDecoration)
        .color!;

void main() {
  testWidgets(
    'нет ADB: красный индикатор, кнопки услуг заблокированы с подсказкой',
    (tester) async {
      await _pump(tester, const AdbStatus(AdbConnection.disconnected));

      expect(find.text('Не подключено'), findsOneWidget);
      expect(_dotColor(tester), const Color(0xFFE5484D));
      expect(find.byTooltip('Подключите автомобиль по USB/ADB'), findsWidgets);
      final inkWells = tester.widgetList<InkWell>(
        find.descendant(of: find.byType(Card), matching: find.byType(InkWell)),
      );
      expect(inkWells, isNotEmpty);
      expect(inkWells.every((w) => w.onTap == null), isTrue);
    },
  );

  testWidgets('ADB подключён: зелёный индикатор, кнопки активны', (
    tester,
  ) async {
    await _pump(
      tester,
      const AdbStatus(AdbConnection.connected, serial: 'A', model: 'Q05'),
    );

    expect(find.textContaining('Подключено'), findsOneWidget);
    expect(_dotColor(tester), const Color(0xFF2EE66B));
    expect(find.text('Русификация и установка приложений'), findsOneWidget);
    final inkWells = tester.widgetList<InkWell>(
      find.descendant(of: find.byType(Card), matching: find.byType(InkWell)),
    );
    expect(inkWells.every((w) => w.onTap != null), isTrue);
  });
}
