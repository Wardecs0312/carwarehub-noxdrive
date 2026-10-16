import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/env.dart';
import '../../core/json.dart';
import '../../data/auth_repository.dart';
import '../../jobs/job_controller.dart';
import '../stream/stream_banner.dart';
import 'device_name.dart';

/// Чем сейчас занят мастер: online (в программе), job (идёт услуга), stream (идёт трансляция).
String presenceActivity({required bool jobRunning, required bool streaming}) =>
    streaming ? 'stream' : (jobRunning ? 'job' : 'online');

/// Страна и город по IP. Ошибка сети не мешает работе: вход запишется без страны.
Future<Map<String, String>?> fetchGeo({http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final r = await c
        .get(
          Uri.parse('https://ipwho.is/?lang=ru&fields=ip,success,country,city'),
        )
        .timeout(const Duration(seconds: 6));
    final j = asMap(jsonDecode(r.body));
    if (j['success'] != true) return null;
    return {
      'ip': str(j['ip']),
      'country': str(j['country']),
      'city': str(j['city']),
    };
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}

String get _platform => kIsWeb
    ? 'web'
    : switch (defaultTargetPlatform) {
        TargetPlatform.windows => 'windows',
        TargetPlatform.android => 'android',
        _ => defaultTargetPlatform.name,
      };

/// «Я в сети»: при входе записывает событие входа, затем раз в минуту отмечает присутствие.
/// Админ видит, кто сейчас в программе, когда был последний раз и откуда заходил.
class PresenceService {
  PresenceService(this.ref);
  final Ref ref;

  static const interval = Duration(seconds: 60);

  Timer? _timer;
  String? _uid;
  Map<String, String>? _geo;

  SupabaseClient get _db => Supabase.instance.client;

  Future<void> start(String uid) async {
    if (_uid == uid) return;
    stop();
    _uid = uid;
    final version = await ref.read(appVersionProvider.future);
    _geo = await fetchGeo();
    if (_uid != uid) return;
    try {
      await _db.rpc(
        'master_login_event',
        params: {
          'p_version': version,
          'p_platform': _platform,
          'p_device': await deviceName(),
          'p_geo': _geo,
        },
      );
    } catch (e) {
      debugPrint('presence: login event failed: $e');
    }
    _timer = Timer.periodic(interval, (_) => beat());
  }

  /// Отметка «в сети»; вызывается по таймеру и сразу при смене занятия.
  Future<void> beat() async {
    if (_uid == null) return;
    final jobRunning =
        ref.read(jobControllerProvider).phase == JobPhase.running;
    final streaming = (ref.read(myStreamSessionsProvider).value ?? const [])
        .any((s) => s['started_at'] != null);
    try {
      await _db.rpc(
        'master_heartbeat',
        params: {
          'p_activity': presenceActivity(
            jobRunning: jobRunning,
            streaming: streaming,
          ),
          'p_version': await ref.read(appVersionProvider.future),
          'p_platform': _platform,
          'p_device': await deviceName(),
          'p_geo': _geo,
        },
      );
    } catch (e) {
      debugPrint('presence: heartbeat failed: $e');
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _uid = null;
  }
}

/// Запускается один раз в корне приложения; следит за входом и выходом.
final presenceProvider = Provider<PresenceService?>((ref) {
  if (!Env.hasSupabase) return null;
  final service = PresenceService(ref);
  ref.onDispose(service.stop);
  ref.listen(
    sessionProvider.select((s) => s.value?.user.id),
    (_, uid) => uid == null ? service.stop() : unawaited(service.start(uid)),
    fireImmediately: true,
  );
  // Начало и конец услуги видны админу сразу, а не через минуту.
  ref.listen(
    jobControllerProvider.select((j) => j.phase == JobPhase.running),
    (_, _) => unawaited(service.beat()),
  );
  return service;
});
