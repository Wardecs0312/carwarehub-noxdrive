-- Changan Q07: один пакет за 14 000 ₽ (14 кредитов), в нём все кнопки Q07 (решение Алишера 21.10.2026).
-- Пакет виден только у Q07; «Обычный доступ» и «Вывод приложений на приборную панель» у Q07 недоступны.

insert into price_groups (code, title, description, price_credits, price_rub, price_usd, items, na_models, sort_order, is_active)
values (
  'q07',
  'Changan Q07: полный пакет',
  'Русификация, установка приложений, голосовое управление, звук мотора, СГУ, ADB по Wi-Fi',
  14, 14000, 168,
  '[{"title":"Подготовка русификации"},{"title":"Русификация"},{"title":"Установка приложений"},{"title":"Голосовое управление"},{"title":"Звук мотора"},{"title":"СГУ"},{"title":"ADB по Wi-Fi"}]'::jsonb,
  '{q05,uni-z,cs75-pro,cs55-plus,uni-v}'::text[],
  30,
  true
)
on conflict (code) do nothing;

update price_groups
   set na_models = array_append(na_models, 'q07')
 where code in ('complex', 'cluster')
   and not ('q07' = any (na_models));

update services
   set price_group = 'q07', price_credits = 0
 where code in ('q07prep', 'q07ru', 'q07apps', 'q07voice', 'q07engine', 'q07sgu');

update model_services ms
   set is_active = true
  from car_models m, services s
 where ms.model_id = m.id and ms.service_id = s.id
   and m.code = 'q07' and s.code in ('q07engine', 'q07sgu');
