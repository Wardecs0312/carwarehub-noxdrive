-- Самостоятельная регистрация мастеров: через почту и через Telegram.
-- Новый мастер получает статус pending и работает только после одобрения админом.

alter table masters drop constraint if exists masters_status_check;
alter table masters add constraint masters_status_check
  check (status in ('pending','active','blocked'));
alter table masters add column if not exists email text;
alter table masters add column if not exists telegram_id bigint unique;
alter table masters add column if not exists telegram_username text;
alter table masters add column if not exists created_via text not null default 'admin'
  check (created_via in ('admin','email','telegram'));

-- Новый пользователь Supabase Auth -> строка мастера (pending) и нулевой баланс.
-- Данные регистрации приходят в raw_user_meta_data: name, phone, telegram_id, telegram_username, via.
create or replace function on_auth_user_created() returns trigger
language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into masters (id, name, phone, status, email, telegram_id, telegram_username, created_via)
  values (
    new.id,
    coalesce(nullif(trim(m->>'name'), ''), split_part(new.email, '@', 1)),
    nullif(trim(m->>'phone'), ''),
    'pending',
    case when m->>'via' = 'telegram' then null else new.email end,
    (m->>'telegram_id')::bigint,
    m->>'telegram_username',
    case when m->>'via' in ('email','telegram') then m->>'via' else 'admin' end
  )
  on conflict (id) do nothing;
  insert into master_balance (master_id) values (new.id) on conflict do nothing;
  return new;
end $$;

drop trigger if exists auth_user_created on auth.users;
create trigger auth_user_created after insert on auth.users
  for each row execute function on_auth_user_created();

-- Одобрение / блокировка мастера админом.
create or replace function admin_set_master_status(p_master uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not nox_is_admin() then raise exception 'FORBIDDEN'; end if;
  if p_status not in ('pending','active','blocked') then raise exception 'BAD_STATUS'; end if;
  update masters set status = p_status where id = p_master;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

-- Вход через Telegram: одноразовый код, который бот подтверждает по /start <код>.
-- Доступ только у Edge Function (service_role); клиентам таблица закрыта.
create table if not exists telegram_logins (
  nonce text primary key,
  created_at timestamptz not null default now(),
  telegram_id bigint,
  telegram_username text,
  telegram_name text,
  confirmed_at timestamptz,
  consumed_at timestamptz
);
alter table telegram_logins enable row level security;
