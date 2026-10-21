-- Q07: кнопки 7 «Открыть ADB по Wi-Fi» и 8 «Закрыть ADB по Wi-Fi» (пакет q07).
-- Шаг adb_host выполняется на компьютере мастера (программа 2.0.31+, белый список: tcpip 5555, usb).
insert into services (code, title, description, price_credits, price_group, sort_order, allow_custom_apks) values
  ('q07adbon', 'Открыть ADB по Wi-Fi', 'Q07: adb по сети, порт 5555. Пока открыт, к машине может подключиться любой в той же Wi-Fi-сети — после работы закройте.', 0, 'q07', 70, false),
  ('q07adboff', 'Закрыть ADB по Wi-Fi', 'Q07: вернуть adb только на USB', 0, 'q07', 80, false)
on conflict (code) do nothing;

insert into model_services (model_id, service_id, is_active)
select m.id, s.id, true from car_models m cross join services s
 where m.code = 'q07' and s.code in ('q07adbon', 'q07adboff')
on conflict (model_id, service_id) do nothing;

insert into scenarios (service_id, firmware_id, version, steps, min_app_version, is_active)
select s.id, f.id, 1, x.steps, '2.0.31', true
  from (values
    ('q07adbon', '[{"type":"shell","title":"Адрес машины в Wi-Fi","cmd":"ip -f inet addr show 2>/dev/null | grep ''inet '' | grep -v '' 127\.''","ignore_errors":true},{"type":"adb_host","title":"Открытие ADB по Wi-Fi (порт 5555)","args":["tcpip","5555"]}]'::jsonb),
    ('q07adboff', '[{"type":"adb_host","title":"Закрытие ADB по Wi-Fi","args":["usb"]}]'::jsonb)
  ) as x(code, steps)
  join services s on s.code = x.code
  join firmwares f on f.model_id = (select id from car_models where code = 'q07')
 where not exists (select 1 from scenarios y where y.service_id = s.id and y.firmware_id = f.id);
