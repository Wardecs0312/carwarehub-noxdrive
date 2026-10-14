-- Исправления по аудиту. Данные не удаляются и не меняются, только функции, политики и индексы.

-- 1. Скачивание файлов услуги. Раньше правило хранилища читало payloads и scenarios напрямую,
--    но на этих таблицах включён RLS без политик, поэтому проверка всегда проваливалась (404 Object not found).
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

-- 2. Установщик обновлений читают только активные мастера, а не любой зарегистрированный пользователь.
drop policy if exists releases_read on storage.objects;
create policy releases_read on storage.objects for select to authenticated
using (
  bucket_id = 'releases'
  and exists (select 1 from public.masters m where m.id = auth.uid() and m.status = 'active')
);

-- 3. Возвраты: заявку можно создать только через request_refund, и только одну на задание.
drop policy if exists refund_insert on refund_requests;
create unique index if not exists refund_requests_one_per_activation
  on refund_requests (activation_id);

create or replace function admin_decide_refund(p_refund_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r refund_requests; a activations;
begin
  if not nox_is_admin() then raise exception 'FORBIDDEN'; end if;
  select * into r from refund_requests where id = p_refund_id and status = 'pending' for update;
  if r.id is null then raise exception 'REFUND_NOT_FOUND'; end if;
  select * into a from activations where id = r.activation_id for update;
  if a.status <> 'failed' or a.credits <= 0 then raise exception 'REFUND_NOT_ALLOWED'; end if;
  update refund_requests set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = auth.uid(), decided_at = now() where id = r.id;
  if p_approve then
    update master_balance set credits = credits + a.credits, updated_at = now() where master_id = a.master_id;
    insert into balance_ledger (master_id, amount, reason, activation_id, created_by)
    values (a.master_id, a.credits, 'refund', a.id, auth.uid());
  end if;
end $$;

-- 4. Заявки на активацию создаются только в статусе pending.
drop policy if exists req_insert on activation_requests;
create policy req_insert on activation_requests for insert to authenticated
with check (master_id = auth.uid() and status = 'pending');

-- 5. nox_is_admin: фиксированный search_path.
create or replace function nox_is_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from admins where user_id = auth.uid()) $$;

-- 6. Анонимный доступ к функциям закрыт явно (в Supabase revoke from public его не снимает).
revoke all on function start_job, finish_job, request_refund, expire_stale_jobs,
  admin_topup, admin_decide_refund, scenario_preview, nox_is_admin, normalize_vin from anon;
revoke all on function expire_stale_jobs from authenticated;

-- 7. Зависшие задания закрываются автоматически раз в 5 минут (нужно расширение pg_cron).
create extension if not exists pg_cron;
select cron.schedule('nox-expire-stale-jobs', '*/5 * * * *', $$select public.expire_stale_jobs()$$);
