-- Трансляции для администратора (docs/STREAMING.md): экран ноутбука мастера, экран ГУ, камера.
-- Видео идёт через LiveKit; здесь только запросы, статусы и журнал.

-- Базы, поставленные до переименования is_admin -> nox_is_admin, получают новое имя
-- (на свежей базе функция уже есть и просто перезаписывается тем же телом).
create or replace function nox_is_admin() returns boolean language sql stable security definer
set search_path = public as
$$ select exists (select 1 from admins where user_id = auth.uid()) $$;

-- Согласие мастера на трансляции (галочка при первом входе).
alter table masters add column if not exists stream_consent_at timestamptz;

create table if not exists stream_sessions (
  id uuid primary key default gen_random_uuid(),
  master_id uuid not null references masters on delete cascade,
  requested_by uuid not null references auth.users,
  sources text[] not null check (sources <@ array['screen-laptop','screen-hu','camera']::text[] and cardinality(sources) > 0),
  status text not null default 'requested' check (status in ('requested','live','ended')),
  created_at timestamptz not null default now(),
  started_at timestamptz,
  ended_at timestamptz
);
create index if not exists stream_sessions_open on stream_sessions (master_id) where status <> 'ended';

alter table stream_sessions enable row level security;

-- Админ: всё. Мастер: видит свои запросы (чтобы показать плашку), статус меняет только через функцию ниже.
drop policy if exists stream_admin on stream_sessions;
drop policy if exists stream_master_read on stream_sessions;
create policy stream_admin on stream_sessions for all to authenticated
  using (nox_is_admin()) with check (nox_is_admin());
create policy stream_master_read on stream_sessions for select to authenticated
  using (master_id = auth.uid());

-- Мастер меняет статус только через эту функцию: live (начал) или ended (остановил сам).
create or replace function master_stream_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('live','ended') then raise exception 'BAD_STATUS'; end if;
  update stream_sessions
     set status = p_status,
         started_at = case when p_status = 'live' then coalesce(started_at, now()) else started_at end,
         ended_at = case when p_status = 'ended' then now() else ended_at end
   where id = p_id and master_id = auth.uid() and status <> 'ended';
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

-- Согласие мастера (один раз; дальше трансляции идут с плашкой без повторного вопроса).
create or replace function master_stream_consent() returns void
language sql security definer set search_path = public as $$
  update masters set stream_consent_at = coalesce(stream_consent_at, now()) where id = auth.uid();
$$;

-- Запросы приходят в приложение мастера мгновенно (Supabase Realtime).
do $$ begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and tablename = 'stream_sessions') then
    alter publication supabase_realtime add table stream_sessions;
  end if;
end $$;
