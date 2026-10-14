-- Смена имени (ника) мастера: администратор меняет имя себе и любому мастеру.
-- Имя видно в админ-панели, журнале операций и заявках. 1–60 символов, пробелы по краям убираются.
-- Скрипт можно запускать повторно.

create or replace function admin_set_master_name(p_master uuid, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare v_name text := btrim(coalesce(p_name, ''));
begin
  if not nox_is_admin() then raise exception 'FORBIDDEN'; end if;
  if char_length(v_name) < 1 or char_length(v_name) > 60 then raise exception 'BAD_NAME'; end if;
  update masters set name = v_name where id = p_master;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

revoke all on function admin_set_master_name(uuid, text) from public;
grant execute on function admin_set_master_name(uuid, text) to authenticated;
