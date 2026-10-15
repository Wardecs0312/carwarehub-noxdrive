-- Диагностика трансляции: какой источник (экран ГУ, экран ноутбука, камера) не запустился у мастера и почему.
-- Программа мастера сообщает причины, админ видит их в окне трансляции. Только новый столбец и функция.
alter table stream_sessions add column if not exists source_errors jsonb;

create or replace function master_stream_report(p_id uuid, p_errors jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if jsonb_typeof(coalesce(p_errors, '{}'::jsonb)) <> 'object' or length(p_errors::text) > 4000 then
    raise exception 'BAD_ERRORS';
  end if;
  update stream_sessions set source_errors = nullif(p_errors, '{}'::jsonb)
   where id = p_id and master_id = auth.uid();
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;
revoke all on function master_stream_report(uuid, jsonb) from public, anon;
grant execute on function master_stream_report(uuid, jsonb) to authenticated, service_role;
