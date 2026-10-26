-- Услуга «Установить RuStore» на всех моделях. Бесплатная и вне пакетов (price_group пусто,
-- как «Перезагрузка»): цену можно назначить позже. После установки мастер выдаёт RuStore
-- разрешение ставить приложения командой appops (кнопка «Патч для RuStore» в программе).
-- Сценарий: tool/publish_package.dart --recipe rustore (Q07 — без --prep, --models q07).

insert into services (code, title, description, price_credits, price_group, sort_order, allow_custom_apks)
values (
  'rustore',
  'Установить RuStore',
  'Магазин приложений RuStore',
  0,
  null,
  55,
  false
)
on conflict (code) do nothing;

insert into model_services (model_id, service_id, is_active)
select m.id, s.id, true
  from car_models m
  cross join services s
 where s.code = 'rustore'
on conflict (model_id, service_id) do nothing;

-- «Перезагрузка автомобиля» — последней в списке услуг.
update services set sort_order = 1000 where code = 'reboot';
