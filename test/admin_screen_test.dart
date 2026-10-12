import 'package:carwarehub_noxdrive/features/admin/admin_repository.dart';
import 'package:carwarehub_noxdrive/features/admin/admin_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRepo extends AdminRepository {
  final topUps = <(String, int)>[];
  final decisions = <(String, bool)>[];
  final streams = <(String, List<String>)>[];

  @override
  Future<List<MasterRow>> masters() async => [
    MasterRow.fromJson({
      'id': 'm1',
      'name': 'Иван',
      'phone': '+7 900 000-00-00',
      'status': 'active',
      'master_balance': {'credits': 100},
    }),
  ];

  @override
  Future<void> topUp(String masterId, int amount) async =>
      topUps.add((masterId, amount));

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
  testWidgets('мастера с балансом, пополнение', (tester) async {
    final repo = await _pump(tester);
    expect(find.text('Иван'), findsOneWidget);
    expect(find.text('100 кр.'), findsOneWidget);

    await tester.tap(find.byTooltip('Пополнить баланс'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '50');
    await tester.tap(find.text('Пополнить'));
    await tester.pumpAndSettle();
    expect(repo.topUps, [('m1', 50)]);
  });

  testWidgets('запрос трансляции: все источники по умолчанию', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.byTooltip('Запросить трансляцию'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Мастер увидит плашку'), findsOneWidget);
    await tester.tap(find.text('Запросить'));
    await tester.pumpAndSettle();
    expect(repo.streams.single.$1, 'm1');
    expect(repo.streams.single.$2.toSet(), streamSources.keys.toSet());
  });

  testWidgets('возврат: одобрение', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.text('Возвраты'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Русификация'), findsOneWidget);
    await tester.tap(find.text('Вернуть кредиты'));
    await tester.pumpAndSettle();
    expect(repo.decisions, [('r1', true)]);
  });
}
