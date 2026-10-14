import 'package:supabase_flutter/supabase_flutter.dart';

/// Владелец проекта: администратор и при входе по почте, и через Telegram.
/// Права на самом деле проверяет сервер (`nox_is_admin()`, таблица admins и masters.role);
/// здесь только быстрый признак, чтобы админ-панель не пропадала, пока сервер не ответил.
///
/// Смотрим только на данные, которые клиент подделать не может:
/// `email` подтверждает сервер, `appMetadata` пишет только сервер.
/// `userMetadata` пользователь задаёт сам при регистрации, ему верить нельзя.
const kOwnerEmail = 'wardecsfly@gmail.com';
const kOwnerTelegramId = 8106761823;

bool isOwnerUser(User? user) {
  if (user == null) return false;
  if ((user.email ?? '').toLowerCase() == kOwnerEmail) return true;
  return user.appMetadata['telegram_id']?.toString() == '$kOwnerTelegramId';
}
