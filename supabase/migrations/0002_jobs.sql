-- Выполнение услуг: серверная проверка баланса и VIN, выдача шагов сценария,
-- доступ к зашифрованным файлам только на время выполнения задания.

alter table payloads add column if not exists enc_key text;   -- base64, 32 байта AES-256. Клиенту недоступен напрямую.

-- Приватные хранилища
insert into storage.buckets (id, name, public) values ('payloads', 'payloads', false) on conflict do nothing;
insert into storage.buckets (id, name, public) values ('releases', 'releases', false) on conflict do nothing;

-- Файл сценария можно скачать только в рамках своего активного задания (status = 'running').
create policy payloads_read_running_job on storage.objects for select to authenticated
using (
  bucket_id = 'payloads' and exists (
    select 1
    from activations a
    join scenarios s on s.id = a.scenario_id
    join payloads p on p.storage_path = storage.objects.name
    where a.master_id = auth.uid()
      and a.status = 'running'
      and s.steps @> jsonb_build_array(jsonb_build_object('payload_id', p.id))
  )
);

-- Установщик обновлений доступен любому вошедшему мастеру
create policy releases_read on storage.objects for select to authenticated
using (bucket_id = 'releases');

-- Нормализация VIN
create function normalize_vin(p_vin text) returns text language sql immutable as
$$ select upper(btrim(p_vin)) $$;

-- Старт задания. Возвращает job_id, цену и шаги с данными для скачивания и расшифровки.
create function start_job(
  p_vin text, p_service_id int, p_model_id int, p_app_version text, p_device jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  v_vin text := normalize_vin(p_vin);
  v_price int;
  v_scenario scenarios;
  v_job uuid;
  v_repeat boolean;
  v_balance int;
  v_steps jsonb;
begin
  if uid is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists (select 1 from masters where id = uid and status = 'active') then
    raise exception 'MASTER_BLOCKED';
  end if;
  if v_vin !~ '^[A-HJ-NPR-Z0-9]{17}$' then raise exception 'VIN_INVALID'; end if;

  select coalesce(ms.price_override, s.price_credits) into v_price
  from model_services ms join services s on s.id = ms.service_id
  where ms.model_id = p_model_id and ms.service_id = p_service_id and ms.is_active and s.is_active;
  if v_price is null then raise exception 'SERVICE_UNAVAILABLE'; end if;

  -- сценарий для прошивки ГУ (version_pattern сравнивается как LIKE с ro.build.display.id)
  select sc.* into v_scenario
  from scenarios sc join firmwares f on f.id = sc.firmware_id
  where sc.service_id = p_service_id and f.model_id = p_model_id
    and sc.is_active and f.is_active
    and coalesce(p_device->>'build', '') like f.version_pattern
  order by sc.version desc limit 1;
  if v_scenario.id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;

  -- повтор той же услуги на тот же VIN бесплатный
  v_repeat := exists (select 1 from activations
                      where vin = v_vin and service_id = p_service_id and status = 'success');
  if v_repeat then v_price := 0; end if;

  insert into master_balance (master_id) values (uid) on conflict do nothing;
  select credits into v_balance from master_balance where master_id = uid for update;
  if v_balance < v_price then raise exception 'INSUFFICIENT_BALANCE'; end if;

  insert into vehicles (vin, model_id, firmware_seen, first_seen_by)
  values (v_vin, p_model_id, p_device->>'build', uid) on conflict (vin) do nothing;

  insert into activations (master_id, vin, service_id, scenario_id, credits, app_version, device_info)
  values (uid, v_vin, p_service_id, v_scenario.id, v_price, p_app_version, p_device)
  returning id into v_job;

  if v_price > 0 then
    update master_balance set credits = credits - v_price, updated_at = now() where master_id = uid;
    insert into balance_ledger (master_id, amount, reason, activation_id)
    values (uid, -v_price, 'charge', v_job);
  end if;

  select coalesce(jsonb_agg(
           case when e.step ? 'payload_id' then
             e.step || jsonb_build_object(
               'storage_path', p.storage_path, 'size_bytes', p.size_bytes,
               'sha256', p.sha256, 'enc_key', p.enc_key, 'kind', p.kind)
           else e.step end
           order by e.ord), '[]'::jsonb)
  into v_steps
  from jsonb_array_elements(v_scenario.steps) with ordinality as e(step, ord)
  left join payloads p on e.step ? 'payload_id' and p.id = (e.step->>'payload_id')::uuid;

  return jsonb_build_object('job_id', v_job, 'price', v_price, 'repeat', v_repeat, 'steps', v_steps);
end $$;

-- Завершение задания. Автоматического возврата нет: при сбое мастер подаёт заявку, решает админ.
create function finish_job(p_job_id uuid, p_success boolean, p_log text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update activations
  set status = case when p_success then 'success' else 'failed' end,
      log = left(p_log, 20000), finished_at = now()
  where id = p_job_id and master_id = auth.uid() and status = 'running';
  if not found then raise exception 'JOB_NOT_FOUND'; end if;
end $$;

create function request_refund(p_activation_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from activations
                 where id = p_activation_id and master_id = auth.uid()
                   and status = 'failed' and credits > 0) then
    raise exception 'REFUND_NOT_ALLOWED';
  end if;
  insert into refund_requests (activation_id, master_id, reason)
  values (p_activation_id, auth.uid(), p_reason);
end $$;

-- Задания, зависшие в 'running' (закрыли программу, выдернули кабель), закрываются как failed.
create function expire_stale_jobs() returns void language sql security definer set search_path = public as $$
  update activations set status = 'failed', finished_at = now(), log = coalesce(log, 'timeout')
  where status = 'running' and created_at < now() - interval '30 minutes'
$$;

-- ---------- Админ ----------
create function admin_topup(p_master uuid, p_amount int, p_note text default 'topup') returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'FORBIDDEN'; end if;
  insert into master_balance (master_id, credits) values (p_master, 0) on conflict do nothing;
  update master_balance set credits = credits + p_amount, updated_at = now() where master_id = p_master;
  insert into balance_ledger (master_id, amount, reason, created_by) values (p_master, p_amount, p_note, auth.uid());
end $$;

create function admin_decide_refund(p_refund_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r refund_requests; a activations;
begin
  if not is_admin() then raise exception 'FORBIDDEN'; end if;
  select * into r from refund_requests where id = p_refund_id and status = 'pending' for update;
  if r.id is null then raise exception 'REFUND_NOT_FOUND'; end if;
  update refund_requests set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = auth.uid(), decided_at = now() where id = r.id;
  if p_approve then
    select * into a from activations where id = r.activation_id;
    update master_balance set credits = credits + a.credits, updated_at = now() where master_id = a.master_id;
    insert into balance_ledger (master_id, amount, reason, activation_id, created_by)
    values (a.master_id, a.credits, 'refund', a.id, auth.uid());
  end if;
end $$;

revoke all on function start_job, finish_job, request_refund, expire_stale_jobs, admin_topup, admin_decide_refund from public;
grant execute on function start_job, finish_job, request_refund, admin_topup, admin_decide_refund to authenticated;

-- Шаги сценария (steps) задаются админом в jsonb, поддерживаются типы:
--   {"type":"install_apk","title":"...","payload_id":"<uuid>"}   APK потоком в память ГУ
--   {"type":"run_script","title":"...","payload_id":"<uuid>"}    sh-скрипт потоком в stdin
--   {"type":"shell","title":"...","cmd":"settings put ..."}      короткая команда
--   {"type":"uninstall","title":"...","packages":["com.a","com.b"]}
--   {"type":"reboot","title":"..."}
