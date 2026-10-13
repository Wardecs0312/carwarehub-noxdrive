import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/env.dart';
import '../../core/json.dart';

/// Одна выполненная (или начатая) услуга: строка таблицы activations с подписями из связанных таблиц.
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.createdAt,
    this.finishedAt,
    required this.vin,
    required this.service,
    required this.model,
    required this.firmware,
    required this.status,
    required this.credits,
    required this.masterName,
    this.appVersion,
  });

  final String id;
  final DateTime createdAt;
  final DateTime? finishedAt;
  final String vin;
  final String service;

  /// Модель авто (по сценарию услуги), например «Changan UNI-V».
  final String model;

  /// Прошивка ГУ, считанная при работе (ro.build.display.id), или шаблон прошивки сценария.
  final String firmware;

  /// running / success / failed
  final String status;
  final int credits;
  final String masterName;
  final String? appVersion;

  factory HistoryEntry.fromJson(Map<String, dynamic> j) {
    final scenario = asMap(j['scenarios']);
    final fw = asMap(scenario['firmwares']);
    final device = asMap(j['device_info']);
    final pattern = str(fw['version_pattern']);
    return HistoryEntry(
      id: str(j['id']),
      createdAt: dateOrNow(j['created_at']),
      finishedAt: j['finished_at'] == null ? null : dateOrNow(j['finished_at']),
      vin: str(j['vin']),
      service: strOrNull(asMap(j['services'])['title']) ?? 'Услуга',
      model: strOrNull(asMap(fw['car_models'])['title']) ?? '—',
      firmware:
          strOrNull(device['build']) ??
          (pattern.isEmpty || pattern == '%' ? 'любая' : pattern),
      status: str(j['status']),
      credits: intOr(j['credits']),
      masterName: strOrNull(asMap(j['masters'])['name']) ?? '—',
      appVersion: strOrNull(j['app_version']),
    );
  }
}

const _select =
    'id, vin, status, credits, created_at, finished_at, app_version, device_info, '
    'services(title), masters(name), '
    'scenarios(firmwares(version_pattern, car_models(title)))';

class HistoryRepository {
  SupabaseClient get _db => Supabase.instance.client;

  /// Работы текущего мастера (RLS отдаёт только его строки), новые сверху.
  Future<List<HistoryEntry>> mine() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return const [];
    final rows = await _db
        .from('activations')
        .select(_select)
        .eq('master_id', uid)
        .order('created_at', ascending: false)
        .limit(300);
    return [for (final r in rows) HistoryEntry.fromJson(r)];
  }

  /// Журнал всех мастеров (только для администратора), новые сверху.
  Future<List<HistoryEntry>> all() async {
    final rows = await _db
        .from('activations')
        .select(_select)
        .order('created_at', ascending: false)
        .limit(1000);
    return [for (final r in rows) HistoryEntry.fromJson(r)];
  }
}

final historyRepositoryProvider = Provider((_) => HistoryRepository());

final myHistoryProvider = FutureProvider.autoDispose<List<HistoryEntry>>(
  (ref) async =>
      Env.hasSupabase ? ref.watch(historyRepositoryProvider).mine() : const [],
);

final allHistoryProvider = FutureProvider.autoDispose<List<HistoryEntry>>(
  (ref) => ref.watch(historyRepositoryProvider).all(),
);
