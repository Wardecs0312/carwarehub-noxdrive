-- Отдельная услуга «Патч для RuStore» на всех моделях: RuStore получает разрешение ставить
-- приложения (раньше мастера вводили в cmd `adb shell appops set ru.vk.store
-- REQUEST_INSTALL_PACKAGES allow`). Вторая команда проверяет, что разрешение включилось:
-- иначе grep вернёт ошибку и услуга упадёт. Бесплатно, вне пакетов, сразу после RuStore.
insert into services (code, title, description, price_credits, price_group, sort_order, allow_custom_apks)
values ('rustorepatch', 'Патч для RuStore', 'Разрешает RuStore устанавливать приложения', 0, null, 56, false)
on conflict (code) do nothing;

insert into model_services (model_id, service_id, is_active)
select m.id, s.id, true from car_models m cross join services s
 where s.code = 'rustorepatch'
on conflict (model_id, service_id) do nothing;

insert into scenarios (service_id, firmware_id, version, steps, is_active)
select s.id, f.id, 1,
       '[{"type":"shell","title":"Патч для RuStore","cmd":"appops set ru.vk.store REQUEST_INSTALL_PACKAGES allow && appops get ru.vk.store REQUEST_INSTALL_PACKAGES | grep allow"}]'::jsonb,
       true
  from services s cross join firmwares f
 where s.code = 'rustorepatch'
   and not exists (select 1 from scenarios y where y.service_id = s.id and y.firmware_id = f.id);
