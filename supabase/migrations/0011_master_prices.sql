-- Специальные цены для отдельных мастеров: администратор задаёт мастеру свою цену в кредитах
-- для строки прайса (price_groups: обычный доступ «complex», «cluster» и т. д.).
-- Нет записи — мастер платит обычную цену. Повторная услуга на тот же VIN по-прежнему бесплатна.
-- Скрипт можно запускать повторно.

create table if not exists master_prices (
  master_id uuid not null references masters on delete cascade,
  group_code text not null references price_groups(code) on delete cascade,
  price_credits int not null check (price_credits >= 0),
  updated_at timestamptz not null default now(),
  primary key (master_id, group_code)
);
alter table master_prices enable row level security;

-- Мастер видит свои специальные цены (для карточки цены), админ — все и меняет их.
drop policy if exists master_prices_self on master_prices;
create policy master_prices_self on master_prices for select to authenticated
  using (master_id = auth.uid() or nox_is_admin());
drop policy if exists master_prices_admin on master_prices;
create policy master_prices_admin on master_prices for all to authenticated
  using (nox_is_admin()) with check (nox_is_admin());

-- Установить (p_price >= 0) или снять (p_price = null) специальную цену мастеру.
create or replace function admin_set_master_price(p_master uuid, p_group text, p_price int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not nox_is_admin() then raise exception 'FORBIDDEN'; end if;
  if p_price is null then
    delete from master_prices where master_id = p_master and group_code = p_group;
    return;
  end if;
  if p_price < 0 then raise exception 'BAD_PRICE'; end if;
  insert into master_prices (master_id, group_code, price_credits) values (p_master, p_group, p_price)
  on conflict (master_id, group_code)
  do update set price_credits = excluded.price_credits, updated_at = now();
end $$;
revoke all on function admin_set_master_price(uuid, text, int) from public;
grant execute on function admin_set_master_price(uuid, text, int) to authenticated;

-- Цена услуги с учётом специальной цены мастера (auth.uid() — мастер, который запускает услугу).
create or replace function service_charge(p_vin text, p_service_id int, p_model_id int)
returns table (price int, repeat boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  v_own int;
  v_group price_groups;
  v_model text;
  v_special int;
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
    select mp.price_credits into v_special from master_prices mp
    where mp.master_id = auth.uid() and mp.group_code = v_group.code;
    repeat := exists (
      select 1 from activations a join services s on s.id = a.service_id
      where a.vin = p_vin and s.price_group = v_group.code and a.status in ('success', 'running'));
    price := case when repeat then 0 else coalesce(v_special, v_group.price_credits) end;
  else
    repeat := exists (select 1 from activations
                      where vin = p_vin and service_id = p_service_id and status = 'success');
    price := case when repeat then 0 else v_own end;
  end if;
  return next;
end $$;
revoke all on function service_charge from public;
