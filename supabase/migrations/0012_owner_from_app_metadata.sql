-- Владелец (администратор) определяется только по серверным данным.
-- В 0007 триггер брал telegram_id из raw_user_meta_data, а её задаёт сам пользователь при регистрации по почте:
-- любой мог вписать Telegram ID владельца и сразу стать администратором. Владелец по почте тоже убран:
-- триггер срабатывает до подтверждения почты.
-- Эта версия совпадает с боевой базой CarWareHubNoxDrive (сверено 14.10.2026), повторный запуск безопасен.

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
    case when tg is not null then 'telegram' when m->>'via' = 'email' then 'email' else 'admin' end
  )
  on conflict (id) do nothing;
  insert into master_balance (master_id) values (new.id) on conflict do nothing;
  if owner then
    insert into admins (user_id) values (new.id) on conflict do nothing;
  end if;
  return new;
end $$;

revoke execute on function on_auth_user_created() from public, anon;
