-- Проверка и ручное управление правами администратора. Выполнять в SQL Editor Supabase по частям.
-- Ничего не запускается автоматически.

-- 1. Кто сейчас администратор. Ожидается только ваша учётная запись.
select u.id, u.email, m.name, m.telegram_id, m.created_via, m.status, u.created_at, u.last_sign_in_at,
       (exists (select 1 from admins a where a.user_id = u.id)) as in_admins,
       (m.role = 'admin') as role_admin
from auth.users u
left join masters m on m.id = u.id
where m.role = 'admin' or exists (select 1 from admins a where a.user_id = u.id)
order by u.created_at;

-- 2. Подозрительные регистрации: администратор, но создан не через Telegram и почта не ваша.
select u.id, u.email, m.created_via, u.created_at
from auth.users u
join masters m on m.id = u.id
where (m.role = 'admin' or exists (select 1 from admins a where a.user_id = u.id))
  and lower(coalesce(u.email, '')) <> 'wardecsfly@gmail.com'
  and m.created_via <> 'telegram';

-- 3. Разжаловать и заблокировать лишнего администратора (подставьте его id из пункта 1).
-- delete from admins where user_id = '<uuid>';
-- update masters set role = 'master', status = 'blocked' where id = '<uuid>';

-- 4. Что мог сделать лишний администратор (проверьте перед разжалованием):
--    пополнения баланса, одобрения, запросы трансляций.
-- select * from balance_ledger where created_by = '<uuid>' order by created_at;
-- select * from stream_sessions where requested_by = '<uuid>' order by created_at;
-- select * from refund_requests where decided_by = '<uuid>';

-- 5. Выдать права владельцу вручную (если его учётную запись пересоздавали).
-- insert into admins (user_id) values ('<uuid владельца>') on conflict do nothing;
-- update masters set role = 'admin', status = 'active' where id = '<uuid владельца>';
