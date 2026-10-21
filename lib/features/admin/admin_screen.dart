import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/theme.dart';
import '../../data/auth_repository.dart';
import '../../data/catalog_repository.dart';
import '../../data/models.dart';
import '../history/credits_repository.dart';
import '../presence/presence_models.dart';
import '../history/credits_screen.dart';
import '../history/history_repository.dart';
import '../history/history_screen.dart';
import '../stream/stream_clock.dart';
import '../stream/stream_viewer_screen.dart';
import 'admin_repository.dart';

/// Админ-панель: мастера и баланс, заявки на возврат, трансляции.
/// Вёрстка одна для телефона (PWA/APK), ноутбука и ГУ: вкладки и списки без фиксированной ширины.
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key, this.standalone = false});

  /// Сайт админки: своя кнопка «Выйти» и нет кнопки «назад».
  final bool standalone;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 5,
    child: Scaffold(
      appBar: AppBar(
        title: Text(standalone ? 'nox.drive · Админ' : 'Админ-панель'),
        automaticallyImplyLeading: !standalone,
        actions: [
          const _SitePasswordButton(),
          const _TelegramSetupButton(),
          if (standalone)
            IconButton(
              key: const Key('admin-logout'),
              tooltip: 'Выйти',
              icon: const Icon(Icons.logout),
              onPressed: () => _confirmLogout(context),
            ),
        ],
        bottom: const TabBar(
          isScrollable: true,
          tabs: [
            Tab(icon: Icon(Icons.people_outline), text: 'Мастера'),
            Tab(icon: Icon(Icons.receipt_long), text: 'Журнал'),
            Tab(
              icon: Icon(Icons.account_balance_wallet_outlined),
              text: 'Кредиты',
            ),
            Tab(icon: Icon(Icons.undo), text: 'Возвраты'),
            Tab(icon: Icon(Icons.videocam_outlined), text: 'Трансляции'),
          ],
        ),
      ),
      body: const TabBarView(
        children: [
          _MastersTab(),
          _JournalTab(),
          _CreditsTab(),
          _RefundsTab(),
          _StreamsTab(),
        ],
      ),
    ),
  );
}

Future<void> _confirmLogout(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Выйти из админ-панели?'),
      content: const Text('Чтобы войти снова, понадобятся логин и пароль.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('admin-logout-confirm'),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Выйти'),
        ),
      ],
    ),
  );
  if (ok == true) await signOut();
}

/// Логин для сайта админки: Telegram ID для входа через Telegram, иначе почта.
String siteLoginFor(String? email) {
  final m = RegExp(r'^tg-(\d+)@telegram\.nox\.drive$').firstMatch(email ?? '');
  return m != null ? m.group(1)! : (email ?? '');
}

/// Чем плох пароль для сайта админки (null — подходит). Логин админа (Telegram ID) знают многие,
/// поэтому защищает только пароль: не короче 12 символов, буквы и цифры.
String? sitePasswordProblem(String p) {
  if (p.length < 12) return 'Пароль: не меньше 12 символов';
  if (!RegExp(r'[A-Za-zА-Яа-яЁё]').hasMatch(p) || !RegExp(r'\d').hasMatch(p)) {
    return 'В пароле нужны и буквы, и цифры';
  }
  if (RegExp(r'^(.)\1+$').hasMatch(p)) return 'Пароль слишком простой';
  return null;
}

/// «Пароль для сайта»: админ сам задаёт пароль для входа в веб-админку.
class _SitePasswordButton extends StatelessWidget {
  const _SitePasswordButton();

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('site-password'),
    tooltip: 'Пароль для сайта админки',
    icon: const Icon(Icons.key),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (_) => const _SitePasswordDialog(),
    ),
  );
}

class _SitePasswordDialog extends StatefulWidget {
  const _SitePasswordDialog();

  @override
  State<_SitePasswordDialog> createState() => _SitePasswordDialogState();
}

