# Регистрация мастеров: почта и Telegram

Новый мастер регистрируется сам на экране входа и попадает в статус «ожидает одобрения».
Админ открывает доступ кнопкой «Одобрить» в админ-панели (вкладка «Мастера»), там же блокировка.
Строку мастера и нулевой баланс создаёт триггер `auth_user_created` (миграция `0006_registration.sql`).

## Почта

Работает сразу после миграции 0006. По умолчанию Supabase просит подтвердить почту письмом
(Authentication → Sign In / Providers → Email → Confirm email). Письма с бесплатного SMTP Supabase
ограничены несколькими в час; для потока регистраций подключите свой SMTP (Authentication → Emails → SMTP).

## Telegram

1. В Telegram открыть @BotFather → `/newbot` → задать имя и username бота (например `noxdrive_login_bot`).
   BotFather выдаст токен — его никому не пересылать.
2. Supabase → Edge Functions → Secrets: добавить
   - `TELEGRAM_BOT_TOKEN` — токен от BotFather;
   - `TELEGRAM_BOT_USERNAME` — username бота без @;
   - `TELEGRAM_WEBHOOK_SECRET` — любая длинная случайная строка (латиница и цифры).
3. Supabase → Edge Functions → Deploy a new function → Via Editor: имя `telegram-auth`, код из
   `supabase/functions/telegram-auth/index.ts`. В настройках функции выключить «Enforce JWT verification»
   (Telegram присылает сообщения без входа). Через CLI: `supabase functions deploy telegram-auth --no-verify-jwt`.
4. Подключить бота к функции: открыть в браузере (подставив свои значения)
   `https://api.telegram.org/bot<ТОКЕН>/setWebhook?url=https://<проект>.supabase.co/functions/v1/telegram-auth&secret_token=<TELEGRAM_WEBHOOK_SECRET>`
   Ответ `"ok":true` — готово.

Как это работает: программа получает одноразовый код и открывает `t.me/<бот>?start=<код>`, мастер жмёт «Старт»,
бот подтверждает код, программа входит сама (код живёт 10 минут и используется один раз).
Мастер из Telegram получает служебную почту `tg-<id>@telegram.nox.drive`, пароль ему не нужен.
