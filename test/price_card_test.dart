import 'package:carwarehub_noxdrive/adb/adb_status.dart';
import 'package:carwarehub_noxdrive/adb/adb_status_checker.dart';
import 'package:carwarehub_noxdrive/data/models.dart';
import 'package:carwarehub_noxdrive/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// Демо-режим (без Supabase): прайс-лист из встроенных данных, как в базе после миграции 0008.
Future<void> _pickModel(WidgetTester tester, String title) async {
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        adbStatusProvider.overrideWith(
          (_) => Stream.value(const AdbStatus(AdbConnection.disconnected)),
        ),
      ],
      child: const NoxDriveApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

String _total(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('price-total'))).data!;

void main() {
  test('рубли с пробелом между разрядами', () {
    expect(formatRub(4000), '4 000 ₽');
    expect(formatRub(500), '500 ₽');
  });

  testWidgets('UNI-V: пакет и вывод на приборную панель, итог 6 000 ₽ / \$71', (
    tester,
  ) async {
    await _pickModel(tester, 'Changan UNI-V');
    expect(find.text('Стоимость для Changan UNI-V'), findsOneWidget);
    expect(find.text('Комплексный пакет'), findsOneWidget);
    expect(find.text('4 000 ₽ / \$48'), findsOneWidget);
    expect(find.text('2 000 ₽ / \$23'), findsOneWidget);
    expect(find.text('Н/Д'), findsNothing);
    expect(_total(tester), '6 000 ₽ / \$71');
  });

  testWidgets('Q05: перевод приборной панели и вывод на неё — Н/Д', (
    tester,
  ) async {
    await _pickModel(tester, 'Changan Q05');
    expect(find.text('Перевод приборной панели — Н/Д'), findsOneWidget);
    expect(find.text('Н/Д'), findsOneWidget);
    expect(_total(tester), '4 000 ₽ / \$48');
  });
}
