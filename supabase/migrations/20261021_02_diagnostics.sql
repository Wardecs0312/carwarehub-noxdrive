-- Диагностика (только чтение): программа мастера по кнопке читает сведения о ГУ через ADB
-- и присылает отчёт сюда. Мастер может только добавить свой отчёт, читает — только админ
-- (и сервисный ключ для удалённого разбора).

create table if not exists diagnostics (
  id uuid primary key default gen_random_uuid(),
  master_id uuid not null default auth.uid() references masters on delete cascade,
  created_at timestamptz not null default now(),
  vin text check (vin is null or char_length(vin) <= 17),
  model text check (model is null or char_length(model) <= 120),
  app_version text check (app_version is null or char_length(app_version) <= 40),
  payload jsonb not null check (pg_column_size(payload) <= 1000000)
);
create index if not exists diagnostics_master_idx on diagnostics (master_id, created_at desc);
create index if not exists diagnostics_created_idx on diagnostics (created_at desc);

alter table diagnostics enable row level security;

-- Сколько отчётов мастер прислал за сутки. security definer: сам мастер чужие и свои
-- отчёты читать не может, поэтому подсчёт в политике без функции всегда давал бы 0.
create or replace function diagnostics_today_count() returns bigint
language sql stable security definer set search_path = public as $$
  select count(*) from diagnostics
  where master_id = auth.uid() and created_at > now() - interval '1 day'
$$;
revoke execute on function diagnostics_today_count() from public, anon;
grant execute on function diagnostics_today_count() to authenticated;

drop policy if exists diagnostics_insert_own on diagnostics;
create policy diagnostics_insert_own on diagnostics for insert to authenticated
  with check (
    master_id = auth.uid()
    and exists (select 1 from masters where id = auth.uid())
    -- защита от засорения: не больше 30 отчётов в сутки с одного аккаунта
    and diagnostics_today_count() < 30
  );

drop policy if exists diagnostics_admin_read on diagnostics;
create policy diagnostics_admin_read on diagnostics for select to authenticated
  using (nox_is_admin());

drop policy if exists diagnostics_admin_delete on diagnostics;
create policy diagnostics_admin_delete on diagnostics for delete to authenticated
  using (nox_is_admin());

revoke all on diagnostics from anon;
revoke all on diagnostics from authenticated;
grant insert (vin, model, app_version, payload) on diagnostics to authenticated;
grant select, delete on diagnostics to authenticated;
