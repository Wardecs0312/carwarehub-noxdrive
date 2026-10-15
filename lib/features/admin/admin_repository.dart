import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/env.dart';
import '../../app/owner.dart';
import '../../core/json.dart';
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
      id: str(j['id']),
      name: str(j['name']),
      phone: strOrNull(j['phone']),
      status: str(j['status']),
      credits: intOr(asMap(bal)['credits']),
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
    final a = asMap(j['activations']);
    return RefundRow(
      id: str(j['id']),
      masterName: strOrNull(asMap(j['masters'])['name']) ?? '—',
      reason: str(j['reason']),
      vin: str(a['vin']),
      service: str(asMap(a['services'])['title']),
      credits: intOr(a['credits']),
      createdAt: dateOrNow(j['created_at']),
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
    this.startedAt,
  });

  final String id;
  final String masterId;
  final String masterName;
  final List<String> sources;
  final String status;
  final DateTime createdAt;

  /// Когда мастер начал трансляцию (null, пока ждём мастера).
  final DateTime? startedAt;

  factory StreamSessionRow.fromJson(Map<String, dynamic> j) => StreamSessionRow(
    id: str(j['id']),
    masterId: str(j['master_id']),
    masterName: strOrNull(asMap(j['masters'])['name']) ?? '—',
    sources: [for (final s in (j['sources'] as List? ?? const [])) str(s)],
    status: str(j['status']),
    createdAt: dateOrNow(j['created_at']),
    startedAt: j['started_at'] == null ? null : dateOrNow(j['started_at']),
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

  /// Начислить (amount > 0) или списать (amount < 0) кредиты с причиной. Возвращает новый баланс.
  /// Причина записывается в журнал, баланс не уходит в минус.
  Future<int> adjustCredits(String masterId, int amount, String reason) async {
    try {
      final r = await _db.rpc(
        'admin_adjust_credits',
        params: {
          'p_master': masterId,
          'p_amount': amount,
          'p_reason': reason.trim(),
        },
      );
      return (r as num).toInt();
    } on PostgrestException catch (e) {
      throw Exception(switch (e.message) {
        final m when m.contains('NOT_ENOUGH_CREDITS') =>
          'Нельзя списать больше, чем есть на балансе',
        final m when m.contains('REASON_REQUIRED') =>
          'Укажите причину (от 3 символов)',
        final m when m.contains('BAD_AMOUNT') => 'Неверная сумма',
        final m when m.contains('FORBIDDEN') => 'Только для администратора',
        final m => m,
      });
    }
  }

  /// Новое имя (ник) мастера или самого администратора, 1–60 символов.
  Future<void> renameMaster(String masterId, String name) => _db.rpc(
    'admin_set_master_name',
    params: {'p_master': masterId, 'p_name': name.trim()},
  );

  /// Специальные цены мастера: код строки прайса → цена в кредитах.
  Future<Map<String, int>> masterPrices(String masterId) async {
    final rows = await _db
        .from('master_prices')
        .select('group_code, price_credits')
        .eq('master_id', masterId);
    return {
      for (final r in rows) str(r['group_code']): intOr(r['price_credits']),
    };
  }

  /// Специальная цена мастеру; null — снять, мастер платит обычную цену.
  Future<void> setMasterPrice(String masterId, String group, int? credits) =>
      _db.rpc(
        'admin_set_master_price',
        params: {'p_master': masterId, 'p_group': group, 'p_price': credits},
      );

  /// pending → active (одобрить), active ↔ blocked.
  Future<void> setMasterStatus(String masterId, String status) => _db.rpc(
    'admin_set_master_status',
    params: {'p_master': masterId, 'p_status': status},
  );

  /// Привязка бота к Edge Function telegram-auth. Возвращает текст для админа.
  Future<String> setupTelegram() async {
    try {
      final r = await _db.functions.invoke(
        'telegram-auth',
        body: {'action': 'setup_webhook'},
      );
      return asMap(r.data)['ok'] == true
          ? 'Telegram-бот подключён'
          : 'Telegram ответил ошибкой';
    } on FunctionException catch (e) {
      final d = e.details;
      final code = strOrNull(asMap(d)['error'] ?? asMap(d)['description']);
      return switch (code) {
        'TELEGRAM_NOT_CONFIGURED' =>
          'В Supabase Secrets нет TELEGRAM_BOT_TOKEN',
        'FORBIDDEN' => 'Нужны права администратора',
        _ when e.status == 404 =>
          'Функция telegram-auth ещё не опубликована в Supabase',
        _ => 'Ошибка: ${code ?? e.status}',
      };
    }
  }

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
        .select(
          'id, master_id, sources, status, created_at, started_at, masters(name)',
        )
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
  // Владелец — администратор всегда, без запроса к серверу.
  if (isOwnerUser(session.user)) return true;
  // При запуске сохранённый токен может быть просрочен, пока Supabase его обновляет:
  // одна неудачная проверка не должна навсегда прятать админ-панель.
  final client = Supabase.instance.client;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      return await client.rpc('nox_is_admin') == true;
    } catch (e) {
      debugPrint('nox_is_admin attempt $attempt failed: $e');
      if (attempt == 0) {
        try {
          await client.auth.refreshSession();
        } catch (_) {}
      }
      await Future<void>.delayed(Duration(seconds: 1 + attempt * 2));
    }
  }
  return false;
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
