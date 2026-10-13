import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/env.dart';
import '../../app/theme.dart';
import '../../data/auth_repository.dart';
import '../admin/admin_repository.dart';
import '../admin/admin_screen.dart';
import '../history/history_screen.dart';
import 'adb_status_badge.dart';
import 'metal_text.dart';

const kSupportTelegram = '@wiqqq99';
const kInstagram = '@nox.drive.kg';

class NoxHeader extends ConsumerWidget {
  const NoxHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balance = ref.watch(balanceProvider).value;
    final isAdmin = ref.watch(isAdminProvider).value ?? false;
    return Container(
      decoration: const BoxDecoration(
        color: NoxColors.panel,
        border: Border(bottom: BorderSide(color: NoxColors.border)),
      ),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, c) {
              // На телефоне (PWA) статус и баланс уходят во вторую строку.
              final narrow = c.maxWidth < kNarrowWidth;
              final status = Wrap(
                spacing: 16,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const AdbStatusBadge(),
                  // Администратор видит свою роль, а не баланс мастера (у админа он обычно 0).
                  if (isAdmin)
                    const Text(
                      'Администратор',
                      style: TextStyle(
                        color: NoxColors.ok,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  else if (balance != null)
                    Text(
                      'Баланс: $balance кр.',
                      style: const TextStyle(color: NoxColors.metalLight),
                    ),
                ],
              );
              final history = Env.hasSupabase
                  ? IconButton(
                      tooltip: 'Моя история',
                      icon: const Icon(
                        Icons.history,
                        color: NoxColors.metalMid,
                      ),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const HistoryScreen(),
                        ),
                      ),
                    )
                  : null;
              final logout = Env.hasSupabase
                  ? IconButton(
                      tooltip: 'Выйти',
                      icon: const Icon(Icons.logout, color: NoxColors.metalMid),
                      onPressed: signOut,
                    )
                  : null;
              final admin = isAdmin
                  ? IconButton(
                      tooltip: 'Админ-панель',
                      icon: const Icon(
                        Icons.admin_panel_settings_outlined,
                        color: NoxColors.metalMid,
                      ),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const AdminScreen(),
                        ),
                      ),
                    )
                  : null;
              return Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: narrow ? 16 : 24,
                  vertical: 12,
                ),
                child: narrow
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Expanded(child: _Brand(compact: true)),
                              ?history,
                              ?admin,
                              ?logout,
                            ],
                          ),
                          const SizedBox(height: 10),
                          status,
                        ],
                      )
                    : Row(
                        children: [
                          const _Brand(compact: false),
                          const Spacer(),
                          status,
                          ?history,
                          ?admin,
                          ?logout,
                        ],
                      ),
              );
            },
          ),
          const _SupportStrip(),
        ],
      ),
    );
  }
}

/// Ширина, ниже которой экран считается телефонным.
const kNarrowWidth = 720.0;

class _Brand extends StatelessWidget {
  const _Brand({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Image.asset(
        'assets/brand/nox_mono.png',
        height: compact ? 34 : 44,
        filterQuality: FilterQuality.medium,
      ),
      SizedBox(width: compact ? 12 : 16),
      Flexible(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MetalText(
              'nox.drive',
              style: TextStyle(
                fontSize: compact ? 22 : 26,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
            Text(
              'AUTOMOTIVE TECHNOLOGY',
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(
                fontSize: compact ? 9 : 10,
                letterSpacing: compact ? 3 : 5,
                color: NoxColors.metalMid.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _SupportStrip extends StatelessWidget {
  const _SupportStrip();

  static const _style = TextStyle(
    fontSize: 12,
    letterSpacing: 2,
    color: NoxColors.metalMid,
  );

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 8),
    color: NoxColors.bg,
    // На телефоне две ссылки переносятся в две строки.
    child: Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 18,
      runSpacing: 2,
      children: [
        _Link(
          key: const Key('support-telegram'),
          text: 'ДЛЯ АДБ ДОСТУПА ПИСАТЬ В ТГ $kSupportTelegram',
          url: 'https://t.me/${kSupportTelegram.substring(1)}',
          style: _style,
        ),
        _Link(
          key: const Key('support-instagram'),
          text: 'INSTAGRAM $kInstagram',
          url: 'https://instagram.com/${kInstagram.substring(1)}',
          style: _style,
          icon: Icons.camera_alt_outlined,
        ),
      ],
    ),
  );
}

class _Link extends StatelessWidget {
  const _Link({
    super.key,
    required this.text,
    required this.url,
    required this.style,
    this.icon,
  });
  final String text;
  final String url;
  final TextStyle style;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () =>
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: style.color),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(text, style: style, textAlign: TextAlign.center),
          ),
        ],
      ),
    ),
  );
}
