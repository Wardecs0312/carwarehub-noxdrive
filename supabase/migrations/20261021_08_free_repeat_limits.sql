-- Бесплатный повтор: только тому же мастеру и не больше 3 раз на услугу за 30 дней
-- (проверка защиты 20.10.2026, пункт 2).
--
-- Было: повтор бесплатный, если на этот VIN уже была услуга (пакет) с тем же серийником ГУ.
-- VIN и серийник присылает программа, сервер их проверить не может: подделанная программа выдавала бы
-- каждую новую машину за уже обслуженную (в том числе чужую) и не платила бы никогда.
-- Стало:
--   тот же мастер, та же машина, повтор после сбоя         -> бесплатно (до 3 раз на услугу за 30 дней)
--   другие услуги того же пакета на этой машине            -> бесплатно (первый раз каждая)
--   другой мастер на уже обслуженной машине                -> платно
--   четвёртый бесплатный повтор одной услуги за 30 дней     -> платно
-- Перед применением сверить с боевой service_charge(text,int,int,text): эта версия = 20261015_01 + условия ниже.
-- Данные не меняются. Скрипт можно запускать повторно.

create or replace function service_charge(p_vin text, p_service_id int, p_model_id int, p_hu text)
returns table (price int, repeat boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  v_own int;
  v_group price_groups;
  v_model text;
  v_special int;
  v_uid uuid := auth.uid();
  -- Сколько раз мастер уже получил эту услугу на этом VIN бесплатно за 30 дней.
  v_free_used int := (
    select count(*) from activations a
    where a.vin = p_vin and a.service_id = p_service_id and a.master_id = v_uid
      and a.credits = 0 and a.created_at > now() - interval '30 days');
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
    if to_regclass('public.master_prices') is not null then
      execute 'select price_credits from master_prices where master_id = $1 and group_code = $2'
        into v_special using v_uid, v_group.code;
    end if;
    repeat := p_hu is not null and v_free_used < 3 and exists (
      select 1 from activations a join services s on s.id = a.service_id
      where a.vin = p_vin and s.price_group = v_group.code and a.status in ('success', 'running')
        and a.master_id = v_uid
        and head_unit_id(a.device_info) = p_hu);
    price := case when repeat then 0 else coalesce(v_special, v_group.price_credits) end;
  else
    repeat := p_hu is not null and v_free_used < 3 and exists (
      select 1 from activations a
      where a.vin = p_vin and a.service_id = p_service_id and a.status = 'success'
        and a.master_id = v_uid
        and head_unit_id(a.device_info) = p_hu);
    price := case when repeat then 0 else v_own end;
  end if;
  return next;
end $$;

revoke all on function service_charge(text, int, int, text) from public, anon;
grant execute on function service_charge(text, int, int, text) to authenticated, service_role;
