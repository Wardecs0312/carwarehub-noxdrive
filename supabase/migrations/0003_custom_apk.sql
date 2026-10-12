-- Услуги установки, для которых мастер может добавить свои APK, и предпросмотр основного пакета.

alter table services add column if not exists allow_custom_apks boolean not null default false;
update services set allow_custom_apks = true where code in ('russify', 'voice', 'sysapps');

-- Предпросмотр основного пакета для окна «Настройка пакета установки».
-- Возвращает только названия шагов, цену и признак бесплатного повтора. Файлы и ключи не раскрываются.
create function scenario_preview(
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

  select coalesce(ms.price_override, s.price_credits) into v_price
  from model_services ms join services s on s.id = ms.service_id
  where ms.model_id = p_model_id and ms.service_id = p_service_id and ms.is_active and s.is_active;
  if v_price is null then raise exception 'SERVICE_UNAVAILABLE'; end if;

  select sc.* into v_scenario
  from scenarios sc join firmwares f on f.id = sc.firmware_id
  where sc.service_id = p_service_id and f.model_id = p_model_id
    and sc.is_active and f.is_active
    and coalesce(p_device->>'build', '') like f.version_pattern
  order by sc.version desc limit 1;
  if v_scenario.id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;

  v_repeat := exists (select 1 from activations
                      where vin = v_vin and service_id = p_service_id and status = 'success');

  return jsonb_build_object(
    'price', case when v_repeat then 0 else v_price end,
    'repeat', v_repeat,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('type', e.step->>'type', 'title', e.step->>'title') order by e.ord)
      from jsonb_array_elements(v_scenario.steps) with ordinality as e(step, ord)
    ), '[]'::jsonb)
  );
end $$;

revoke all on function scenario_preview from public;
grant execute on function scenario_preview to authenticated;
