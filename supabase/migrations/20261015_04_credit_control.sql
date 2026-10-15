-- Контроль кредитов: админ начисляет и списывает с причиной, каждое изменение баланса только через журнал.
--
-- 1) Журнал получает причину (note), видно, кто и зачем менял баланс.
-- 2) admin_adjust_credits: начислить (+) или списать (-) с обязательной причиной; баланс не уходит в минус.
-- 3) Сверка: если баланс мастера уже расходится с журналом (баланс правили напрямую в таблице),
--    в журнал дописывается запись «правка мимо журнала» на разницу. Баланс НЕ меняется, ничего не теряется.
-- 4) Защита: при сохранении изменений баланс каждого мастера обязан совпадать с суммой его журнала.
--    Правка баланса в таблице мимо функций отклоняется. Функции программы (start_job, admin_topup,
--    admin_decide_refund, admin_adjust_credits) пишут журнал сами и работают как раньше.
-- Скрипт можно запускать повторно.

alter table balance_ledger add column if not exists note text;

-- 3) Сверка существующих расхождений (до включения защиты).
insert into balance_ledger (master_id, amount, reason, note)
select b.master_id, b.credits - coalesce(l.s, 0), 'adjust',
       'сверка ' || to_char(now(), 'DD.MM.YYYY') || ': изменение баланса без записи в журнал'
from master_balance b
left join (select master_id, sum(amount) s from balance_ledger group by 1) l on l.master_id = b.master_id
where b.credits <> coalesce(l.s, 0);

-- 2) Начислить или списать.
create or replace function admin_adjust_credits(p_master uuid, p_amount int, p_reason text) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_reason text := btrim(coalesce(p_reason, ''));
  v_credits int;
begin
  if not nox_is_admin() then raise exception 'FORBIDDEN'; end if;
  if p_amount is null or p_amount = 0 or abs(p_amount) > 1000000 then raise exception 'BAD_AMOUNT'; end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 200 then raise exception 'REASON_REQUIRED'; end if;
  if not exists (select 1 from masters where id = p_master) then raise exception 'NOT_FOUND'; end if;

  insert into master_balance (master_id) values (p_master) on conflict do nothing;
  select credits into v_credits from master_balance where master_id = p_master for update;
  if v_credits + p_amount < 0 then raise exception 'NOT_ENOUGH_CREDITS'; end if;

  update master_balance set credits = credits + p_amount, updated_at = now() where master_id = p_master;
  insert into balance_ledger (master_id, amount, reason, created_by, note)
  values (p_master, p_amount, case when p_amount > 0 then 'topup' else 'adjust' end, auth.uid(), v_reason);
  return v_credits + p_amount;
end $$;
revoke all on function admin_adjust_credits(uuid, int, text) from public, anon;
grant execute on function admin_adjust_credits(uuid, int, text) to authenticated, service_role;

-- 4) Защита: баланс = сумма журнала. Проверяется в конце транзакции, поэтому функции,
--    которые сначала меняют баланс, а потом пишут журнал, проходят.
create or replace function check_balance_matches_ledger() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_sum int;
begin
  select coalesce(sum(amount), 0) into v_sum from balance_ledger where master_id = new.master_id;
  if (select credits from master_balance where master_id = new.master_id) <> v_sum then
    raise exception 'BALANCE_WITHOUT_LEDGER: баланс можно менять только через начисление/списание в админ-панели';
  end if;
  return null;
end $$;
revoke all on function check_balance_matches_ledger() from public, anon;

drop trigger if exists balance_matches_ledger on master_balance;
create constraint trigger balance_matches_ledger
  after insert or update on master_balance
  deferrable initially deferred
  for each row execute function check_balance_matches_ledger();
