-- Changan Q07 (Android Automotive, платформа SDA): свой набор услуг.
-- Модель создаётся СКРЫТОЙ (is_active = false): включить после утверждения цен Алишером.
-- Кнопки:
--   1 q07prep   «Подготовка русификации»  = пункт 1 FunkyDev Q07 Language Tool (Install_Final_Overlays.bat)
--   2 q07ru     «Русификация»             = пункт 2 (Enable_Final_Overlays.bat) + перезагрузка
--   3 q07apps   «Установить приложения»   = свои APK мастера
--   5 q07engine «Установить звук мотора»  = Q07_Engine_Sound.apk (az.q07.enginesound)
--   6 q07sgu    «Установить СГУ»          = приложение «Громкоговоритель» (com.nox.speaker)
-- Кнопки 4 (голосовое управление из облака) и 7 (ADB по Wi-Fi) ждут файлы и доработку программы.
-- Сценарии публикуются tool/publish_package.dart --recipe q07prep|q07ru|q07engine|q07sgu --models q07.
-- Цены: 1–3 входят в пакет «Обычный доступ» (complex), 5 и 6 пока 0 — утвердить до включения модели.

insert into car_models (brand_id, code, title, is_active, sort_order)
select b.id, 'q07', 'Changan Q07', false, 60 from brands b where b.code = 'changan'
on conflict (code) do nothing;

insert into firmwares (model_id, version_pattern, notes)
select m.id, '%', 'любая прошивка'
  from car_models m
 where m.code = 'q07'
   and not exists (select 1 from firmwares f where f.model_id = m.id);

insert into services (code, title, description, price_credits, price_group, sort_order, allow_custom_apks)
values
  ('q07prep', 'Подготовка русификации', 'Q07: установка 36 файлов перевода и текстов DLP', 0, 'complex', 10, false),
  ('q07ru', 'Русификация', 'Q07: включение перевода для всех пользователей машины и перезагрузка', 0, 'complex', 20, false),
  ('q07apps', 'Установить приложения', 'Q07: установка APK, которые мастер выбирает сам', 0, 'complex', 30, true),
  ('q07engine', 'Установить звук мотора', 'Q07: приложение Q07 Engine Sound', 0, null, 50, false),
  ('q07sgu', 'Установить СГУ', 'Q07: приложение «Громкоговоритель» (фразы и звуки наружу)', 0, null, 60, false)
on conflict (code) do nothing;

insert into model_services (model_id, service_id, is_active)
select m.id, s.id, true
  from car_models m
  cross join services s
 where m.code = 'q07'
   and s.code in ('q07prep', 'q07ru', 'q07apps', 'q07engine', 'q07sgu', 'reboot')
on conflict (model_id, service_id) do nothing;

-- Перезагрузка (общая услуга) для прошивки Q07.
insert into scenarios (service_id, firmware_id, version, steps, is_active)
select s.id, f.id, 1, '[{"type": "reboot", "title": "Перезагрузка автомобиля"}]'::jsonb, true
  from services s
  join firmwares f on f.model_id = (select id from car_models where code = 'q07')
 where s.code = 'reboot'
   and not exists (select 1 from scenarios x where x.service_id = s.id and x.firmware_id = f.id);

-- «Установить приложения»: основной шаг только подготовка, дальше свои APK мастера.
insert into scenarios (service_id, firmware_id, version, steps, is_active)
select s.id, f.id, 1,
       '[{"type": "shell", "title": "Подготовка системы", "cmd": "setprop vecentek.model 1", "hidden": true}]'::jsonb,
       true
  from services s
  join firmwares f on f.model_id = (select id from car_models where code = 'q07')
 where s.code = 'q07apps'
   and not exists (select 1 from scenarios x where x.service_id = s.id and x.firmware_id = f.id);
