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

/// Регистрация по почте. Возвращает true, если нужно подтвердить почту по ссылке из письма.
/// Строку мастера (статус «ожидает одобрения») создаёт триггер в базе (миграция 0006).
Future<bool> signUp({
  required String name,
  required String phone,
  required String email,
  required String password,
}) async {
  try {
    final r = await Supabase.instance.client.auth.signUp(
      email: email.trim(),
      password: password,
      data: {'via': 'email', 'name': name.trim(), 'phone': phone.trim()},
    );
    return r.session == null;
  } on AuthException catch (e) {
    final m = e.message.toLowerCase();
    throw Exception(
      m.contains('already')
          ? 'Эта почта уже зарегистрирована. Войдите'
          : m.contains('password')
          ? 'Пароль слишком простой: минимум 6 символов'
          : e.message,
    );
  }
}

/// Вход через Telegram: код и ссылка на бота (Edge Function telegram-auth).
Future<({String nonce, String link})> telegramStart() async {
  final r = await Supabase.instance.client.functions.invoke(
    'telegram-auth',
    body: {'action': 'start'},
  );
  final d = r.data as Map<String, dynamic>;
  return (nonce: d['nonce'] as String, link: d['link'] as String);
}

/// Один опрос: false, пока мастер не нажал «Старт» в боте; при подтверждении входит сам и возвращает true.
/// Бросает исключение, если код устарел.
Future<bool> telegramPoll(String nonce) async {
  final r = await Supabase.instance.client.functions.invoke(
    'telegram-auth',
    body: {'action': 'poll', 'nonce': nonce},
  );
  final d = r.data as Map<String, dynamic>;
  switch (d['status']) {
    case 'pending':
      return false;
    case 'ok':
      await Supabase.instance.client.auth.verifyOTP(
        type: OtpType.magiclink,
        tokenHash: d['token_hash'] as String,
      );
      return true;
    default:
      throw Exception(
        'Код входа устарел. Нажмите «Войти через Telegram» ещё раз',
      );
  }
}

/// Статус мастера: pending (ожидает одобрения), active, blocked. null: демо или не мастер.
final masterStatusProvider = FutureProvider<String?>((ref) async {
  final session = ref.watch(sessionProvider).value;
  if (!Env.hasSupabase || session == null) return null;
  final row = await Supabase.instance.client
      .from('masters')
      .select('status')
      .eq('id', session.user.id)
      .maybeSingle();
  return row?['status'] as String?;
});

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