class _SitePasswordDialogState extends State<_SitePasswordDialog> {
  final _p1 = TextEditingController();
  final _p2 = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _p1.dispose();
    _p2.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final p = _p1.text;
    final problem = sitePasswordProblem(p);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    if (p != _p2.text) {
      setState(() => _error = 'Пароли не совпадают');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: p),
      );
      if (!mounted) return;
      Navigator.pop(context);
      _toast(context, 'Пароль для сайта сохранён');
    } catch (e) {
      setState(() => _error = 'Не удалось сохранить: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final login = siteLoginFor(
      Supabase.instance.client.auth.currentUser?.email,
    );
    return AlertDialog(
      title: const Text('Пароль для сайта админки'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Логин для входа на сайт:'),
            SelectableText(
              login,
              key: const Key('site-login'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('site-pass-1'),
              controller: _p1,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Новый пароль'),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('site-pass-2'),
              controller: _p2,
              obscureText: true,
              onSubmitted: (_) => _save(),
              decoration: const InputDecoration(labelText: 'Повторите пароль'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: NoxColors.bad)),
            ],
            const SizedBox(height: 8),
            const Text(
              'Вход в программу через Telegram не меняется.',
              style: TextStyle(color: NoxColors.metalMid, fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('site-pass-save'),
          onPressed: _busy ? null : _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
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

/// Настройки мастера: имя и специальные цены по строкам прайса.
/// Пустое поле цены — обычная цена для всех.
class _MasterSettingsDialog extends ConsumerStatefulWidget {
  const _MasterSettingsDialog({required this.master});
  final MasterRow master;

  @override
  ConsumerState<_MasterSettingsDialog> createState() =>
      _MasterSettingsDialogState();
}

class _MasterSettingsDialogState extends ConsumerState<_MasterSettingsDialog> {
  late final _name = TextEditingController(text: widget.master.name);
  final _prices = <String, TextEditingController>{};
  Map<String, int> _initial = const {};
  List<PriceGroup> _groups = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final groups = await ref.read(priceGroupsProvider.future);
      final special = await ref
          .read(adminRepositoryProvider)
          .masterPrices(widget.master.id);
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _initial = special;
        for (final g in groups) {
          _prices[g.code] = TextEditingController(
            text: special[g.code]?.toString() ?? '',
          );
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e'.contains('master_prices')
              ? 'Специальные цены появятся после SQL update_0011.sql в Supabase'
              : 'Цены не загрузились: $e';
        });
      }
    }
  }

  Future<void> _save() async {
    final repo = ref.read(adminRepositoryProvider);
    final name = _name.text.trim();
    // Сначала проверяем все поля, чтобы не сохранить половину.
    final changes = <String, int?>{};
    for (final g in _groups) {
      final raw = _prices[g.code]!.text.trim();
      final v = raw.isEmpty ? null : int.tryParse(raw);
      if (raw.isNotEmpty && (v == null || v < 0)) {
        setState(() => _error = '«${g.title}»: цена — целое число кредитов');
        return;
      }
      if (v != _initial[g.code]) changes[g.code] = v;
    }
    if (name.isEmpty) {
      setState(() => _error = 'Имя не может быть пустым');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (name != widget.master.name) {
        await repo.renameMaster(widget.master.id, name);
      }
      for (final e in changes.entries) {
        await repo.setMasterPrice(widget.master.id, e.key, e.value);
      }
      if (mounted) Navigator.pop(context, 'Сохранено: $name');
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e'.contains('admin_set_master')
              ? 'Сначала выполните в Supabase SQL update_0010.sql и update_0011.sql'
              : 'Не удалось: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    for (final c in _prices.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Мастер'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('rename-field'),
              controller: _name,
              autofocus: true,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'Имя (ник)'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Специальные цены',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const Text(
              'Пустое поле — обычная цена.',
              style: TextStyle(fontSize: 12, color: NoxColors.metalMid),
            ),
            const SizedBox(height: 8),
            if (_loading)
              const LinearProgressIndicator()
            else
              for (final g in _groups)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    key: Key('price-${g.code}'),
                    controller: _prices[g.code],
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: g.title,
                      hintText: 'обычно ${g.priceCredits} кр.',
                      suffixText: 'кр.',
                    ),
                  ),
                ),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: NoxColors.bad)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: _saving || _loading ? null : _save,
        child: const Text('Сохранить'),
      ),
    ],
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
  Widget build(BuildContext context, WidgetRef ref) {
    final presence = ref.watch(presenceMapProvider).value ?? const {};
    final now = ref.watch(presenceClockProvider).value ?? DateTime.now();
    return _AsyncList<MasterRow>(
      value: ref.watch(adminMastersProvider),
      onRefresh: () => ref.refresh(adminMastersProvider.future),
      empty: 'Мастеров пока нет',
      // Карточка в две строки: на телефоне имя не сжимается кнопками.
      itemBuilder: (m) => Card(
        color: NoxColors.panelHi,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _PresenceAvatar(
                    status: m.status,
                    online: presence[m.id]?.isOnline(now) ?? false,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: InkWell(
                      key: Key('rename-${m.id}'),
                      onTap: () => _rename(context, ref, m),
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${m.name} ',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Icon(
                                Icons.edit,
                                size: 14,
                                color: NoxColors.metalMid,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      '${m.credits} кр.',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 42, top: 2, right: 8),
                child: Text(
                  [
                    presenceText(presence[m.id], now),
                    ?presence[m.id]?.place,
                    if (presence[m.id]?.appVersion case final v?) 'версия $v',
                    if (m.phone != null) m.phone!,
                    if (m.status == 'pending') 'ожидает одобрения',
                    if (m.status == 'blocked') 'заблокирован',
                  ].join(' · '),
                  style: TextStyle(
                    fontSize: 13,
                    color: (presence[m.id]?.isOnline(now) ?? false)
                        ? NoxColors.ok
                        : NoxColors.metalMid,
                  ),
                ),
              ),
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (m.status == 'pending')
                    FilledButton(
                      onPressed: () => _setStatus(context, ref, m, 'active'),
                      child: const Text('Одобрить'),
                    ),
                  IconButton(
                    tooltip: m.status == 'blocked'
                        ? 'Разблокировать'
                        : 'Заблокировать',
                    icon: Icon(
                      m.status == 'blocked' ? Icons.lock_open : Icons.block,
                    ),
                    onPressed: () => _setStatus(
                      context,
                      ref,
                      m,
                      m.status == 'blocked' ? 'active' : 'blocked',
                    ),
                  ),
                  IconButton(
                    key: Key('credits-${m.id}'),
                    tooltip: 'Кредиты: начислить или списать',
                    icon: const Icon(Icons.add_card),
                    onPressed: () => _adjustCredits(context, ref, m),
                  ),
                  IconButton(
                    key: Key('logins-${m.id}'),
                    tooltip: 'История входов',
                    icon: const Icon(Icons.travel_explore),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => _LoginHistoryDialog(master: m),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Запросить трансляцию',
                    icon: const Icon(Icons.videocam),
                    onPressed: () => _requestStream(context, ref, m),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Окно мастера: имя (ник) и специальные цены.
  Future<void> _rename(BuildContext context, WidgetRef ref, MasterRow m) async {
    final saved = await showDialog<String>(
      context: context,
      builder: (_) => _MasterSettingsDialog(master: m),
    );
    if (saved != null && context.mounted) {
      ref.invalidate(adminMastersProvider);
      _toast(context, saved);
    }
  }

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

  /// Начислить или списать кредиты мастеру. Причина обязательна и попадает в журнал.
  Future<void> _adjustCredits(
    BuildContext context,
    WidgetRef ref,
    MasterRow m,
  ) async {
    final amountCtrl = TextEditingController();
    final reasonCtrl = TextEditingController();
    final signed = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Кредиты: ${m.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Сейчас на балансе: ${m.credits} кр.'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('credits-amount'),
              controller: amountCtrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Сколько кредитов'),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('credits-reason'),
              controller: reasonCtrl,
              decoration: const InputDecoration(
                labelText: 'Причина (видна в журнале)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          OutlinedButton(
            key: const Key('credits-minus'),
            onPressed: () {
              final n = int.tryParse(amountCtrl.text.trim());
              Navigator.pop(ctx, n == null || n <= 0 ? null : -n);
            },
            child: const Text('Списать'),
          ),
          FilledButton(
            key: const Key('credits-plus'),
            onPressed: () {
              final n = int.tryParse(amountCtrl.text.trim());
              Navigator.pop(ctx, n == null || n <= 0 ? null : n);
            },
            child: const Text('Начислить'),
          ),
        ],
      ),
    );
    if (signed == null || !context.mounted) return;
    try {
      final now = await ref
          .read(adminRepositoryProvider)
          .adjustCredits(m.id, signed, reasonCtrl.text);
      ref.invalidate(adminMastersProvider);
      ref.invalidate(allCreditsProvider);
      if (context.mounted) {
        _toast(
          context,
          '${signed > 0 ? 'Начислено' : 'Списано'} ${signed.abs()} кр. Баланс: $now кр.',
        );
      }
    } catch (e) {
      if (context.mounted) {
        _toast(context, e.toString().replaceFirst('Exception: ', ''));
      }
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
  Widget build(
    BuildContext context,
    WidgetRef ref,
  ) => _AsyncList<StreamSessionRow>(
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
          '${s.status == 'live' ? (s.startedAt != null ? 'В эфире ${streamClockText(s.startedAt!, DateTime.now())}' : 'В эфире') : 'Ожидает мастера'} · '
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
                    sessionId: s.id,
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

/// Движение кредитов всех мастеров: пополнения, оплата услуг, списания и возвраты.
class _CreditsTab extends ConsumerWidget {
  const _CreditsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) => CreditList(
    value: ref.watch(allCreditsProvider),
    onRefresh: () => ref.refresh(allCreditsProvider.future),
    showMaster: true,
    empty: 'Операций с кредитами пока нет.',
  );
}

/// Значок мастера: цвет — статус доступа, зелёная точка — сейчас в программе.
class _PresenceAvatar extends StatelessWidget {
  const _PresenceAvatar({required this.status, required this.online});
  final String status;
  final bool online;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 32,
    height: 32,
    child: Stack(
      children: [
        Icon(
          Icons.person,
          size: 28,
          color: switch (status) {
            'active' => NoxColors.metalLight,
            'pending' => NoxColors.warn,
            _ => NoxColors.bad,
          },
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            key: Key(online ? 'online-dot' : 'offline-dot'),
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: online ? NoxColors.ok : NoxColors.metalDark,
              border: Border.all(color: NoxColors.panelHi, width: 2),
            ),
          ),
        ),
      ],
    ),
  );
}

/// История входов мастера: когда, откуда (страна, город, IP), с какого компьютера и версии.
class _LoginHistoryDialog extends ConsumerWidget {
  const _LoginHistoryDialog({required this.master});
  final MasterRow master;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(loginEventsProvider(master.id));
    const muted = TextStyle(color: NoxColors.metalMid, fontSize: 13);
    return AlertDialog(
      title: Text('Входы: ${master.name}'),
      content: SizedBox(
        width: 520,
        child: events.when(
          loading: () => const SizedBox(
            height: 80,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text('Не удалось загрузить: $e'),
          data: (list) => list.isEmpty
              ? const Text(
                  'Входов пока нет. История появится, когда мастер откроет программу версии 2.0.21 или новее.',
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 12),
                  itemBuilder: (_, i) {
                    final e = list[i];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          formatWhen(e.createdAt),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          [
                            placeText(e.country, e.city) ??
                                'страна не определилась',
                            if (e.ip != null) 'IP ${e.ip}',
                          ].join(' · '),
                          style: muted,
                        ),
                        Text(
                          [
                            if (e.device != null) e.device!,
                            if (e.platform != null) e.platform!,
                            if (e.appVersion != null) 'версия ${e.appVersion}',
                          ].join(' · '),
                          style: muted,
                        ),
                      ],
                    );
                  },
                ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}
