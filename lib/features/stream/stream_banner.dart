import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/env.dart';
import '../../app/theme.dart';
import '../../data/auth_repository.dart';
import '../admin/admin_repository.dart';

/// Открытые запросы трансляции текущего мастера (Supabase Realtime, без опроса).
final myStreamSessionsProvider = StreamProvider<List<Map<String, dynamic>>>((
  ref,
) {
  final uid = ref.watch(sessionProvider).value?.user.id;
  if (!Env.hasSupabase || uid == null) return Stream.value(const []);
  return Supabase.instance.client
      .from('stream_sessions')
      .stream(primaryKey: ['id'])
      .eq('master_id', uid)
      .map((rows) => rows.where((r) => r['status'] != 'ended').toList());
});

/// Плашка у мастера: администратор запросил или смотрит трансляцию.
/// Трансляция никогда не идёт незаметно для мастера (docs/STREAMING.md).
class StreamBanner extends ConsumerWidget {
  const StreamBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(myStreamSessionsProvider).value ?? const [];
    if (open.isEmpty) return const SizedBox.shrink();
    final live = open.any((r) => r['status'] == 'live');
    final sources = {
      for (final r in open)
        for (final s in (r['sources'] as List? ?? const []))
          streamSources[s] ?? '$s',
    }.join(', ');
    return Material(
      color: live ? NoxColors.bad : NoxColors.warn,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              live ? Icons.fiber_manual_record : Icons.videocam_outlined,
              color: Colors.black,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                live
                    ? 'Идёт трансляция администратору: $sources'
                    : 'Администратор запросил трансляцию: $sources',
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
