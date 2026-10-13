import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/env.dart';
import '../core/json.dart';

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

/// Бот входа (имя по умолчанию; сервер может прислать ссылку на другого бота).
const kTelegramBot = 'NoxDrive_Bot';

/// Одноразовый код входа: 24 случайных байта в hex (48 символов).
String newTelegramNonce() {
  final rnd = Random.secure();
  return [
    for (var i = 0; i < 24; i++)
      rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// Вход через Telegram: код и ссылка на бота (Edge Function telegram-auth).
/// Код создаёт сама программа и передаёт серверу, поэтому формат ответа не важен:
/// если сервер не прислал nonce/link, используются свои значения.
Future<({String nonce, String link})> telegramStart() async {
  final own = newTelegramNonce();
  final d = await _telegram({'action': 'start', 'nonce': own});
  if (d['error'] != null) {
    throw Exception('Ошибка входа через Telegram: ${str(d['error'])}');
  }
  final nonce = strOrNull(d['nonce']) ?? own;
  final link =
      strOrNull(d['link']) ?? 'https://t.me/$kTelegramBot?start=$nonce';
  return (nonce: nonce, link: link);
}

/// Вызов Edge Function telegram-auth с понятными ошибками вместо падения на разборе ответа.
Future<Map<String, dynamic>> _telegram(Map<String, dynamic> body) async {
  try {
    final r = await Supabase.instance.client.functions.invoke(
      'telegram-auth',
      body: body,
    );
    return asMap(r.data);
  } on FunctionException catch (e) {
    final code = str(asMap(e.details)['error']);
    throw Exception(switch (code) {
      'TELEGRAM_NOT_CONFIGURED' =>
        'Вход через Telegram ещё не настроен (нет токена бота в Supabase)',
      _ when e.status == 404 => 'Вход через Telegram ещё не подключён: функция telegram-auth не опубликована',
      _ => 'Ошибка входа через Telegram (${code.isEmpty ? e.status : code})',
    });
  }
}

/// Один опрос: false, пока мастер не нажал «Старт» в боте; при подтверждении входит сам и возвращает true.
/// Бросает исключение, если код устарел.
Future<bool> telegramPoll(String nonce) async {
  final d = await _telegram({'action': 'poll', 'nonce': nonce});
  switch (str(d['status'])) {
    case 'pending':
      return false;
    case 'ok':
      await Supabase.instance.client.auth.verifyOTP(
        type: OtpType.magiclink,
        tokenHash: requireStr(d, 'token_hash', 'Вход через Telegram'),
      );
      return true;
    case 'expired' || 'invalid':
      throw Exception(
        'Код входа устарел. Нажмите «Войти через Telegram» ещё раз',
      );
    default:
      throw Exception(
        'Сервер входа через Telegram ответил неожиданно. '
        'Опубликуйте функцию telegram-auth заново',
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
  return strOrNull(row?['status']);
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
  return intOr(row?['credits']);
});
