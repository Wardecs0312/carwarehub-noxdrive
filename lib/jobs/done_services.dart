import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/env.dart';
import '../core/vin.dart';

/// Сколько времени выполненная услуга считается «сделанной сегодня» на этой машине.
const doneWindow = Duration(hours: 24);

/// Успешные услуги этого запуска программы: (VIN, код услуги). Видны сразу, без ответа сервера.
final localDoneProvider = StateProvider<Set<(String, String)>>((_) => {});

/// Услуги, которые текущий мастер успешно выполнил на этом VIN за [doneWindow] (по журналу сервера).
final serverDoneProvider = FutureProvider.autoDispose
    .family<Set<String>, String>((ref, vin) async {
      if (!Env.hasSupabase || !isValidVin(vin)) return const {};
      final db = Supabase.instance.client;
      final uid = db.auth.currentUser?.id;
      if (uid == null) return const {};
      final since = DateTime.now().toUtc().subtract(doneWindow);
      final rows = await db
          .from('activations')
          .select('services(code)')
          .eq('master_id', uid)
          .eq('vin', vin)
          .eq('status', 'success')
          .gte('created_at', since.toIso8601String());
      return {
        for (final r in rows)
          if (r['services'] case {'code': final String code}) code,
      };
    });

/// Коды услуг, уже выполненных на машине с этим VIN: карточки накрываются зелёным с галочкой,
/// мастер видит, что всё сделано и можно перезагружать.
final doneServicesProvider = Provider.autoDispose.family<Set<String>, String>((
  ref,
  vin,
) {
  final server = ref.watch(serverDoneProvider(vin)).value ?? const {};
  return {
    ...server,
    for (final (v, code) in ref.watch(localDoneProvider))
      if (v == vin) code,
  };
});
