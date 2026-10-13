-- Прайс-лист: пакеты услуг с ценой в рублях и долларах, исключения по моделям.
-- Списание с баланса мастера в кредитах; рубли и доллары показываются для справки.
--   Обычный доступ (русификация: перевод системы, приложения, голос, системные приложения,
--     удаление китайских приложений): 4 кредита (4 000 ₽ / $48), списывается ОДИН раз на VIN
--     за первую услугу пакета, остальные услуги пакета на этот VIN бесплатны.
--   Доступ «Вывод приложений на приборную панель»: 2 кредита (2 000 ₽ / $23).
--   Changan Q05: перевод приборной панели и вывод приложений на приборную панель недоступны.
-- Скрипт можно запускать повторно.

create table if not exists price_groups (
  code text primary key,
  title text not null,
  description text,
  price_credits int not null default 0 check (price_credits >= 0),
  price_rub int not null check (price_rub >= 0),
  price_usd int not null check (price_usd >= 0),
  -- состав для карточки цены: [{"title": "...", "na_models": ["q05"]}]
  items jsonb not null default '[]'::jsonb,
  -- модели, где вся группа недоступна
  na_models text[] not null default '{}',
  sort_order int not null default 100,
  is_active boolean not null default true
);
alter table price_groups enable row level security;
drop policy if exists price_groups_read on price_groups;
create policy price_groups_read on price_groups for select to authenticated using (is_active);
drop policy if exists price_groups_admin on price_groups;
create policy price_groups_admin on price_groups for all to authenticated
  using (nox_is_admin()) with check (nox_is_admin());

alter table services add column if not exists price_group text references price_groups(code);

alter table price_groups add column if not exists price_credits int not null default 0;

insert into price_groups (code, title, description, price_credits, price_rub, price_usd, items, na_models, sort_order) values
  ('complex', 'Обычный доступ: русификация',
   'Разблокировка ADB, полный перевод системы, установка приложений, перевод приборной панели, голосовой ассистент',
   4, 4000, 48,
   '[{"title":"Разблокировка ADB"},{"title":"Полный перевод системы"},{"title":"Установка приложений"},
     {"title":"Перевод приборной панели","na_models":["q05"]},{"title":"Голосовой ассистент"}]'::jsonb,
   '{}', 10),
  ('cluster', 'Вывод приложений на приборную панель',
   'Отдельный доступ',
   2, 2000, 23,
   '[{"title":"Вывод приложений на приборную панель"}]'::jsonb,
   '{q05}', 20)
on conflict (code) do update set
  title = excluded.title, description = excluded.description, price_credits = excluded.price_credits,
  price_rub = excluded.price_rub, price_usd = excluded.price_usd,
  items = excluded.items, na_models = excluded.na_models, sort_order = excluded.sort_order;

update services set price_group = 'complex' where code in ('russify', 'voice', 'sysapps', 'debloat');
update services set price_group = 'cluster' where code = 'cluster';
update services set price_group = null, price_credits = 0 where code = 'reboot';

-- Q05: услуга вывода на приборную панель скрыта для этой модели.
update model_services ms set is_active = false
  from car_models m, services s
 where ms.model_id = m.id and ms.service_id = s.id and m.code = 'q05' and s.code = 'cluster';

-- Цена услуги для VIN и модели: цена группы (один раз на VIN за всю группу) или собственная цена услуги.
create or replace function service_charge(p_vin text, p_service_id int, p_model_id int)
returns table (price int, repeat boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  v_own int;
  v_group price_groups;
  v_model text;
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
    repeat := exists (
      select 1 from activations a join services s on s.id = a.service_id
      where a.vin = p_vin and s.price_group = v_group.code and a.status in ('success', 'running'));
    price := case when repeat then 0 else v_group.price_credits end;
  else
    repeat := exists (select 1 from activations
                      where vin = p_vin and service_id = p_service_id and status = 'success');
    price := case when repeat then 0 else v_own end;
  end if;
  return next;
end $$;
revoke all on function service_charge from public;

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

  select c.price, c.repeat into v_price, v_repeat from service_charge(v_vin, p_service_id, p_model_id) c;

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

  select c.price, c.repeat into v_price, v_repeat from service_charge(v_vin, p_service_id, p_model_id) c;

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

revoke all on function scenario_preview from public;
grant execute on function scenario_preview to authenticated;
