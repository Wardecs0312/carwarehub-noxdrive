import 'package:carwarehub_noxdrive/features/history/history_repository.dart';
import 'package:carwarehub_noxdrive/features/history/history_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

HistoryEntry _e(String vin, String status, {String model = 'Changan UNI-V'}) =>
    HistoryEntry.fromJson({
      'id': vin,
      'vin': vin,
      'status': status,
      'credits': 10,
      'created_at': '2026-10-13T05:30:00Z',
      'device_info': {'build': 'UNIV_RU_2.3.1'},
      'services': {'title': 'Русификация'},
      'masters': {'name': 'Иван'},
      'scenarios': {
        'firmwares': {
          'version_pattern': '%',
          'car_models': {'title': model},
        },
      },
    });

Future<void> _pump(WidgetTester tester, List<HistoryEntry> items) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HistoryList(
          value: AsyncData(items),
          onRefresh: () async {},
          showMaster: true,
          empty: 'пусто',
        ),
      ),
    ),
  );
}

void main() {
  test('запись истории: модель, услуга, прошивка из связанных таблиц', () {
    final e = _e('LS5A3ABC1NA000001', 'success');
    expect(e.model, 'Changan UNI-V');
    expect(e.service, 'Русификация');
    expect(e.firmware, 'UNIV_RU_2.3.1');
    expect(e.masterName, 'Иван');
  });

  test('без прошивки ГУ и связей: понятные подписи', () {
    final e = HistoryEntry.fromJson({'id': 'x', 'status': 'failed'});
    expect(e.model, '—');
    expect(e.firmware, 'любая');
    expect(e.service, 'Услуга');
  });

  testWidgets('список, поиск по VIN и фильтр по статусу', (tester) async {
    await _pump(tester, [
      _e('LS5A3ABC1NA000001', 'success'),
      _e('LS5A3ABC1NA000002', 'failed', model: 'Changan Q05'),
    ]);
    expect(find.text('Changan UNI-V · Русификация'), findsOneWidget);
    expect(find.text('Changan Q05 · Русификация'), findsOneWidget);
    expect(find.textContaining('Мастер: Иван'), findsNWidgets(2));

    await tester.enterText(find.byKey(const Key('history-search')), '000002');
    await tester.pump();
    expect(find.text('Changan UNI-V · Русификация'), findsNothing);
    expect(find.text('Changan Q05 · Русификация'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('history-search')), '');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Выполнено'));
    await tester.pump();
    expect(find.text('Changan Q05 · Русификация'), findsNothing);
    expect(find.text('Changan UNI-V · Русификация'), findsOneWidget);
  });

  testWidgets('пустая история: подсказка', (tester) async {
    await _pump(tester, const []);
    expect(find.text('пусто'), findsOneWidget);
  });
}
