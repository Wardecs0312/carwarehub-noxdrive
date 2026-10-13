import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../history/history_repository.dart';
import '../history/history_screen.dart';
import '../stream/stream_viewer_screen.dart';
import 'admin_repository.dart';

/// Админ-панель: мастера и баланс, заявки на возврат, трансляции.
/// Вёрстка одна для телефона (PWA/APK), ноутбука и ГУ: вкладки и списки без фиксированной ширины.
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 4,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Админ-панель'),
        actions: const [_TelegramSetupButton()],
        bottom: const TabBar(
          isScrollable: true,
          tabs: [
            Tab(icon: Icon(Icons.people_outline), text: 'Мастера'),
            Tab(icon: Icon(Icons.receipt_long), text: 'Журнал'),
            Tab(icon: Icon(Icons.undo), text: 'Возвраты'),
            Tab(icon: Icon(Icons.videocam_outlined), text: 'Трансляции'),
          ],
        ),
      ),
      body: const TabBarView(
        children: [_MastersTab(), _JournalTab(), _RefundsTab(), _StreamsTab()],
      ),
    ),
  );
}

/// Подключает Telegram-бота к функции входа (один раз после публикации telegram-auth).
class _TelegramSetupButton extends ConsumerWidget {
  const _TelegramSetupButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    tooltip: 'Подключить Telegram-бота',
    icon: const Icon(Icons.send),
    onPressed: () async {
      try {
        final msg = await ref.read(adminRepositoryProvider).setupTelegram();
        if (context.mounted) _toast(context, msg);
      } catch (e) {
        if (context.mounted) _toast(context, 'Не удалось: $e');
      }
    },
  );
}

/// Общая обёртка: загрузка, ошибка, пустой список, обновление жестом.
class _AsyncList<T> extends StatelessWidget {
  const _AsyncList({
    required this.value,
    required this.onRefresh,
    required this.empty,
    required this.itemBuilder,
  });

  final AsyncValue<List<T>> value;
  final Future<void> Function() onRefresh;
  final String empty;
  final Widget Function(T) itemBuilder;

  @override
  Widget build(BuildContext context) => value.when(
    loading: () => const Center(child: CircularProgressIndicator()),
    error: (e, _) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text('Ошибка загрузки: $e', textAlign: TextAlign.center),
      ),
    ),
    data: (items) => RefreshIndicator(
      onRefresh: onRefresh,
      child: items.isEmpty
          ? ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    empty,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: NoxColors.metalMid),
                  ),
                ),
              ],
            )
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) => itemBuilder(items[i]),
            ),
    ),
  );
}

