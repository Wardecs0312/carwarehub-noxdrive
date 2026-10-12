import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/auth_repository.dart';

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
                      ? 'Администратор проверит её и откроет доступ. После одобрения нажмите «Проверить».'
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
                    if (pending)
                      FilledButton(
                        onPressed: () => ref.invalidate(masterStatusProvider),
                        child: const Text('Проверить'),
                      ),
                    OutlinedButton(
                      onPressed: signOut,
                      child: const Text('Выйти'),
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
