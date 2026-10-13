import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/env.dart';
import '../../app/theme.dart';
import '../../data/auth_repository.dart';
import '../../adb/adb_status_checker.dart';
import '../admin/admin_repository.dart';
import '../../core/json.dart';
import 'stream_service.dart';

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

/// Плашка у мастера и публикация трансляции по запросу админа.
/// Трансляция никогда не идёт незаметно для мастера (docs/STREAMING.md):
/// один раз спрашивается согласие, дальше при каждой трансляции видна красная плашка.
class StreamBanner extends ConsumerStatefulWidget {
  const StreamBanner({super.key});

  @override
  ConsumerState<StreamBanner> createState() => _StreamBannerState();
}

class _StreamBannerState extends ConsumerState<StreamBanner> {
  final _publisher = StreamPublisher();
  String? _error;
  bool _busy = false;

  SupabaseClient get _db => Supabase.instance.client;

  @override
  void dispose() {
    _publisher.stop();
    super.dispose();
  }

  Future<void> _sync(List<Map<String, dynamic>> open) async {
    if (_busy) return;
    final current = open
        .where((r) => r['id'] == _publisher.sessionId)
        .firstOrNull;
    if (_publisher.isActive && current == null) {
      await _publisher.stop(); // админ завершил трансляцию
      return;
    }
    final next = open.where((r) => r['status'] == 'requested').firstOrNull;
    if (_publisher.isActive || next == null) return;

    _busy = true;
    try {
      if (!await _ensureConsent()) {
        await _setStatus(str(next['id']), 'ended');
        return;
      }
      final adb = ref.read(adbStatusProvider).value;
      _publisher.huSerial = adb != null && adb.isReady ? adb.serial : null;
      await _publisher.start(str(next['id']), [
        for (final s in (next['sources'] as List? ?? const [])) str(s),
      ]);
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _busy = false;
    }
  }

  Future<bool> _ensureConsent() async {
    final uid = _db.auth.currentUser!.id;
    final row = await _db
        .from('masters')
        .select('stream_consent_at')
        .eq('id', uid)
        .maybeSingle();
    if (row?['stream_consent_at'] != null) return true;
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Трансляция администратору'),
        content: const Text(
          'Администратор может смотреть экран этого устройства и камеру во время работы. '
          'Пока идёт трансляция, вверху всегда видна красная плашка. '
          'Разрешить трансляции?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Не разрешать'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Разрешить'),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    await _db.rpc('master_stream_consent');
    return true;
  }

  Future<void> _setStatus(String id, String status) =>
      _db.rpc('master_stream_status', params: {'p_id': id, 'p_status': status});

  Future<void> _stopByMaster() async {
    final id = _publisher.sessionId;
    await _publisher.stop();
    if (id != null) await _setStatus(id, 'ended');
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(myStreamSessionsProvider, (_, next) {
      final open = next.value;
      if (open != null) _sync(open);
    });
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
                    : _error != null
                    ? 'Трансляция не запущена: $_error'
                    : 'Администратор запросил трансляцию: $sources',
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (_publisher.isActive)
              TextButton(
                onPressed: _stopByMaster,
                child: const Text(
                  'Остановить',
                  style: TextStyle(color: Colors.black),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
