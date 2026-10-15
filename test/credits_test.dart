import 'package:carwarehub_noxdrive/features/history/credits_repository.dart';
import 'package:carwarehub_noxdrive/features/history/credits_screen.dart';
import 'package:carwarehub_noxdrive/features/history/history_repository.dart';
import 'package:carwarehub_noxdrive/features/history/history_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

CreditEntry _c(
  String id,
  int amount,
  String reason, {
  String master = 'm1',
  String? note,
  String time = '2026-10-15T10:00:00Z',
}) => CreditEntry.fromJson({
  'id': id,
  'master_id': master,
  'amount': amount,
  'reason': reason,
  'note': note,
  'created_at': time,
  'masters': {'name': master == 'm1' ? 'Иван' : 'Пётр'},
});

HistoryEntry _h(
  String id,
  String vin,
  String time, {
  String service = 'Русификация',
}) => HistoryEntry.fromJson({
  'id': id,
  'vin': vin,
  'status': 'success',
  'credits': 4,
  'created_at': time,
  'services': {'title': service},
  'masters': {'name': 'Иван'},
  'scenarios': {
    'firmwares': {
      'version_pattern': '%',
      'car_models': {'title': 'Changan UNI-V'},
    },
  },
});

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(500, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  test('баланс после каждой операции считается от текущего назад', () {
    // Новые сверху: +100, -4, -4 → текущий 92.
    final rows = CreditEntry.withBalances(
      [_c('3', -4, 'charge'), _c('2', -4, 'charge'), _c('1', 100, 'topup')],
      {'m1': 92},
    );
    expect([for (final r in rows) r.balanceAfter], [92, 96, 100]);
  });

  test('у каждого мастера свой баланс', () {
    final rows = CreditEntry.withBalances(
      [_c('2', 50, 'topup', master: 'm2'), _c('1', -10, 'adjust')],
      {'m1': 0, 'm2': 50},
    );
    expect([for (final r in rows) r.balanceAfter], [50, 0]);
  });

  test('подписи операций', () {
    expect(creditLabel(_c('1', 10, 'topup')), 'Пополнение');
    expect(creditLabel(_c('1', -4, 'charge')), 'Оплата услуги');
    expect(creditLabel(_c('1', 4, 'refund')), 'Возврат');
    expect(creditLabel(_c('1', -5, 'adjust')), 'Списание');
  });

  testWidgets('журнал кредитов: суммы, причина и фильтр', (tester) async {
    final items = CreditEntry.withBalances(
      [
        _c('3', -5, 'adjust', note: 'ошибка начисления'),
        _c(
          '2',
          -4,
          'charge',
        ).copyWith(vin: 'LS5A3ABC1NA000123', service: 'Русификация'),
        _c('1', 100, 'topup', note: 'оплата наличными'),
      ],
      {'m1': 91},
    );
    await _pump(
      tester,
      CreditList(
        value: AsyncData(items),
        onRefresh: () async {},
        showMaster: true,
        empty: 'пусто',
      ),
    );
    expect(find.text('Пришло: +100 кр.'), findsOneWidget);
    expect(find.text('Ушло: −9 кр.'), findsOneWidget);
    expect(find.text('Причина: ошибка начисления'), findsOneWidget);
    expect(find.text('Русификация · VIN LS5A3ABC1NA000123'), findsOneWidget);
    expect(find.text('баланс 91'), findsOneWidget);
    expect(find.text('баланс 100'), findsOneWidget);

    await tester.tap(find.text('Пополнения'));
    await tester.pump();
    expect(find.text('Операций: 1'), findsOneWidget);
    expect(find.text('+100 кр.'), findsOneWidget);
  });

  test('работы группируются по VIN', () {
    final cars = groupByCar([
      _h('3', 'VIN-A', '2026-10-15T10:00:00Z'),
      _h('2', 'VIN-B', '2026-10-14T10:00:00Z'),
      _h('1', 'VIN-A', '2026-10-13T10:00:00Z'),
    ]);
    expect(cars.length, 2);
    expect(cars.first.length, 2);
    expect(cars.first.first.vin, 'VIN-A');
  });

  testWidgets('история по машинам: одна карточка на VIN', (tester) async {
    await _pump(
      tester,
      HistoryList(
        value: AsyncData([
          _h('2', 'VIN-A', '2026-10-15T10:00:00Z', service: 'Установка APK'),
          _h('1', 'VIN-A', '2026-10-13T10:00:00Z'),
        ]),
        onRefresh: () async {},
        showMaster: true,
        empty: 'пусто',
      ),
    );
    await tester.tap(find.byKey(const Key('view-cars')));
    await tester.pump();
    expect(find.text('VIN VIN-A'), findsOneWidget);
    expect(find.text('работ: 2'), findsOneWidget);
    expect(find.textContaining('Первая: 13 окт 2026'), findsOneWidget);
  });
}
