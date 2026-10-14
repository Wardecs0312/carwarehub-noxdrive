-- Исправление ошибки «StorageException: Object not found, 404» при скачивании файлов услуги.
-- Причина: правило хранилища читало payloads и scenarios напрямую, а на этих таблицах включён RLS без политик,
-- поэтому для мастера они пусты и проверка всегда проваливалась. Теперь проверка идёт через функцию security definer.
-- Данные не затрагиваются.

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
  )
$$;
revoke all on function can_read_payload(text) from public, anon;
grant execute on function can_read_payload(text) to authenticated;

drop policy if exists payloads_read_running_job on storage.objects;
create policy payloads_read_running_job on storage.objects for select to authenticated
using (bucket_id = 'payloads' and can_read_payload(name));
