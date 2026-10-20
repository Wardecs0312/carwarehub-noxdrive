-- [7] Перевод приборной панели на русский.
-- Входит в пакет «Обычный доступ: русификация» (price_group complex): отдельно 0 кредитов,
-- оплачивается пакетом. По прайсу недоступен для Changan Q05, поэтому у Q05 услуга выключена.
-- Сценарий (помощник c281-polymeric-language-helper.jar, команда set ru) публикуется
-- tool/publish_package.dart --recipe clusterlang.

insert into services (code, title, description, price_credits, price_group, sort_order, allow_custom_apks)
values (
  'clusterlang',
  'Перевод приборной панели',
  'Переключает язык приборной панели на русский через штатную службу головного устройства',
  0,
  'complex',
  70,
  false
)
on conflict (code) do nothing;

insert into model_services (model_id, service_id, is_active)
select m.id, s.id, m.code <> 'q05'
  from car_models m
  cross join services s
 where s.code = 'clusterlang'
on conflict (model_id, service_id) do nothing;
