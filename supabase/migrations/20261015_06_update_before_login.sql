-- Обязательное обновление показывается сразу при запуске программы, ещё до входа (экран поверх всего).
-- Для этого список активных версий и файлы обновлений читаются без входа. Это безопасно:
-- установщик и так открыт на странице скачивания, а каждое обновление подписано ключом nox.drive,
-- и программа без верной подписи его не ставит (lib/security/release_signature.dart).
-- Только правила чтения, данные не меняются. Скрипт можно запускать повторно.
drop policy if exists app_releases_public_read on app_releases;
create policy app_releases_public_read on app_releases for select to anon, authenticated using (is_active);

drop policy if exists releases_read on storage.objects;
create policy releases_read on storage.objects for select to anon, authenticated
  using (bucket_id = 'releases');
