import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/env.dart';
import '../../app/theme.dart';
import '../../data/auth_repository.dart';
import 'adb_status_badge.dart';
import 'metal_text.dart';

const kSupportTelegram = '@wiqqq99';

class NoxHeader extends ConsumerWidget {
  const NoxHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balance = ref.watch(balanceProvider).value;
    return Container(
      decoration: const BoxDecoration(
        color: NoxColors.panel,
        border: Border(bottom: BorderSide(color: NoxColors.border)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Row(
              children: [
                Image.asset(
                  'assets/brand/nox_mono.png',
                  height: 44,
                  filterQuality: FilterQuality.medium,
                ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const MetalText(
                      'nox.drive',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                    Text(
                      'AUTOMOTIVE TECHNOLOGY',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 5,
                        color: NoxColors.metalMid.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                const AdbStatusBadge(),
                if (balance != null) ...[
                  const SizedBox(width: 16),
                  Text(
                    'Баланс: $balance кр.',
                    style: const TextStyle(color: NoxColors.metalLight),
                  ),
                ],
                if (Env.hasSupabase)
                  IconButton(
                    tooltip: 'Выйти',
                    icon: const Icon(Icons.logout, color: NoxColors.metalMid),
                    onPressed: signOut,
                  ),
              ],
            ),
          ),
          const _SupportStrip(),
        ],
      ),
    );
  }
}

class _SupportStrip extends StatelessWidget {
  const _SupportStrip();

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () =>
        launchUrl(Uri.parse('https://t.me/${kSupportTelegram.substring(1)}')),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 7),
      color: NoxColors.bg,
      alignment: Alignment.center,
      child: const Text(
        'ДЛЯ АДБ ДОСТУПА ПИСАТЬ В ТГ $kSupportTelegram',
        style: TextStyle(
          fontSize: 12,
          letterSpacing: 2,
          color: NoxColors.metalMid,
        ),
      ),
    ),
  );
}
