import 'package:carwarehub_noxdrive/features/admin/admin_repository.dart';
import 'package:carwarehub_noxdrive/features/admin/admin_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRepo extends AdminRepository {
  final topUps = <(String, int)>[];
  final decisions = <(String, bool)>[];
  final streams = <(String, List<String>)>[];
  final statuses = <(String, String)>[];
  final renames = <(String, String)>[];
  final prices = <(String, String, int?)>[];

  @override
  Future<Map<String, int>> masterPrices(String masterId) async => const {};

  @override
  Future<void> setMasterPrice(
    String masterId,
    String group,
    int? credits,
  ) async => prices.add((masterId, group, credits));

  @override
  Future<void> renameMaster(String masterId, String name) async =>
      renames.add((masterId, name));

  @override
  Future<void> setMasterStatus(String masterId, String status) async =>
      statuses.add((masterId, status));

  @override
  Future<List<MasterRow>> masters() async => [
    MasterRow.fromJson({
      'id': 'm1',
      'name': 'Иван',
      'phone': '+7 900 000-00-00',
      'status': 'active',
      'master_balance': {'credits': 100},
    }),
    MasterRow.fromJson({
      'id': 'm2',
      'name': 'Пётр',
      'status': 'pending',
      'master_balance': <Object>[],
    }),
  ];

  @override
  Future<void> topUp(String masterId, int amount) async =>
      topUps.add((masterId, amount));

  final adjusts = <(String, int, String)>[];

  @override
  Future<int> adjustCredits(String masterId, int amount, String reason) async {
    adjusts.add((masterId, amount, reason));
    return 100 + amount;
  }

  @override
  Future<List<RefundRow>> pendingRefunds() async => [
    RefundRow.fromJson({
      'id': 'r1',
      'reason': 'Не установилось',
      'created_at': '2026-10-12T20:00:00Z',
      'masters': {'name': 'Иван'},
      'activations': {
        'vin': 'LS5A3ABC1NA000000',
        'credits': 10,
        'services': {'title': 'Русификация'},
      },
    }),
  ];

  @override
  Future<void> decideRefund(String id, {required bool approve}) async =>
      decisions.add((id, approve));

  @override
  Future<List<StreamSessionRow>> streamSessions() async => const [];

  @override
  Future<void> requestStream(String masterId, List<String> sources) async =>
      streams.add((masterId, sources));
}

Future<_FakeRepo> _pump(WidgetTester tester) async {
  // Ширина телефона: панель должна помещаться без переполнения.
  tester.view.physicalSize = const Size(375, 812);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repo = _FakeRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [adminRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(home: AdminScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  Future<void> credits(
    WidgetTester tester,
    String amount,
    String reason,
    String button,
  ) async {
    await tester.tap(find.byKey(const Key('credits-m1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('credits-amount')), amount);
    await tester.enterText(find.byKey(const Key('credits-reason')), reason);
    await tester.tap(find.byKey(Key(button)));
    await tester.pumpAndSettle();
  }

  testWidgets('кредиты: начисление с причиной', (tester) async {
    final repo = await _pump(tester);
    expect(find.textContaining('Иван', findRichText: true), findsOneWidget);
    expect(find.text('100 кр.'), findsOneWidget);
    await credits(tester, '50', 'оплата наличными', 'credits-plus');
    expect(repo.adjusts, [('m1', 50, 'оплата наличными')]);
    expect(
      find.textContaining('Начислено 50 кр. Баланс: 150 кр.'),
      findsOneWidget,
    );
  });

  testWidgets('кредиты: списание с причиной', (tester) async {
    final repo = await _pump(tester);
    await credits(tester, '30', 'ошибочное начисление', 'credits-minus');
    expect(repo.adjusts, [('m1', -30, 'ошибочное начисление')]);
  });

  testWidgets('кредиты: не число ничего не меняет', (tester) async {
    final repo = await _pump(tester);
    await credits(tester, 'abc', 'тест', 'credits-plus');
    expect(repo.adjusts, isEmpty);
  });

  testWidgets('запрос трансляции: все источники по умолчанию', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.byTooltip('Запросить трансляцию').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Мастер увидит плашку'), findsOneWidget);
    await tester.tap(find.text('Запросить'));
    await tester.pumpAndSettle();
    expect(repo.streams.single.$1, 'm1');
    expect(repo.streams.single.$2.toSet(), streamSources.keys.toSet());
  });

  testWidgets('возврат: одобрение', (tester) async {
    final repo = await _pump(tester);
    await tester.ensureVisible(find.text('Возвраты'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Возвраты'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Русификация'), findsOneWidget);
    await tester.tap(find.text('Вернуть кредиты'));
    await tester.pumpAndSettle();
    expect(repo.decisions, [('r1', true)]);
  });

  testWidgets('новый мастер: одобрение', (tester) async {
    final repo = await _pump(tester);
    expect(find.textContaining('ожидает одобрения'), findsOneWidget);
    await tester.tap(find.text('Одобрить'));
    await tester.pumpAndSettle();
    expect(repo.statuses, [('m2', 'active')]);
  });

  testWidgets('переименование мастера: нажатие на имя, новое имя сохраняется', (
    tester,
  ) async {
    final repo = await _pump(tester);
    await tester.tap(find.byKey(const Key('rename-m1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rename-field')), '  Админ  ');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(repo.renames, [('m1', 'Админ')]);
  });

  testWidgets('специальная цена мастеру: только изменённая строка прайса', (
    tester,
  ) async {
    final repo = await _pump(tester);
    await tester.tap(find.byKey(const Key('rename-m1')));
    await tester.pumpAndSettle();
    expect(find.text('Специальные цены'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('price-complex')), '2');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(repo.prices, [('m1', 'complex', 2)]);
    expect(repo.renames, isEmpty);
  });

  testWidgets('цена не числом: понятная ошибка, ничего не сохраняется', (
    tester,
  ) async {
    final repo = await _pump(tester);
    await tester.tap(find.byKey(const Key('rename-m1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('price-cluster')), 'abc');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.textContaining('целое число'), findsOneWidget);
    expect(repo.prices, isEmpty);
  });
}
