import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/auth_repository.dart';
import '../admin/admin_repository.dart';

/// Мастер зарегистрировался, но ещё не одобрен администратором (или заблокирован).
class AccountStatusScreen extends ConsumerWidget {
  const AccountStatusScreen({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = status == 'pending';
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  pending ? Icons.hourglass_top : Icons.block,
                  size: 56,
                  color: pending ? NoxColors.warn : NoxColors.bad,
                ),
                const SizedBox(height: 16),
                Text(
                  pending
                      ? 'Заявка на регистрацию отправлена'
                      : 'Аккаунт заблокирован',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  pending
                      ? 'Администратор проверит её и откроет доступ. После одобрения программа откроется сама.'
                      : 'Обратитесь к администратору.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: NoxColors.metalMid),
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (pending) const _ApprovalWatcher(),
                    if (pending)
                      FilledButton(
                        onPressed: () => ref
                          ..invalidate(masterStatusProvider)
                          ..invalidate(isAdminProvider),
                        child: const Text('Проверить'),
                      ),
                    // «Назад» ведёт на экран входа (выход из аккаунта).
                    OutlinedButton.icon(
                      onPressed: signOut,
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: const Text('Назад ко входу'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Пока мастер ждёт одобрения, статус перепроверяется каждые [approvalPollInterval]: одобрили —
/// программа открывается сама, без кнопки «Проверить» и перезапуска.
class _ApprovalWatcher extends ConsumerStatefulWidget {
  const _ApprovalWatcher();

  @override
  ConsumerState<_ApprovalWatcher> createState() => _ApprovalWatcherState();
}

/// Как часто экран ожидания спрашивает сервер, одобрен ли мастер.
const approvalPollInterval = Duration(seconds: 10);

class _ApprovalWatcherState extends ConsumerState<_ApprovalWatcher> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(approvalPollInterval, (_) {
      if (!mounted) return;
      ref
        ..invalidate(masterStatusProvider)
        ..invalidate(isAdminProvider);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
