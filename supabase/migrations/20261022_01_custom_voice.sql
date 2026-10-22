-- [2б] Выбор голоса в кнопке «Установка голосового управления» (22.10.2026, решение Алишера):
--   штатный голос (voice)                  — бесплатно, входит в пакет «Обычный доступ»;
--   кастомный голос MMVoice (voicecustom)  — 2 кредита (800 ₽), отдельная строка прайса.
-- Мастер нажимает кнопку, выбирает вариант, затем подтверждает загрузку.
-- Что voicecustom — вариант кнопки voice, знает программа (lib/data/models.dart, serviceVariantOf):
-- отдельной карточкой она его не рисует.
-- model_services создаются ВЫКЛЮЧЕННЫМИ на тех же моделях, что штатный голос: старые версии программы
-- (до 2.0.34) показали бы кастомный голос лишней карточкой. Строка прайса тоже выключена (иначе её
-- увидят в карточке цен раньше времени). Включать после выпуска 2.0.34:
--   update price_groups set is_active = true where code = 'voicecustom';
--   update model_services set is_active = true
--    where service_id = (select id from services where code = 'voicecustom')
--      and model_id in (select model_id from model_services
--                        where service_id = (select id from services where code = 'voice') and is_active);
-- Сценарий: tool/publish_package.dart --recipe voicecustom --source MMVOICE_2026.zip.
-- Только новые строки, данные не меняются. Скрипт можно запускать повторно.

insert into price_groups (code, title, description, price_credits, price_rub, price_usd, items, na_models, sort_order,
                          is_active)
values ('voicecustom', 'Кастомный голос MMVoice', 'Отдельная активация', 2, 800, 10,
        '[{"title":"Кастомный голосовой помощник MMVoice"}]'::jsonb, '{}', 15, false)
on conflict (code) do nothing;

insert into services (code, title, description, price_credits, price_group, sort_order, allow_custom_apks)
values ('voicecustom', 'Установка кастомного голоса',
        'Голосовой помощник MMVoice: выбор помощником по умолчанию и кнопка голоса на руле',
        2, 'voicecustom', 25, false)
on conflict (code) do nothing;

insert into model_services (model_id, service_id, is_active)
select ms.model_id, c.id, false
  from model_services ms
  join services v on v.id = ms.service_id and v.code = 'voice'
  cross join services c
 where c.code = 'voicecustom'
on conflict (model_id, service_id) do nothing;
