import 'package:supabase_flutter/supabase_flutter.dart';

/// Владелец проекта: всегда администратор, при входе и по почте, и через Telegram.
/// На сервере права проверяет nox_is_admin() (таблица admins и masters.role, миграция 0007),
/// здесь — чтобы админ-панель не пропадала, даже если проверка на сервере не успела ответить.
const kOwnerEmail = 'wardecsfly@gmail.com';
const kOwnerTelegramId = 8106761823;

bool isOwnerUser(User? user) {
  if (user == null) return false;
  if ((user.email ?? '').toLowerCase() == kOwnerEmail) return true;
  final tg = user.userMetadata?['telegram_id'];
  return tg?.toString() == '$kOwnerTelegramId';
}
