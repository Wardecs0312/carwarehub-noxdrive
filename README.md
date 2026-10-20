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

### Кабинет мастера в браузере (PWA)

```
flutter build web --release --no-web-resources-cdn \
  --dart-define=SUPABASE_URL=https://<project>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon/publishable key>
```

Папка `build/web` выкладывается на любой статический хостинг (например, Cloudflare Pages).
`--no-web-resources-cdn` кладёт движок отрисовки рядом с сайтом, без загрузки с серверов Google.
В браузере USB недоступен: вместо индикатора ADB показывается «Кабинет мастера», кнопки услуг заблокированы.

## Настройка Supabase

1. Выполнить в SQL Editor все файлы `supabase/migrations/` по порядку (0001…0009) или один раз `supabase/apply_all.sql`
   на пустом проекте (собирается из них скриптом `tool/build_apply_all.sh`).
   Если проект уже работает на старых миграциях, выполнить только недостающие. Миграция `0009` закрывает получение прав
   администратора при регистрации: перед ней опубликовать новую версию функции `telegram-auth`, после неё
   выполнить `supabase/audit_admins.sql` и проверить список администраторов.
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

Шаги сценария (`scenarios.steps`, jsonb): `install_apk` (флаги `grant` = `-g`, `downgrade` = `-d`), `run_script`,
`push_file` (запись файла на ГУ по `remote_path`), `shell` (флаг `ignore_errors`), `uninstall`, `reboot`.
Шаг с `"hidden": true` не показывается мастеру в окне настройки пакета.
Услуга [6] (вывод на приборную панель) это обычный сценарий с шагом `install_apk`: пока файл не загружен, сервер ответит, что сценарий для прошивки не найден.

## Услуги из nox.bat

| Услуга | Как задаётся |
|---|---|
| [1] Русификация | `publish_package.dart --recipe russify`: подготовка, все .apk из `soft/` с `-r -g` |
| [2] Голосовое управление | `--recipe voice`: push файлов в /data/local/tmp, установка SpeechHMI, перенос в /resources/appdata/tinnove, очистка |
| [3] Удаление китайских приложений | `0004_seed_scenarios.sql`: 7 пакетов через `pm uninstall --user 0` |
| [4] Перезагрузка | `0004_seed_scenarios.sql`: `adb reboot` |
| [5] Системные приложения | `--recipe sysapps`: все .apk из `firmware/` с `-r -d`, затем три `cmd overlay enable` |
| [6] Приборная панель | `--recipe cluster`: подготовка (как в [2] и [5]), затем один .apk с `-r -g` |
| [7] Перевод приборной панели | `--recipe clusterlang --source c281-polymeric-language-helper.jar`: подготовка, помощник в /data/local/tmp, `app_process ... C281PolymericLanguage set ru` (русский = 23), очистка. Источник: архив «рестайлинг чанганы». Входит в «Обычный доступ», у Q05 выключен. Нужен ли `adb root` (по инструкции архива), не проверено на машине |

Публикация (на компьютере администратора, ключ service_role только в переменных окружения):

```
export SUPABASE_URL=https://<project>.supabase.co
export SUPABASE_SERVICE_KEY=<service_role key>
dart run tool/publish_package.dart --recipe russify --source storage:firmwares/nox.zip --prep tool/local/prep.sh --models all --dry-run
```

Без `--dry-run` утилита скачает архив из Storage, зашифрует каждый файл, загрузит в `payloads` и создаст сценарии.
Файл `tool/local/prep.sh` (команда доступа ADB) лежит только у администратора, папка не попадает в git, образец в `tool/examples/`.

## Свои APK мастера

Для услуг установки (`services.allow_custom_apks = true`: русификация, голосовое управление, системные приложения)
перед стартом открывается окно «Настройка пакета установки». Основной пакет показан списком (названия шагов сценария),
ниже мастер добавляет свои .apk через проводник Windows, отмечает галочками нужные и может убрать лишние.
Порядок: основной пакет из облака, затем свои APK по очереди, перезагрузка (если есть в сценарии) в самом конце.
Свои файлы читаются с диска мастера потоком и передаются в ADB (`cmd package install -r -S`), копий не создаётся.
Сбой одного своего APK не отменяет основной пакет и остальные файлы: мастер увидит, какие не встали.
Включить окно для другой услуги: `update services set allow_custom_apks = true where code = '...';`

## Обновления

Версии лежат в таблице `app_releases`, установщики в приватном bucket `releases`.
Обязательное обновление блокирует работу, необязательное показывается плашкой.
