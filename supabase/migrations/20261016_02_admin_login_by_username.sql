-- Вход на сайт админки по Telegram-нику (@username) вместо служебной почты.
-- Возвращает почту учётной записи только для администраторов; для остальных — null,
-- поэтому по нику нельзя узнать почту обычного мастера.
create or replace function admin_login_email(p_username text) returns text
language sql stable security definer set search_path = public, auth as $$
  select u.email
  from masters m
  join auth.users u on u.id = m.id
  where lower(m.telegram_username) = lower(ltrim(btrim(p_username), '@'))
    and (m.role = 'admin' or exists (select 1 from admins a where a.user_id = m.id))
    and char_length(btrim(p_username)) between 3 and 64
  limit 1
$$;
revoke execute on function admin_login_email(text) from public;
grant execute on function admin_login_email(text) to anon, authenticated;
