-- 1) Заранее скачивать файлы (как у батника — файлы уже на диске к приезду машины).
--    Файлы зашифрованы, ключи выдаются только в start_job, поэтому одобренному мастеру
--    можно отдавать зашифрованные файлы активных сценариев и без идущей услуги.
create or replace function can_read_payload(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from activations a
    join scenarios s on s.id = a.scenario_id
    join payloads p on p.storage_path = p_name
    where a.master_id = auth.uid()
      and a.status = 'running'
      and s.steps @> jsonb_build_array(jsonb_build_object('payload_id', p.id))
  ) or exists (
    select 1
    from masters m, payloads p, scenarios s
    where m.id = auth.uid() and m.status = 'active'
      and p.storage_path = p_name
      and s.is_active
      and s.steps @> jsonb_build_array(jsonb_build_object('payload_id', p.id))
  )
$$;

-- Пути файлов всех активных сценариев модели (без ключей) — для фоновой загрузки.
create or replace function payloads_for_model(p_model int) returns setof text
language sql stable security definer set search_path = public as $$
  select distinct p.storage_path
  from masters m, scenarios s
  join firmwares f on f.id = s.firmware_id and f.is_active
  cross join lateral jsonb_array_elements(s.steps) e
  join payloads p on p.id::text = e->>'payload_id'
  where m.id = auth.uid() and m.status = 'active'
    and s.is_active and f.model_id = p_model
$$;
revoke all on function payloads_for_model(int) from public, anon;
grant execute on function payloads_for_model(int) to authenticated;

-- 2) «Задание живо»: программа отмечается каждые 30 секунд во время услуги.
alter table activations add column if not exists heartbeat_at timestamptz;

create or replace function job_heartbeat(p_job uuid) returns void
language sql security definer set search_path = public as $$
  update activations set heartbeat_at = now()
  where id = p_job and master_id = auth.uid() and status = 'running'
$$;
revoke all on function job_heartbeat(uuid) from public, anon;
grant execute on function job_heartbeat(uuid) to authenticated;

-- Задание с отметками снимается, если отметок нет 5 минут (программу закрыли посреди услуги).
-- Задание старой версии программы (без отметок) — по прежнему правилу.
create or replace function expire_stale_jobs() returns void
language sql security definer set search_path = public as $$
  update activations a set status = 'failed', finished_at = now(), log = coalesce(a.log, 'timeout')
  where a.status = 'running'
    and (a.created_at < now() - interval '3 hours'
         or (a.heartbeat_at is not null and a.heartbeat_at < now() - interval '5 minutes')
         or (a.heartbeat_at is null and a.created_at < now() - interval '30 minutes'
             and not exists (select 1 from master_presence p
                             where p.master_id = a.master_id
                               and p.last_seen > now() - interval '5 minutes')));

  update stream_sessions s set status = 'ended', ended_at = now()
  where s.status in ('requested', 'live')
    and ((s.status = 'requested' and s.created_at < now() - interval '10 minutes')
         or (s.created_at < now() - interval '3 minutes'
             and not exists (select 1 from master_presence p
                             where p.master_id = s.master_id
                               and p.last_seen > now() - interval '3 minutes')));
$$;
revoke all on function expire_stale_jobs() from public, anon, authenticated;
