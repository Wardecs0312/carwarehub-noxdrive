-- Кто в сети и история входов для админ-панели.
-- Программа мастера раз в минуту вызывает master_heartbeat, при запуске/входе — master_login_event.
-- IP берётся на сервере из заголовков запроса; страна и город — из ответа геосервиса, который
-- присылает программа (geo_ip показывает, для какого IP он был получен).

create table if not exists master_presence (
  master_id uuid primary key references masters on delete cascade,
  last_seen timestamptz not null default now(),
  activity text not null default 'online',   -- online / job / stream
  app_version text,
  platform text,                             -- windows / web / android
  device text,
  ip text,
  country text,
  city text
);
alter table master_presence enable row level security;
drop policy if exists presence_read on master_presence;
create policy presence_read on master_presence for select to authenticated
  using (master_id = auth.uid() or nox_is_admin());

create table if not exists login_events (
  id bigint generated always as identity primary key,
  master_id uuid not null references masters on delete cascade,
  created_at timestamptz not null default now(),
  ip text,
  geo_ip text,
  country text,
  city text,
  app_version text,
  platform text,
  device text
);
create index if not exists login_events_master_idx on login_events (master_id, created_at desc);
alter table login_events enable row level security;
drop policy if exists login_events_read on login_events;
create policy login_events_read on login_events for select to authenticated
  using (master_id = auth.uid() or nox_is_admin());

-- Читать можно только по политикам выше; писать — только через функции.
revoke all on master_presence, login_events from anon;
grant select on master_presence, login_events to authenticated;

-- IP клиента из заголовков PostgREST (первый адрес в X-Forwarded-For).
create or replace function request_ip() returns text
language sql stable set search_path = public as $$
  select nullif(btrim(split_part(coalesce(
    current_setting('request.headers', true)::json ->> 'cf-connecting-ip',
    current_setting('request.headers', true)::json ->> 'x-forwarded-for',
    ''), ',', 1)), '')
$$;

create or replace function master_heartbeat(
  p_activity text, p_version text, p_platform text, p_device text, p_geo jsonb default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_activity text := case when p_activity in ('online', 'job', 'stream') then p_activity else 'online' end;
begin
  if v_uid is null or not exists (select 1 from masters where id = v_uid) then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  insert into master_presence as p (master_id, last_seen, activity, app_version, platform, device, ip, country, city)
  values (v_uid, now(), v_activity, left(p_version, 40), left(p_platform, 20), left(p_device, 120), request_ip(),
          left(p_geo ->> 'country', 80), left(p_geo ->> 'city', 80))
  on conflict (master_id) do update set
    last_seen = now(),
    activity = excluded.activity,
    app_version = coalesce(excluded.app_version, p.app_version),
    platform = coalesce(excluded.platform, p.platform),
    device = coalesce(excluded.device, p.device),
    ip = coalesce(excluded.ip, p.ip),
    country = coalesce(excluded.country, p.country),
    city = coalesce(excluded.city, p.city);
end $$;

create or replace function master_login_event(
  p_version text, p_platform text, p_device text, p_geo jsonb default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_ip text := request_ip();
begin
  if v_uid is null or not exists (select 1 from masters where id = v_uid) then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  -- Защита от засорения: не чаще раза в минуту с одного IP.
  if exists (select 1 from login_events where master_id = v_uid and ip is not distinct from v_ip
             and created_at > now() - interval '1 minute') then
    return;
  end if;
  insert into login_events (master_id, ip, geo_ip, country, city, app_version, platform, device)
  values (v_uid, v_ip, left(p_geo ->> 'ip', 60), left(p_geo ->> 'country', 80), left(p_geo ->> 'city', 80),
          left(p_version, 40), left(p_platform, 20), left(p_device, 120));
  -- Хранится история за 180 дней.
  delete from login_events where master_id = v_uid and created_at < now() - interval '180 days';
  perform master_heartbeat('online', p_version, p_platform, p_device, p_geo);
end $$;

revoke execute on function master_heartbeat(text, text, text, text, jsonb) from public, anon;
revoke execute on function master_login_event(text, text, text, jsonb) from public, anon;
revoke execute on function request_ip() from public, anon;
grant execute on function master_heartbeat(text, text, text, text, jsonb) to authenticated;
grant execute on function master_login_event(text, text, text, jsonb) to authenticated;

-- Админ видит изменения сразу (realtime).
do $$ begin
  alter publication supabase_realtime add table master_presence;
exception when duplicate_object then null; end $$;
