import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import 'credits_repository.dart';
import 'history_screen.dart';

/// Подпись операции с кредитами.
String creditLabel(CreditEntry e) => switch (e.reason) {
  'topup' => 'Пополнение',
  'charge' => 'Оплата услуги',
  'refund' => 'Возврат',
  'adjust' => e.amount < 0 ? 'Списание' : 'Корректировка',
  _ => e.reason.isEmpty ? 'Операция' : e.reason,
};

/// Группа фильтра: пополнения и начисления админом вместе, списания админом вместе с оплатами.
String _group(CreditEntry e) => switch (e.reason) {
  'charge' => 'charge',
  'refund' => 'refund',
  _ => e.amount >= 0 ? 'topup' : 'minus',
};

/// Журнал кредитов с поиском и фильтром. Используется у мастера и в админ-панели.
class CreditList extends StatefulWidget {
  const CreditList({
    super.key,
    required this.value,
    required this.onRefresh,
    required this.showMaster,
    required this.empty,
  });

  final AsyncValue<List<CreditEntry>> value;
  final Future<void> Function() onRefresh;
  final bool showMaster;
  final String empty;

  @override
  State<CreditList> createState() => _CreditListState();
}

class _CreditListState extends State<CreditList> {
  final _search = TextEditingController();
  String _filter = 'all';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _match(CreditEntry e) {
    if (_filter != 'all' && _group(e) != _filter) return false;
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [
      e.vin ?? '',
      e.service ?? '',
      e.note ?? '',
      creditLabel(e),
      if (widget.showMaster) e.masterName,
    ].any((s) => s.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) => widget.value.when(
    loading: () => const Center(child: CircularProgressIndicator()),
    error: (e, _) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Не удалось загрузить кредиты: $e',
          textAlign: TextAlign.center,
        ),
      ),
    ),
    data: (all) {
      final items = all.where(_match).toList();
      final plus = items
          .where((e) => e.amount > 0)
          .fold<int>(0, (s, e) => s + e.amount);
      final minus = items
          .where((e) => e.amount < 0)
          .fold<int>(0, (s, e) => s - e.amount);
      return RefreshIndicator(
        onRefresh: widget.onRefresh,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                Text('Операций: ${items.length}'),
                Text(
                  'Пришло: +$plus кр.',
                  style: const TextStyle(color: NoxColors.ok),
                ),
                Text(
                  'Ушло: −$minus кр.',
                  style: const TextStyle(color: NoxColors.bad),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('credits-search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                labelText: widget.showMaster
                    ? 'Поиск: мастер, VIN, причина'
                    : 'Поиск: VIN, услуга, причина',
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final s in const [
                  ('all', 'Все'),
                  ('topup', 'Пополнения'),
                  ('charge', 'Оплата услуг'),
                  ('minus', 'Списания'),
                  ('refund', 'Возвраты'),
                ])
                  ChoiceChip(
                    label: Text(s.$2),
                    selected: _filter == s.$1,
                    onSelected: (_) => setState(() => _filter = s.$1),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (all.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  widget.empty,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: NoxColors.metalMid),
                ),
              )
            else if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Ничего не найдено',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: NoxColors.metalMid),
                ),
              )
            else
              for (final e in items) ...[
                _CreditCard(e, showMaster: widget.showMaster),
                const SizedBox(height: 8),
              ],
          ],
        ),
      );
    },
  );
}

class _CreditCard extends StatelessWidget {
  const _CreditCard(this.e, {required this.showMaster});
  final CreditEntry e;
  final bool showMaster;

  @override
  Widget build(BuildContext context) {
    final up = e.amount >= 0;
    final color = up ? NoxColors.ok : NoxColors.bad;
    const muted = TextStyle(color: NoxColors.metalMid, fontSize: 13);
    return Card(
      color: NoxColors.panelHi,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              up ? Icons.add_circle_outline : Icons.remove_circle_outline,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    creditLabel(e),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(formatWhen(e.createdAt), style: muted),
                  if (showMaster) Text('Мастер: ${e.masterName}', style: muted),
                  if (e.vin != null)
                    Text(
                      '${e.service ?? 'Услуга'} · VIN ${e.vin}',
                      style: muted,
                    ),
                  if (e.note != null) Text('Причина: ${e.note}', style: muted),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${up ? '+' : '−'}${e.amount.abs()} кр.',
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                if (e.balanceAfter != null)
                  Text('баланс ${e.balanceAfter}', style: muted),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Вкладка «Кредиты» в «Моей истории».
class MyCreditsTab extends ConsumerWidget {
  const MyCreditsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => CreditList(
    value: ref.watch(myCreditsProvider),
    onRefresh: () => ref.refresh(myCreditsProvider.future),
    showMaster: false,
    empty: 'Здесь появятся пополнения и списания кредитов.',
  );
}
