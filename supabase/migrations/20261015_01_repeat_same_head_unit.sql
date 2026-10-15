-- Бесплатный повтор услуги только для той же машины (аудит 13.10.2026, пункт B-2).
--
-- Было: повтор считался по одному VIN, который мастер вводит руками. Оплатив пакет на любой VIN,
-- можно было вводить этот же VIN на других машинах и получать услуги бесплатно (и любой другой мастер тоже).
-- Стало: повтор бесплатный, только если совпали VIN и головное устройство (его заводской серийный номер).
--   та же машина, переустановка после сбоя  -> бесплатно
--   та же машина, другой мастер              -> бесплатно (машина уже оплачена)
--   другая машина с тем же VIN               -> платно
--
-- Серийный номер ГУ: device_info.hu_serial (программа 2.0.14+, getprop ro.serialno). Для старых версий
-- берётся device_info.serial от adb, если это USB-номер, а не адрес «IP:порт» сетевого подключения.
-- Нет номера -> повтор платный (обманом его не получить).
-- Особые цены мастеров (master_prices, миграция 0011) учитываются, если таблица уже есть.
-- Данные не меняются. Скрипт можно запускать повторно.

create or replace function head_unit_id(p_device jsonb) returns text
language sql immutable as $$
  select coalesce(
    nullif(btrim(p_device->>'hu_serial'), ''),
    case when coalesce(p_device->>'serial', '') !~ '[:.]'
         then nullif(btrim(p_device->>'serial'), '') end)
$$;

create or replace function service_charge(p_vin text, p_service_id int, p_model_id int, p_hu text)
returns table (price int, repeat boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  v_own int;
  v_group price_groups;
  v_model text;
  v_special int;
begin
  select coalesce(ms.price_override, s.price_credits) into v_own
  from model_services ms join services s on s.id = ms.service_id
  where ms.model_id = p_model_id and ms.service_id = p_service_id and ms.is_active and s.is_active;
  if v_own is null then raise exception 'SERVICE_UNAVAILABLE'; end if;

  select g.* into v_group from services s join price_groups g on g.code = s.price_group and g.is_active
  where s.id = p_service_id;
  select code into v_model from car_models where id = p_model_id;

  if v_group.code is not null then
    if v_model = any (v_group.na_models) then raise exception 'SERVICE_UNAVAILABLE'; end if;
    if to_regclass('public.master_prices') is not null then
      execute 'select price_credits from master_prices where master_id = $1 and group_code = $2'
        into v_special using auth.uid(), v_group.code;
    end if;
    repeat := p_hu is not null and exists (
      select 1 from activations a join services s on s.id = a.service_id
      where a.vin = p_vin and s.price_group = v_group.code and a.status in ('success', 'running')
        and head_unit_id(a.device_info) = p_hu);
    price := case when repeat then 0 else coalesce(v_special, v_group.price_credits) end;
  else
    repeat := p_hu is not null and exists (
      select 1 from activations a
      where a.vin = p_vin and a.service_id = p_service_id and a.status = 'success'
        and head_unit_id(a.device_info) = p_hu);
    price := case when repeat then 0 else v_own end;
  end if;
  return next;
end $$;

-- Старый вариант без устройства: бесплатного повтора больше не даёт (на случай, если его кто-то вызывает).
create or replace function service_charge(p_vin text, p_service_id int, p_model_id int)
returns table (price int, repeat boolean)
language sql stable security definer set search_path = public as $$
  select * from service_charge(p_vin, p_service_id, p_model_id, null::text)
$$;

create or replace function start_job(
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

  select c.price, c.repeat into v_price, v_repeat
  from service_charge(v_vin, p_service_id, p_model_id, head_unit_id(p_device)) c;

  select sc.* into v_scenario
  from scenarios sc join firmwares f on f.id = sc.firmware_id
  where sc.service_id = p_service_id and f.model_id = p_model_id
    and sc.is_active and f.is_active
    and coalesce(p_device->>'build', '') like f.version_pattern
  order by sc.version desc limit 1;
  if v_scenario.id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;

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

create or replace function scenario_preview(
  p_vin text, p_service_id int, p_model_id int, p_device jsonb
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_vin text := normalize_vin(p_vin);
  v_price int;
  v_scenario scenarios;
  v_repeat boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  select c.price, c.repeat into v_price, v_repeat
  from service_charge(v_vin, p_service_id, p_model_id, head_unit_id(p_device)) c;

  select sc.* into v_scenario
  from scenarios sc join firmwares f on f.id = sc.firmware_id
  where sc.service_id = p_service_id and f.model_id = p_model_id
    and sc.is_active and f.is_active
    and coalesce(p_device->>'build', '') like f.version_pattern
  order by sc.version desc limit 1;
  if v_scenario.id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;

  return jsonb_build_object(
    'price', v_price,
    'repeat', v_repeat,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('type', e.step->>'type', 'title', e.step->>'title') order by e.ord)
      from jsonb_array_elements(v_scenario.steps) with ordinality as e(step, ord)
      where not coalesce((e.step->>'hidden')::boolean, false)
    ), '[]'::jsonb)
  );
end $$;

-- Права: только вошедшие пользователи (Supabase по умолчанию даёт новым функциям право anon).
revoke all on function head_unit_id(jsonb) from public, anon;
revoke all on function service_charge(text, int, int, text) from public, anon;
revoke all on function service_charge(text, int, int) from public, anon;
revoke all on function start_job(text, int, int, text, jsonb) from public, anon;
revoke all on function scenario_preview(text, int, int, jsonb) from public, anon;
grant execute on function head_unit_id(jsonb) to authenticated, service_role;
grant execute on function service_charge(text, int, int, text) to authenticated, service_role;
grant execute on function service_charge(text, int, int) to authenticated, service_role;
grant execute on function start_job(text, int, int, text, jsonb) to authenticated, service_role;
grant execute on function scenario_preview(text, int, int, jsonb) to authenticated, service_role;
