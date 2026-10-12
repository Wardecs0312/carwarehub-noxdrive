# nox.drive: CarWareHubNoxDrive

Десктопное приложение (Flutter, Windows) для русификации и настройки мультимедиа Changan.

## Запуск

```
flutter pub get
flutter run -d windows \
  --dart-define=SUPABASE_URL=https://<project>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon/publishable key>
```

Без этих параметров приложение работает в демо-режиме (без входа, демо-каталог, безопасный тестовый шаг).
Service key в приложение не добавлять.

## Настройка Supabase

1. Выполнить по порядку `supabase/migrations/0001_init.sql` и `0002_jobs.sql` в SQL Editor.
2. Создать мастера: Authentication → Users → Add user, затем `insert into masters (id, name) values ('<uuid>', 'Имя');`
3. Администратор: `insert into admins (user_id) values ('<uuid>');`
4. Пополнение баланса: `select admin_topup('<uuid мастера>', 100);` (от имени администратора).

## Как устроено выполнение услуги

1. ADB Status Checker раз в 2 секунды проверяет подключение ГУ (`lib/adb/`). Нет ГУ, нет VIN или модели: кнопки услуг заблокированы.
2. `start_job` на сервере проверяет VIN, баланс и находит сценарий для прошивки ГУ. Повтор той же услуги на тот же VIN бесплатный.
3. Файлы (APK, скрипты) лежат в приватном bucket `payloads` в зашифрованном виде (AES-256-GCM, блоками).
   Приложение скачивает поток, расшифровывает в памяти и сразу передаёт в stdin ADB. На диск ничего не пишется.
   Доступ к файлу открыт только на время активного задания.
4. `finish_job` закрывает задание. Автовозврата нет: при сбое мастер подаёт заявку, решает админ.

Подготовка файла для загрузки: `dart run tool/encrypt_payload.dart app.apk app.apk.enc`.
Утилита печатает ключ, размер и sha256, их нужно внести в таблицу `payloads`.

Шаги сценария (`scenarios.steps`, jsonb): `install_apk`, `run_script`, `shell`, `uninstall`, `reboot`.
Услуга [6] (вывод на приборную панель) это обычный сценарий с шагом `install_apk`: пока файл не загружен, сервер ответит, что сценарий для прошивки не найден.

## Обновления

Версии лежат в таблице `app_releases`, установщики в приватном bucket `releases`.
Обязательное обновление блокирует работу, необязательное показывается плашкой.
