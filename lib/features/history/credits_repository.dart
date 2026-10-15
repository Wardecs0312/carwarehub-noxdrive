import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/env.dart';
import '../../core/json.dart';

/// Одна строка журнала кредитов (balance_ledger): пополнение, списание, возврат или корректировка.
class CreditEntry {
  const CreditEntry({
    required this.id,
    required this.createdAt,
    required this.masterId,
    required this.masterName,
    required this.amount,
    required this.reason,
    this.note,
    this.activationId,
    this.vin,
    this.service,
    this.balanceAfter,
  });

  final String id;
  final DateTime createdAt;
  final String masterId;
  final String masterName;

  /// + пополнение/возврат, - списание.
  final int amount;

  /// topup / charge / refund / adjust
  final String reason;

  /// Причина, которую указал админ.
  final String? note;
  final String? activationId;

  /// Машина и услуга, если операция связана с работой.
  final String? vin;
  final String? service;

  /// Баланс мастера сразу после операции.
  final int? balanceAfter;

  factory CreditEntry.fromJson(Map<String, dynamic> j) => CreditEntry(
    id: str(j['id']),
    createdAt: dateOrNow(j['created_at']),
    masterId: str(j['master_id']),
    masterName: strOrNull(asMap(j['masters'])['name']) ?? '—',
    amount: intOr(j['amount']),
    reason: str(j['reason']),
    note: strOrNull(j['note']),
    activationId: strOrNull(j['activation_id']),
  );

  CreditEntry copyWith({String? vin, String? service, int? balanceAfter}) =>
      CreditEntry(
        id: id,
        createdAt: createdAt,
        masterId: masterId,
        masterName: masterName,
        amount: amount,
        reason: reason,
        note: note,
        activationId: activationId,
        vin: vin ?? this.vin,
        service: service ?? this.service,
        balanceAfter: balanceAfter ?? this.balanceAfter,
      );

  /// Баланс после каждой операции: идём от нового к старому, начиная с текущего баланса мастера.
  /// [newestFirst] — строки, отсортированные от новых к старым.
  static List<CreditEntry> withBalances(
    List<CreditEntry> newestFirst,
    Map<String, int> current,
  ) {
    final running = Map<String, int>.of(current);
    final out = <CreditEntry>[];
    for (final e in newestFirst) {
      final b = running[e.masterId];
      if (b == null) {
        out.add(e);
        continue;
      }
      running[e.masterId] = b - e.amount;
      out.add(e.copyWith(balanceAfter: b));
    }
    return out;
  }
}

const _select =
    'id, master_id, amount, reason, note, activation_id, created_at, masters(name)';

class CreditsRepository {
  SupabaseClient get _db => Supabase.instance.client;

  /// Операции текущего мастера, новые сверху.
  Future<List<CreditEntry>> mine() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return const [];
    final rows = await _db
        .from('balance_ledger')
        .select(_select)
        .eq('master_id', uid)
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .limit(500);
    return _finish(
      rows,
      _db
          .from('master_balance')
          .select('master_id, credits')
          .eq('master_id', uid),
    );
  }

  /// Операции всех мастеров (только для администратора), новые сверху.
  Future<List<CreditEntry>> all() async {
    final rows = await _db
        .from('balance_ledger')
        .select(_select)
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .limit(2000);
    return _finish(
      rows,
      _db.from('master_balance').select('master_id, credits'),
    );
  }

  Future<List<CreditEntry>> _finish(
    List<Map<String, dynamic>> rows,
    Future<List<Map<String, dynamic>>> balances,
  ) async {
    final entries = [for (final r in rows) CreditEntry.fromJson(r)];
    final current = {
      for (final b in await balances) str(b['master_id']): intOr(b['credits']),
    };
    final cars = await _cars({
      for (final e in entries)
        if (e.activationId != null) e.activationId!,
    });
    return CreditEntry.withBalances([
      for (final e in entries)
        if (cars[e.activationId] case (final vin, final service))
          e.copyWith(vin: vin, service: service)
        else
          e,
    ], current);
  }

  /// VIN и услуга для операций, связанных с работами (в журнале кредитов хранится только id работы).
  Future<Map<String, (String, String)>> _cars(Set<String> ids) async {
    final out = <String, (String, String)>{};
    final list = ids.toList();
    for (var i = 0; i < list.length; i += 150) {
      final part = list.sublist(
        i,
        i + 150 > list.length ? list.length : i + 150,
      );
      final rows = await _db
          .from('activations')
          .select('id, vin, services(title)')
          .inFilter('id', part);
      for (final r in rows) {
        out[str(r['id'])] = (
          str(r['vin']),
          strOrNull(asMap(r['services'])['title']) ?? 'Услуга',
        );
      }
    }
    return out;
  }
}

final creditsRepositoryProvider = Provider((_) => CreditsRepository());

final myCreditsProvider = FutureProvider.autoDispose<List<CreditEntry>>(
  (ref) async =>
      Env.hasSupabase ? ref.watch(creditsRepositoryProvider).mine() : const [],
);

final allCreditsProvider = FutureProvider.autoDispose<List<CreditEntry>>(
  (ref) => ref.watch(creditsRepositoryProvider).all(),
);
