-- Сценарии без файлов (из nox.bat): [3] удаление китайских приложений и [4] перезагрузка.
-- Остальные услуги публикуются утилитой tool/publish_package.dart, потому что требуют загрузки файлов.

-- Прошивка «любая» для каждой модели (version_pattern сравнивается как LIKE с ro.build.display.id)
insert into firmwares (model_id, version_pattern, notes)
select m.id, '%', 'любая прошивка' from car_models m
where not exists (select 1 from firmwares f where f.model_id = m.id and f.version_pattern = '%');

insert into scenarios (service_id, firmware_id, version, steps)
select s.id, f.id, 1,
  case s.code
    when 'debloat' then jsonb_build_array(jsonb_build_object(
      'type', 'uninstall',
      'title', 'Удаление китайских приложений',
      'packages', jsonb_build_array(
        'com.tinnove.scenemode',
        'com.tinnove.wecarnavi',
        'com.tinnove.wechatlink',
        'com.changan.appmarket',
        'com.tinnove.netease.music',
        'com.wtcl.electronicdirections',
        'com.wt.phonelink')))
    else jsonb_build_array(jsonb_build_object('type', 'reboot', 'title', 'Перезагрузка автомобиля'))
  end
from services s
join firmwares f on f.version_pattern = '%'
where s.code in ('debloat', 'reboot')
on conflict (service_id, firmware_id, version) do nothing;

-- Предпросмотр основного пакета: шаги с "hidden": true (технические, например передача каждого файла) не показываются.
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
      where not coalesce((e.step->>'hidden')::boolean, false)
    ), '[]'::jsonb)
  );
end $$;
