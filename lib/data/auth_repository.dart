import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/env.dart';

/// Сессия мастера. Без Supabase возвращает null и приложение работает в демо-режиме.
final sessionProvider = StreamProvider<Session?>((ref) {
  if (!Env.hasSupabase) return Stream.value(null);
  final auth = Supabase.instance.client.auth;
  return (() async* {
    yield auth.currentSession;
    yield* auth.onAuthStateChange.map((e) => e.session);
  })();
});

Future<void> signIn(String email, String password) async {
  try {
    await Supabase.instance.client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
  } on AuthException catch (e) {
    throw Exception(
      e.message.contains('Invalid login')
          ? 'Неверная почта или пароль'
          : e.message,
    );
  }
}

Future<void> signOut() => Supabase.instance.client.auth.signOut();

/// Баланс кредитов мастера. null: демо-режим или баланс ещё не создан.
final balanceProvider = FutureProvider<int?>((ref) async {
  if (!Env.hasSupabase) return null;
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return null;
  final row = await Supabase.instance.client
      .from('master_balance')
      .select('credits')
      .eq('master_id', uid)
      .maybeSingle();
  return (row?['credits'] as int?) ?? 0;
});