void _toast(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

class _MastersTab extends ConsumerWidget {
  const _MastersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _AsyncList<MasterRow>(
    value: ref.watch(adminMastersProvider),
    onRefresh: () => ref.refresh(adminMastersProvider.future),
    empty: 'Мастеров пока нет',
    itemBuilder: (m) => Card(
      color: NoxColors.panelHi,
      child: ListTile(
        leading: Icon(
          Icons.person,
          color: switch (m.status) {
            'active' => NoxColors.ok,
            'pending' => NoxColors.warn,
            _ => NoxColors.bad,
          },
        ),
        title: Text(m.name),
        subtitle: Text(
          [
            if (m.phone != null) m.phone!,
            if (m.status == 'pending') 'ожидает одобрения',
            if (m.status == 'blocked') 'заблокирован',
          ].join(' · '),
        ),
        trailing: Wrap(
          spacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (m.status == 'pending')
              FilledButton(
                onPressed: () => _setStatus(context, ref, m, 'active'),
                child: const Text('Одобрить'),
              ),
            Text('${m.credits} кр.'),
            IconButton(
              tooltip: m.status == 'blocked'
                  ? 'Разблокировать'
                  : 'Заблокировать',
              icon: Icon(m.status == 'blocked' ? Icons.lock_open : Icons.block),
              onPressed: () => _setStatus(
                context,
                ref,
                m,
                m.status == 'blocked' ? 'active' : 'blocked',
              ),
            ),
            IconButton(
              tooltip: 'Пополнить баланс',
              icon: const Icon(Icons.add_card),
              onPressed: () => _topUp(context, ref, m),
            ),
            IconButton(
              tooltip: 'Запросить трансляцию',
              icon: const Icon(Icons.videocam),
              onPressed: () => _requestStream(context, ref, m),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _setStatus(
    BuildContext context,
    WidgetRef ref,
    MasterRow m,
    String status,
  ) async {
    try {
      await ref.read(adminRepositoryProvider).setMasterStatus(m.id, status);
      ref.invalidate(adminMastersProvider);
      if (context.mounted) {
        _toast(
          context,
          status == 'active'
              ? '${m.name}: доступ открыт'
              : '${m.name}: заблокирован',
        );
      }
    } catch (e) {
      if (context.mounted) _toast(context, 'Не удалось: $e');
    }
  }

  Future<void> _topUp(BuildContext context, WidgetRef ref, MasterRow m) async {
    final ctrl = TextEditingController();
    final amount = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Пополнить: ${m.name}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Кредиты'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text.trim())),
            child: const Text('Пополнить'),
          ),
        ],
      ),
    );
    if (amount == null || amount <= 0 || !context.mounted) return;
    try {
      await ref.read(adminRepositoryProvider).topUp(m.id, amount);
      ref.invalidate(adminMastersProvider);
      if (context.mounted) _toast(context, 'Начислено $amount кр.');
    } catch (e) {
      if (context.mounted) _toast(context, 'Не удалось: $e');
    }
  }

  Future<void> _requestStream(
    BuildContext context,
    WidgetRef ref,
    MasterRow m,
  ) async {
    final chosen = {...streamSources.keys};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Трансляция: ${m.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in streamSources.entries)
                CheckboxListTile(
                  value: chosen.contains(e.key),
                  title: Text(e.value),
                  onChanged: (v) => setState(
                    () => v == true ? chosen.add(e.key) : chosen.remove(e.key),
                  ),
                ),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Мастер увидит плашку «Идёт трансляция администратору».',
                  style: TextStyle(fontSize: 12, color: NoxColors.metalMid),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: chosen.isEmpty ? null : () => Navigator.pop(ctx, true),
              child: const Text('Запросить'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref
          .read(adminRepositoryProvider)
          .requestStream(m.id, chosen.toList());
      ref.invalidate(adminStreamsProvider);
      if (context.mounted) _toast(context, 'Запрос трансляции отправлен');
    } catch (e) {
      if (context.mounted) _toast(context, 'Не удалось: $e');
    }
  }
}

class _RefundsTab extends ConsumerWidget {
  const _RefundsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _AsyncList<RefundRow>(
    value: ref.watch(adminRefundsProvider),
    onRefresh: () => ref.refresh(adminRefundsProvider.future),
    empty: 'Новых заявок на возврат нет',
    itemBuilder: (r) => Card(
      color: NoxColors.panelHi,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${r.masterName} · ${r.service} · ${r.credits} кр.',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'VIN ${r.vin}',
              style: const TextStyle(color: NoxColors.metalMid),
            ),
            if (r.reason.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(r.reason),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () => _decide(context, ref, r, approve: true),
                  child: const Text('Вернуть кредиты'),
                ),
                OutlinedButton(
                  onPressed: () => _decide(context, ref, r, approve: false),
                  child: const Text('Отклонить'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _decide(
    BuildContext context,
    WidgetRef ref,
    RefundRow r, {
    required bool approve,
  }) async {
    try {
      await ref
          .read(adminRepositoryProvider)
          .decideRefund(r.id, approve: approve);
      ref.invalidate(adminRefundsProvider);
      ref.invalidate(adminMastersProvider);
      if (context.mounted) {
        _toast(context, approve ? 'Кредиты возвращены' : 'Заявка отклонена');
      }
    } catch (e) {
      if (context.mounted) _toast(context, 'Не удалось: $e');
    }
  }
}

class _StreamsTab extends ConsumerWidget {
  const _StreamsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _AsyncList<StreamSessionRow>(
        value: ref.watch(adminStreamsProvider),
        onRefresh: () => ref.refresh(adminStreamsProvider.future),
        empty: 'Активных трансляций нет. Запросить трансляцию можно на вкладке «Мастера».',
        itemBuilder: (s) => Card(
          color: NoxColors.panelHi,
          child: ListTile(
            leading: Icon(
              Icons.circle,
              size: 14,
              color: s.status == 'live' ? NoxColors.bad : NoxColors.warn,
            ),
            title: Text(s.masterName),
            subtitle: Text(
              '${s.status == 'live' ? 'В эфире' : 'Ожидает мастера'} · '
              '${s.sources.map((x) => streamSources[x] ?? x).join(', ')}',
            ),
            trailing: Wrap(
              spacing: 4,
              children: [
                IconButton(
                  tooltip: 'Смотреть',
                  icon: const Icon(Icons.play_circle_outline),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => StreamViewerScreen(
                        masterId: s.masterId,
                        masterName: s.masterName,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Завершить',
                  icon: const Icon(Icons.stop_circle_outlined),
                  onPressed: () async {
                    await ref.read(adminRepositoryProvider).endStream(s.id);
                    ref.invalidate(adminStreamsProvider);
                  },
                ),
              ],
            ),
          ),
        ),
      );
}

/// Журнал операций всех мастеров: кто, когда, какое авто, услуга, прошивка, статус.
class _JournalTab extends ConsumerWidget {
  const _JournalTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) => HistoryList(
    value: ref.watch(allHistoryProvider),
    onRefresh: () => ref.refresh(allHistoryProvider.future),
    showMaster: true,
    empty: 'Операций пока нет. Здесь появится каждая услуга, запущенная мастерами.',
  );
}
