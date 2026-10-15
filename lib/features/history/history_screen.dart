import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import 'credits_screen.dart';
import 'history_repository.dart';

const _months = [
  'янв',
  'фев',
  'мар',
  'апр',
  'мая',
  'июн',
  'июл',
  'авг',
  'сен',
  'окт',
  'ноя',
  'дек',
];

/// Дата и время по-русски: «13 окт 2026, 10:30».
String formatWhen(DateTime d) {
  final l = d.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.day} ${_months[l.month - 1]} ${l.year}, ${two(l.hour)}:${two(l.minute)}';
}

/// Статус операции: цвет и подпись.
(Color, String, IconData) _status(String s) => switch (s) {
  'success' => (NoxColors.ok, 'Выполнено', Icons.check_circle),
  'failed' => (NoxColors.bad, 'Ошибка', Icons.error),
  'running' => (NoxColors.warn, 'В процессе', Icons.timelapse),
  _ => (NoxColors.metalMid, s.isEmpty ? '—' : s, Icons.help_outline),
};

/// «Моя история»: машины, на которых работал мастер, и движение кредитов.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Моя история'),
        bottom: const TabBar(
          tabs: [
            Tab(icon: Icon(Icons.directions_car_outlined), text: 'Машины'),
            Tab(
              icon: Icon(Icons.account_balance_wallet_outlined),
              text: 'Кредиты',
            ),
          ],
        ),
      ),
      body: TabBarView(
        children: [
          HistoryList(
            value: ref.watch(myHistoryProvider),
            onRefresh: () => ref.refresh(myHistoryProvider.future),
            showMaster: false,
            empty: 'Здесь появятся ваши работы: какое авто, какая услуга и прошивка, когда и с каким результатом.',
          ),
          const MyCreditsTab(),
        ],
      ),
    ),
  );
}

/// Список операций с поиском. Используется в «Моей истории» и в журнале админ-панели.
class HistoryList extends StatefulWidget {
  const HistoryList({
    super.key,
    required this.value,
    required this.onRefresh,
    required this.showMaster,
    required this.empty,
  });

  final AsyncValue<List<HistoryEntry>> value;
  final Future<void> Function() onRefresh;
  final bool showMaster;
  final String empty;

  @override
  State<HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends State<HistoryList> {
  final _search = TextEditingController();
  String _status = 'all';

  /// Показывать по машинам: каждый VIN одной карточкой со всеми работами.
  bool _byCar = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _match(HistoryEntry e) {
    if (_status != 'all' && e.status != _status) return false;
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [
      e.vin,
      e.model,
      e.service,
      e.firmware,
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
          'Не удалось загрузить историю: $e',
          textAlign: TextAlign.center,
        ),
      ),
    ),
    data: (all) {
      final items = all.where(_match).toList();
      final ok = all.where((e) => e.status == 'success').length;
      final spent = all
          .where((e) => e.status == 'success')
          .fold<int>(0, (s, e) => s + e.credits);
      return RefreshIndicator(
        onRefresh: widget.onRefresh,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                Text('Всего: ${all.length}'),
                Text(
                  'Выполнено: $ok',
                  style: const TextStyle(color: NoxColors.ok),
                ),
                Text('Кредитов: $spent'),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('history-search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                labelText: widget.showMaster
                    ? 'Поиск: VIN, мастер, модель, услуга'
                    : 'Поиск: VIN, модель, услуга',
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final s in const [
                  ('all', 'Все'),
                  ('success', 'Выполнено'),
                  ('failed', 'Ошибка'),
                  ('running', 'В процессе'),
                ])
                  ChoiceChip(
                    label: Text(s.$2),
                    selected: _status == s.$1,
                    onSelected: (_) => setState(() => _status = s.$1),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  key: const Key('view-jobs'),
                  avatar: const Icon(Icons.list, size: 18),
                  label: const Text('Все работы'),
                  selected: !_byCar,
                  onSelected: (_) => setState(() => _byCar = false),
                ),
                ChoiceChip(
                  key: const Key('view-cars'),
                  avatar: const Icon(Icons.directions_car_outlined, size: 18),
                  label: const Text('По машинам'),
                  selected: _byCar,
                  onSelected: (_) => setState(() => _byCar = true),
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
            else if (_byCar)
              for (final car in groupByCar(items)) ...[
                _CarCard(car, showMaster: widget.showMaster),
                const SizedBox(height: 8),
              ]
            else
              for (final e in items) ...[
                _EntryCard(e, showMaster: widget.showMaster),
                const SizedBox(height: 8),
              ],
          ],
        ),
      );
    },
  );
}

class _EntryCard extends StatelessWidget {
  const _EntryCard(this.e, {required this.showMaster});
  final HistoryEntry e;
  final bool showMaster;

  @override
  Widget build(BuildContext context) {
    final (color, label, icon) = _status(e.status);
    final muted = const TextStyle(color: NoxColors.metalMid, fontSize: 13);
    return Card(
      color: NoxColors.panelHi,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    '${e.model} · ${e.service}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 4),
                Text(label, style: TextStyle(color: color, fontSize: 13)),
              ],
            ),
            const SizedBox(height: 6),
            Text(formatWhen(e.createdAt), style: muted),
            Text('VIN ${e.vin}', style: muted),
            Text('Прошивка ГУ: ${e.firmware}', style: muted),
            Text(
              [
                if (showMaster) 'Мастер: ${e.masterName}',
                '${e.credits} кр.',
                if (e.appVersion != null) 'программа ${e.appVersion}',
              ].join(' · '),
              style: muted,
            ),
          ],
        ),
      ),
    );
  }
}

/// Работы, сгруппированные по VIN; порядок — по последней работе, новые сверху.
List<List<HistoryEntry>> groupByCar(List<HistoryEntry> newestFirst) {
  final byVin = <String, List<HistoryEntry>>{};
  for (final e in newestFirst) {
    byVin.putIfAbsent(e.vin, () => []).add(e);
  }
  return byVin.values.toList();
}

class _CarCard extends StatelessWidget {
  const _CarCard(this.jobs, {required this.showMaster});

  /// Работы на одной машине, новые сверху.
  final List<HistoryEntry> jobs;
  final bool showMaster;

  @override
  Widget build(BuildContext context) {
    final last = jobs.first;
    final first = jobs.last;
    const muted = TextStyle(color: NoxColors.metalMid, fontSize: 13);
    return Card(
      color: NoxColors.panelHi,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.directions_car, color: NoxColors.metalLight),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'VIN ${last.vin}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text('работ: ${jobs.length}', style: muted),
              ],
            ),
            const SizedBox(height: 4),
            Text(last.model, style: muted),
            Text(
              jobs.length == 1
                  ? formatWhen(last.createdAt)
                  : 'Первая: ${formatWhen(first.createdAt)} · последняя: ${formatWhen(last.createdAt)}',
              style: muted,
            ),
            const Divider(height: 16),
            for (final j in jobs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      _status(j.status).$3,
                      size: 14,
                      color: _status(j.status).$1,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        [
                          formatWhen(j.createdAt),
                          j.service,
                          if (showMaster) j.masterName,
                          '${j.credits} кр.',
                        ].join(' · '),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
