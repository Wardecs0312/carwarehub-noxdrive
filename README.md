# CarWareHubNoxDrive

Десктопное приложение (Flutter, Windows) для русификации и настройки мультимедиа Changan.
План и архитектура: см. `carwarehub-plan.md` в файлах проекта.

## Запуск

```
flutter pub get
flutter run -d windows \
  --dart-define=SUPABASE_URL=https://<project>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon key>
```

Без этих параметров приложение показывает демо-каталог. Service key в приложение не добавлять.

## База данных

`supabase/migrations/0001_init.sql` содержит схему. Модели, услуги, прошивки, сценарии и
версии приложения (`app_releases`, для Auto-Up) хранятся в таблицах и загружаются динамически.
