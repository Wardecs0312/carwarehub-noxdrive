-- Вход через Telegram с кодом из бота (аудит 13.10.2026, пункт B-4).
-- Бот присылает 6-значный код, программа вводит его для завершения входа. Здесь хранится только хеш кода
-- и число неверных попыток (не больше 5). Только новые столбцы, данные не меняются.
alter table telegram_logins add column if not exists code_hash text;
alter table telegram_logins add column if not exists code_attempts int not null default 0;
