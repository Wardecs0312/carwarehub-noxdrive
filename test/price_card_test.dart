import 'package:carwarehub_noxdrive/adb/adb_status.dart';
import 'package:carwarehub_noxdrive/adb/adb_status_checker.dart';
import 'package:carwarehub_noxdrive/data/catalog_repository.dart';
import 'package:carwarehub_noxdrive/data/models.dart';
import 'package:carwarehub_noxdrive/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// Демо-режим (без Supabase): прайс-лист из встроенных данных, как в базе после миграции 0008.
Future<void> _pickModel(
  WidgetTester tester,
  String title, {
  double width = 1400,
  Map<String, int> special = const {},
}) async {
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        adbStatusProvider.overrideWith(
          (_) => Stream.value(const AdbStatus(AdbConnection.disconnected)),
        ),
        myPricesProvider.overrideWith((_) async => special),
      ],
      child: const NoxDriveApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

const nb = ' ';

void main() {
  test('рубли с пробелом между разрядами', () {
    expect(formatRub(4000), '4${nb}000$nb₽');
    expect(formatRub(500), '500$nb₽');
  });

  test(
    'цена только в кредитах (кастомный голос): рубли и доллары не показываются',
    () {
      expect(moneyText(0, 0), '');
      expect(moneyText(4000, 48), '4${nb}000$nb₽ / \$48');
    },
  );

  testWidgets('UNI-V: 4 + 2 кредита, итог 6 кр.', (tester) async {
    await _pickModel(tester, 'Changan UNI-V');
    expect(find.text('Стоимость для Changan UNI-V'), findsOneWidget);
    expect(find.text('Обычный доступ: русификация'), findsOneWidget);
    expect(find.text('4 кр.'), findsOneWidget);
    expect(find.text('2 кр.'), findsOneWidget);
    expect(find.text('4${nb}000$nb₽ / \$48'), findsOneWidget);
    expect(find.text('Н/Д'), findsNothing);
    expect(_text(tester, 'price-total'), '6 кр.');
    expect(_text(tester, 'price-total-money'), '6${nb}000$nb₽ / \$71');
  });

  testWidgets('Q05: перевод приборной панели и вывод на неё — Н/Д', (
    tester,
  ) async {
    await _pickModel(tester, 'Changan Q05');
    expect(find.text('Перевод приборной панели — Н/Д'), findsOneWidget);
    expect(find.text('Н/Д'), findsOneWidget);
    expect(_text(tester, 'price-total'), '4 кр.');
  });

  testWidgets('на ширине телефона карточка помещается', (tester) async {
    await _pickModel(tester, 'Changan UNI-V', width: 360);
    expect(find.byKey(const Key('price-card')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('специальная цена мастера: 2 кр. вместо 4, итог пересчитан', (
    tester,
  ) async {
    await _pickModel(tester, 'Changan UNI-V', special: {'complex': 2});
    expect(find.text('2 кр.'), findsNWidgets(2));
    expect(find.text('обычно 4 кр.'), findsOneWidget);
    expect(_text(tester, 'price-total'), '4 кр.');
    expect(_text(tester, 'price-total-money'), 'ваша специальная цена');
  });
}
