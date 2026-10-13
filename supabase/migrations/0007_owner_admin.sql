-- Владелец всегда администратор: почта wardecsfly@gmail.com и Telegram 8106761823.
-- 1) колонка masters.role ('master' | 'admin');
-- 2) nox_is_admin() = запись в admins ИЛИ masters.role = 'admin';
-- 3) при создании аккаунта владельца (почта или Telegram) он сразу админ и одобрен (status = 'active').
-- Статус «одобрен» в этой базе называется 'active'. Скрипт можно запускать повторно.

alter table masters add column if not exists role text not null default 'master';
alter table masters drop constraint if exists masters_role_check;
alter table masters add constraint masters_role_check check (role in ('master','admin'));

create or replace function is_owner_identity(p_email text, p_telegram_id bigint) returns boolean
language sql immutable as $$
  select lower(coalesce(p_email, '')) = 'wardecsfly@gmail.com'
      or coalesce(p_telegram_id, 0) = 8106761823
$$;

create or replace function nox_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid())
      or exists (select 1 from masters where id = auth.uid() and role = 'admin')
$$;

-- Уже существующие аккаунты владельца.
update masters m set role = 'admin', status = 'active'
  from auth.users u
 where u.id = m.id and is_owner_identity(u.email, m.telegram_id);
insert into admins (user_id)
select m.id from masters m join auth.users u on u.id = m.id
 where is_owner_identity(u.email, m.telegram_id)
on conflict do nothing;

-- Новые аккаунты: владелец сразу админ и одобрен, остальные — мастер в ожидании.
create or replace function on_auth_user_created() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  tg bigint := nullif(m->>'telegram_id', '')::bigint;
  owner boolean := is_owner_identity(new.email, tg);
begin
  insert into masters (id, name, phone, status, role, email, telegram_id, telegram_username, created_via)
  values (
    new.id,
    coalesce(nullif(trim(m->>'name'), ''), split_part(new.email, '@', 1)),
    nullif(trim(m->>'phone'), ''),
    case when owner then 'active' else 'pending' end,
    case when owner then 'admin' else 'master' end,
    case when m->>'via' = 'telegram' then null else new.email end,
    tg,
    m->>'telegram_username',
    case when m->>'via' in ('email','telegram') then m->>'via' else 'admin' end
  )
  on conflict (id) do nothing;
  insert into master_balance (master_id) values (new.id) on conflict do nothing;
  if owner then
    insert into admins (user_id) values (new.id) on conflict do nothing;
  end if;
  return new;
end $$;

-- Владельца нельзя случайно заблокировать или разжаловать из админ-панели.
create or replace function admin_set_master_status(p_master uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not nox_is_admin() then raise exception 'FORBIDDEN'; end if;
  if p_status not in ('pending','active','blocked') then raise exception 'BAD_STATUS'; end if;
  if exists (select 1 from masters where id = p_master and role = 'admin') and p_status <> 'active' then
    raise exception 'OWNER_PROTECTED';
  end if;
  update masters set status = p_status where id = p_master;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;
