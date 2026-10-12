import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/env.dart';
import '../../data/auth_repository.dart';

/// Мастер в админ-панели.
class MasterRow {
  const MasterRow({
    required this.id,
    required this.name,
    this.phone,
    required this.status,
    required this.credits,
  });

  final String id;
  final String name;
  final String? phone;
  final String status;
  final int credits;

  factory MasterRow.fromJson(Map<String, dynamic> j) {
    // master_balance встраивается как объект (связь 1:1) или как список, если PostgREST не распознал 1:1.
    final b = j['master_balance'];
    final bal = b is List ? (b.isEmpty ? null : b.first) : b;
    return MasterRow(
      id: j['id'] as String,
      name: j['name'] as String,
      phone: j['phone'] as String?,
      status: j['status'] as String,
      credits: (bal?['credits'] as int?) ?? 0,
    );
  }
}

/// Заявка мастера на возврат кредитов.
class RefundRow {
  const RefundRow({
    required this.id,
    required this.masterName,
    required this.reason,
    required this.vin,
    required this.service,
    required this.credits,
    required this.createdAt,
  });

  final String id;
  final String masterName;
  final String reason;
  final String vin;
  final String service;
  final int credits;
  final DateTime createdAt;

  factory RefundRow.fromJson(Map<String, dynamic> j) {
    final a = (j['activations'] as Map?) ?? const {};
    return RefundRow(
      id: j['id'] as String,
      masterName: ((j['masters'] as Map?)?['name'] as String?) ?? '—',
      reason: (j['reason'] as String?) ?? '',
      vin: (a['vin'] as String?) ?? '',
      service: ((a['services'] as Map?)?['title'] as String?) ?? '',
      credits: (a['credits'] as int?) ?? 0,
      createdAt: DateTime.parse(j['created_at'] as String),
    );
  }
}

/// Сеанс трансляции (таблица stream_sessions, миграция 0005).
class StreamSessionRow {
  const StreamSessionRow({
    required this.id,
    required this.masterId,
    required this.masterName,
    required this.sources,
    required this.status,
    required this.createdAt,
  });

  final String id;
  final String masterId;
  final String masterName;
  final List<String> sources;
  final String status;
  final DateTime createdAt;

  factory StreamSessionRow.fromJson(Map<String, dynamic> j) => StreamSessionRow(
    id: j['id'] as String,
    masterId: j['master_id'] as String,
    masterName: ((j['masters'] as Map?)?['name'] as String?) ?? '—',
    sources: [for (final s in (j['sources'] as List? ?? const [])) s as String],
    status: j['status'] as String,
    createdAt: DateTime.parse(j['created_at'] as String),
  );
}

/// Источники трансляции: экран ноутбука, экран ГУ, камера.
const streamSources = {
  'screen-laptop': 'Экран ноутбука',
  'screen-hu': 'Экран ГУ',
  'camera': 'Камера',
};

class AdminRepository {
  SupabaseClient get _db => Supabase.instance.client;

  Future<List<MasterRow>> masters() async {
    final rows = await _db
        .from('masters')
        .select('id, name, phone, status, master_balance(credits)')
        .order('name');
    return [for (final r in rows) MasterRow.fromJson(r)];
  }

  Future<void> topUp(String masterId, int amount) => _db.rpc(
    'admin_topup',
    params: {'p_master': masterId, 'p_amount': amount},
  );

  Future<List<RefundRow>> pendingRefunds() async {
    final rows = await _db
        .from('refund_requests')
        .select(
          'id, reason, created_at, masters(name), activations(vin, credits, services(title))',
        )
        .eq('status', 'pending')
        .order('created_at');
    return [for (final r in rows) RefundRow.fromJson(r)];
  }

  Future<void> decideRefund(String id, {required bool approve}) => _db.rpc(
    'admin_decide_refund',
    params: {'p_refund_id': id, 'p_approve': approve},
  );

  Future<List<StreamSessionRow>> streamSessions() async {
    final rows = await _db
        .from('stream_sessions')
        .select('id, master_id, sources, status, created_at, masters(name)')
        .neq('status', 'ended')
        .order('created_at', ascending: false);
    return [for (final r in rows) StreamSessionRow.fromJson(r)];
  }

  /// Запрос трансляции: приложение мастера получает строку через Supabase Realtime и показывает плашку.
  Future<void> requestStream(String masterId, List<String> sources) =>
      _db.from('stream_sessions').insert({
        'master_id': masterId,
        'requested_by': _db.auth.currentUser!.id,
        'sources': sources,
      });

  Future<void> endStream(String id) => _db
      .from('stream_sessions')
      .update({
        'status': 'ended',
        'ended_at': DateTime.now().toUtc().toIso8601String(),
      })
      .eq('id', id);
}

final adminRepositoryProvider = Provider((_) => AdminRepository());

/// Текущий пользователь администратор? Пересчитывается при смене сессии.
final isAdminProvider = FutureProvider<bool>((ref) async {
  final session = ref.watch(sessionProvider).value;
  if (!Env.hasSupabase || session == null) return false;
  try {
    return await Supabase.instance.client.rpc('nox_is_admin') as bool;
  } catch (_) {
    return false;
  }
});

final adminMastersProvider = FutureProvider.autoDispose(
  (ref) => ref.watch(adminRepositoryProvider).masters(),
);

final adminRefundsProvider = FutureProvider.autoDispose(
  (ref) => ref.watch(adminRepositoryProvider).pendingRefunds(),
);

final adminStreamsProvider = FutureProvider.autoDispose(
  (ref) => ref.watch(adminRepositoryProvider).streamSessions(),
);
