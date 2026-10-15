-- Подпись выпусков (аудит 13.10.2026, пункт F-1).
-- Утилита выпуска подписывает каждую версию ключом администратора, программа для Windows проверяет подпись
-- открытым ключом, зашитым в код, и без неё обновление не ставит. Здесь только новый столбец, данные не меняются.
alter table app_releases add column if not exists signature text;
comment on column app_releases.signature is
  'Ed25519 (base64) от строки "nox.drive release v1\n<platform>\n<version>\n<build>\n<sha256>\n", см. lib/security/release_signature.dart';
