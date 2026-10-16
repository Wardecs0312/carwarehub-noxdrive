import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/env.dart';
import '../../core/json.dart';

/// Мастер считается «в сети», если программа отмечалась за последние 2 минуты
/// (она отмечается раз в минуту).
const onlineWindow = Duration(minutes: 2);

/// Присутствие мастера: строка master_presence.
class Presence {
  const Presence({
    required this.masterId,
    required this.lastSeen,
    required this.activity,
    this.appVersion,
    this.platform,
    this.device,
    this.country,
    this.city,
  });

  final String masterId;
  final DateTime lastSeen;
  final String activity;
  final String? appVersion;
  final String? platform;
  final String? device;
  final String? country;
  final String? city;

  factory Presence.fromJson(Map<String, dynamic> j) => Presence(
    masterId: str(j['master_id']),
    lastSeen: dateOrNow(j['last_seen']),
    activity: str(j['activity']),
    appVersion: strOrNull(j['app_version']),
    platform: strOrNull(j['platform']),
    device: strOrNull(j['device']),
    country: strOrNull(j['country']),
    city: strOrNull(j['city']),
  );

  bool isOnline(DateTime now) => now.difference(lastSeen) < onlineWindow;

  /// «Кыргызстан, Бишкек» или null, если страна не определилась.
  String? get place => placeText(country, city);
}

String? placeText(String? country, String? city) {
  final s = [
    if (country != null && country.isNotEmpty) country,
    if (city != null && city.isNotEmpty) city,
  ].join(', ');
  return s.isEmpty ? null : s;
}

/// «в сети · работает с машиной» или «был 5 мин назад».
String presenceText(Presence? p, DateTime now) {
  if (p == null) return 'ещё не заходил в новую версию';
  if (p.isOnline(now)) {
    return switch (p.activity) {
      'job' => 'в сети · работает с машиной',
      'stream' => 'в сети · идёт трансляция',
      _ => 'в сети',
    };
  }
  return 'был ${agoText(p.lastSeen, now)}';
}

/// «только что», «5 мин назад», «3 ч назад», «2 дн назад».
String agoText(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.inMinutes < 1) return 'только что';
  if (d.inHours < 1) return '${d.inMinutes} мин назад';
  if (d.inDays < 1) return '${d.inHours} ч назад';
  return '${d.inDays} дн назад';
}

/// Одна запись истории входов.
class LoginEvent {
  const LoginEvent({
    required this.createdAt,
    this.ip,
    this.country,
    this.city,
    this.appVersion,
    this.platform,
    this.device,
  });

  final DateTime createdAt;
  final String? ip;
  final String? country;
  final String? city;
  final String? appVersion;
  final String? platform;
  final String? device;

  factory LoginEvent.fromJson(Map<String, dynamic> j) => LoginEvent(
    createdAt: dateOrNow(j['created_at']),
    ip: strOrNull(j['ip']),
    country: strOrNull(j['country']),
    city: strOrNull(j['city']),
    appVersion: strOrNull(j['app_version']),
    platform: strOrNull(j['platform']),
    device: strOrNull(j['device']),
  );
}

/// Присутствие всех мастеров в реальном времени (для админа; RLS отдаёт всё только админу).
final presenceMapProvider = StreamProvider.autoDispose<Map<String, Presence>>(
  (ref) => !Env.hasSupabase
      ? Stream.value(const {})
      : Supabase.instance.client
            .from('master_presence')
            .stream(primaryKey: ['master_id'])
            .map(
              (rows) => {
                for (final r in rows) str(r['master_id']): Presence.fromJson(r),
              },
            ),
);

/// Часы для надписей «был N мин назад»: обновляются раз в 30 секунд.
final presenceClockProvider = StreamProvider.autoDispose<DateTime>(
  (ref) => Stream.periodic(const Duration(seconds: 30), (_) => DateTime.now()),
);

final loginEventsProvider = FutureProvider.autoDispose
    .family<List<LoginEvent>, String>((ref, masterId) async {
      final rows = await Supabase.instance.client
          .from('login_events')
          .select(
            'created_at, ip, country, city, app_version, platform, device',
          )
          .eq('master_id', masterId)
          .order('created_at', ascending: false)
          .limit(100);
      return [for (final r in rows) LoginEvent.fromJson(r)];
    });
