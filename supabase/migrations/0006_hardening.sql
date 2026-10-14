-- Исправления безопасности по аудиту, сверено с боевой базой (is_admin(), nox_is_admin(), price_groups и др.).
-- Данные не удаляются и не меняются: только политики, индекс, функции и расписание.

-- 1. users: чтение было открыто всем (политика для роли public с условием true). Оставляем свою строку и админа.
drop policy if exists "Allow public read users" on users;
create policy users_admin_read on users for select to authenticated using (is_admin());

-- 2. Возвраты: заявку создаёт только request_refund (security definer), одну на задание.
drop policy if exists refund_insert on refund_requests;
create unique index if not exists refund_requests_one_per_activation on refund_requests (activation_id);

-- 3. Заявки на активацию создаются только в статусе pending.
drop policy if exists req_insert on activation_requests;
create policy req_insert on activation_requests for insert to authenticated
  with check (master_id = auth.uid() and status = 'pending');

-- 4. Установщик обновлений читают только активные мастера.
drop policy if exists releases_read on storage.objects;
create policy releases_read on storage.objects for select to authenticated
  using (bucket_id = 'releases' and exists (select 1 from public.masters m where m.id = auth.uid() and m.status = 'active'));

-- 5. admin_decide_refund: возврат только за проваленное платное задание.
create or replace function admin_decide_refund(p_refund_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r refund_requests; a activations;
begin
  if not is_admin() then raise exception 'FORBIDDEN'; end if;
  select * into r from refund_requests where id = p_refund_id and status = 'pending' for update;
  if r.id is null then raise exception 'REFUND_NOT_FOUND'; end if;
  select * into a from activations where id = r.activation_id for update;
  if p_approve and (a.status <> 'failed' or a.credits <= 0) then raise exception 'REFUND_NOT_ALLOWED'; end if;
  update refund_requests set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = auth.uid(), decided_at = now() where id = r.id;
  if p_approve then
    update master_balance set credits = credits + a.credits, updated_at = now() where master_id = a.master_id;
    insert into balance_ledger (master_id, amount, reason, activation_id, created_by)
    values (a.master_id, a.credits, 'refund', a.id, auth.uid());
  end if;
end $$;

-- 6. is_admin: фиксированный search_path.
alter function is_admin() set search_path = public;

-- 7. Анонимный доступ ко всем security definer функциям закрыт (в Supabase revoke from public его не снимает).
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p
           where p.pronamespace = 'public'::regnamespace and p.prosecdef loop
    execute format('revoke execute on function %s from anon', f.sig);
  end loop;
end $$;

-- 8. Зависшие задания закрываются автоматически раз в 5 минут.
create extension if not exists pg_cron;
select cron.schedule('nox-expire-stale-jobs', '*/5 * * * *', 'select public.expire_stale_jobs()');
