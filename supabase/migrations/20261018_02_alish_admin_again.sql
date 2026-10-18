-- Алишер (@fxallish) снова администратор (по его просьбе).
insert into admins (user_id) values ('b623a7ec-465a-43b8-a422-d8db746f804a') on conflict do nothing;
update masters set role = 'admin' where id = 'b623a7ec-465a-43b8-a422-d8db746f804a';
