-- Проверка перед установкой: ищем в проекте объекты с теми же именами, что создают миграции.
do $$
declare
  conflicts text;
begin
  select string_agg(kind || ' ' || name, ', ') into conflicts from (
    select 'таблица' as kind, c.relname::text as name
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = any (array[
        'admins','masters','balance_ledger','master_balance','brands','car_models','firmwares',
        'services','model_services','payloads','scenarios','app_releases','vehicles',
        'activation_requests','activation_codes','activations','refund_requests'])
    union all
    select 'функция', p.proname::text
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = any (array[
        'nox_is_admin','normalize_vin','start_job','finish_job','request_refund',
        'expire_stale_jobs','admin_topup','admin_decide_refund','scenario_preview'])
    union all
    select 'правило хранилища', policyname::text
      from pg_policies
      where schemaname = 'storage' and tablename = 'objects'
        and policyname in ('payloads_read_running_job','releases_read')
  ) x;
  if conflicts is not null then
    raise exception 'В проекте уже есть объекты с такими именами: %. Ничего не создано.', conflicts;
  end if;
end $$;
