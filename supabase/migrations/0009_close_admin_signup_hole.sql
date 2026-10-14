-- Закрывает самостоятельное получение прав администратора при регистрации (аудит 13.10.2026, пункт B-1).
--
-- Причина: 0007 брала telegram_id из raw_user_meta_data, а это поле пользователь задаёт сам в signUp(data: {...}).
-- Любой, кто подставил туда Telegram ID владельца, становился администратором.
--
-- Что меняется:
--  1) Права владельца по Telegram выдаются только по raw_app_meta_data. Это поле не задаётся с клиента:
--     его пишет лишь сервер (Edge Function telegram-auth через service_role).
--  2) masters.telegram_id тоже берётся только из app_metadata: чужой Telegram ID больше нельзя «занять».
--  3) Почта владельца больше не даёт права автоматически. Владелец уже записан в admins миграцией 0007.
--     Если учётную запись владельца пересоздали, права выдаются вручную (supabase/audit_admins.sql).
--  4) Метки name/phone ограничены по длине, created_via и telegram_username больше не берутся «на веру».
--
-- Миграция никого не удаляет и не разжалует: она выводит список текущих администраторов в сообщениях (NOTICE).
-- Лишних администраторов разжалуйте вручную по supabase/audit_admins.sql.
--
-- ПОРЯДОК: сначала опубликовать новую версию функции telegram-auth (она начинает писать app_metadata),
-- затем выполнить этот файл. Скрипт можно запускать повторно.

create or replace function is_owner_telegram(p_telegram_id bigint) returns boolean
language sql immutable as $$
  select coalesce(p_telegram_id, 0) = 8106761823
$$;

create or replace function on_auth_user_created() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  a jsonb := coalesce(new.raw_app_meta_data, '{}'::jsonb);
  -- Только из app_metadata (пишет сервер). Нечисловое значение игнорируется, а не ломает регистрацию.
  tg bigint := case when a->>'telegram_id' ~ '^[0-9]{1,18}$' then (a->>'telegram_id')::bigint end;
  owner boolean := is_owner_telegram(tg);
begin
  insert into masters (id, name, phone, status, role, email, telegram_id, telegram_username, created_via)
  values (
    new.id,
    left(coalesce(nullif(trim(m->>'name'), ''), split_part(new.email, '@', 1)), 100),
    left(nullif(trim(m->>'phone'), ''), 40),
    case when owner then 'active' else 'pending' end,
    case when owner then 'admin' else 'master' end,
    case when tg is not null then null else new.email end,
    tg,
    case when tg is not null then left(nullif(trim(m->>'telegram_username'), ''), 64) end,
    case when tg is not null then 'telegram'
         when m->>'via' = 'email' then 'email'
         else 'admin' end
  )
  on conflict (id) do nothing;
  insert into master_balance (master_id) values (new.id) on conflict do nothing;
  if owner then
    insert into admins (user_id) values (new.id) on conflict do nothing;
  end if;
  return new;
end $$;

-- Старая функция принимала почту и Telegram ID из метаданных пользователя; больше не нужна.
drop function if exists is_owner_identity(text, bigint);

-- Текущие администраторы: должна быть только ваша учётная запись. Результат смотрите во вкладке сообщений.
do $$
declare
  r record;
  n int := 0;
begin
  for r in
    select u.id, u.email, m.telegram_id, m.created_via, u.created_at
    from auth.users u
    left join masters m on m.id = u.id
    where m.role = 'admin' or exists (select 1 from admins a where a.user_id = u.id)
    order by u.created_at
  loop
    n := n + 1;
    raise notice 'ADMIN % | email=% | telegram=% | via=% | создан %',
      r.id, r.email, r.telegram_id, r.created_via, r.created_at;
  end loop;
  raise notice 'Администраторов: %. Лишних быть не должно, разжалуйте их по supabase/audit_admins.sql.', n;
end $$;
