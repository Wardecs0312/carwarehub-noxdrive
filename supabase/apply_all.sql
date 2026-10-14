
-- Все миграции одним файлом для вставки в SQL Editor Supabase (собрано из всех файлов supabase/migrations, по порядку).
-- Выполнять один раз. Если в проекте уже есть объекты с такими же именами,
-- скрипт сразу остановится со списком совпадений и ничего не создаст.

-- Проверка перед установкой: ищем в проекте объекты с теми же именами, что создают миграции.
do $$
declare
  conflicts text;
begin
  select string_agg(kind || ' ' || name, ', ') into conflicts from (
    select 'таблица' as kind, c.relname::text as name
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = any (array[
        'admins','masters','balance_ledger','master_balance','brands','car_models','firmwares',
        'services','model_services','payloads','scenarios','app_releases','vehicles',
        'activation_requests','activation_codes','activations','refund_requests'])
    union all
    select 'функция', p.proname::text
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = any (array[
        'nox_is_admin','normalize_vin','start_job','finish_job','request_refund',
        'expire_stale_jobs','admin_topup','admin_decide_refund','scenario_preview'])
    union all
    select 'правило хранилища', policyname::text
      from pg_policies
      where schemaname = 'storage' and tablename = 'objects'
        and policyname in ('payloads_read_running_job','releases_read')
  ) x;
  if conflicts is not null then
    raise exception 'В проекте уже есть объекты с такими именами: %. Ничего не создано.', conflicts;
  end if;
end $$;

-- ===== supabase/migrations/0001_init.sql =====
-- CarWareHubNoxDrive: начальная схема.
-- Каталоги (бренды, модели, прошивки, услуги, сценарии) хранятся в данных,
-- приложение загружает их динамически. Новая модель или услуга = строка в таблице.

create extension if not exists pgcrypto;

-- ---------- Администраторы и мастера ----------
create table admins (user_id uuid primary key references auth.users on delete cascade);

create function nox_is_admin() returns boolean language sql stable security definer as
$$ select exists (select 1 from admins where user_id = auth.uid()) $$;

create table masters (
  id uuid primary key references auth.users on delete cascade,
  name text not null,
  phone text,
  status text not null default 'active' check (status in ('active','blocked')),
  created_at timestamptz not null default now()
);

-- Баланс: журнал + кэш. Менять можно только через RPC (security definer).
create table balance_ledger (
  id bigint generated always as identity primary key,
  master_id uuid not null references masters,
  amount int not null,                 -- + пополнение, - списание
  reason text not null,                -- 'topup' | 'charge' | 'refund' | 'adjust'
  activation_id uuid,
  created_by uuid,
  created_at timestamptz not null default now()
);
create table master_balance (
  master_id uuid primary key references masters,
  credits int not null default 0 check (credits >= 0),
  updated_at timestamptz not null default now()
);

-- ---------- Динамические каталоги ----------
create table brands (
  id serial primary key,
  code text unique not null,           -- 'changan'
  title text not null,
  is_active boolean not null default true,
  sort_order int not null default 100
);

create table car_models (
  id serial primary key,
  brand_id int not null references brands,
  code text unique not null,           -- 'q05', 'uni-z', 'cs75-pro' ...
  title text not null,
  image_url text,
  is_active boolean not null default true,
  sort_order int not null default 100
);

create table firmwares (
  id serial primary key,
  model_id int not null references car_models,
  version_pattern text not null,       -- шаблон для сопоставления с ro.build.* ГУ
  android_api int,
  notes text,
  is_active boolean not null default true
);

create table services (
  id serial primary key,
  code text unique not null,           -- 'russify', 'voice', 'debloat', 'reboot', 'sysapps', 'cluster'
  title text not null,
  description text,
  icon text,
  price_credits int not null default 0 check (price_credits >= 0),
  is_active boolean not null default true,
  sort_order int not null default 100
);

-- Какие услуги доступны для какой модели (можно скрыть услугу у модели)
create table model_services (
  model_id int not null references car_models,
  service_id int not null references services,
  price_override int check (price_override >= 0),
  is_active boolean not null default true,
  primary key (model_id, service_id)
);

-- Файлы в приватном Storage (APK, скрипты), зашифрованные
create table payloads (
  id uuid primary key default gen_random_uuid(),
  storage_path text not null,
  kind text not null check (kind in ('apk','sh','bin')),
  size_bytes bigint not null,
  sha256 text not null,
  enc_key_id text not null,            -- ссылка на ключ, сам ключ не хранится в клиентских таблицах
  created_at timestamptz not null default now()
);

-- Сценарий = шаги для пары (услуга, прошивка)
create table scenarios (
  id uuid primary key default gen_random_uuid(),
  service_id int not null references services,
  firmware_id int not null references firmwares,
  version int not null default 1,
  steps jsonb not null,                -- [{type:'install_apk',payload_id:..},{type:'shell',payload_id:..},{type:'reboot'}]
  min_app_version text,                -- сценарий требует приложение не старее
  is_active boolean not null default true,
  unique (service_id, firmware_id, version)
);

-- ---------- Версии приложения (Auto-Up) ----------
create table app_releases (
  id serial primary key,
  platform text not null default 'windows',
  channel text not null default 'stable' check (channel in ('stable','beta')),
  version text not null,               -- semver: 1.2.3
  build_number int not null,
  download_path text not null,         -- путь в приватном Storage 'releases'
  sha256 text not null,
  size_bytes bigint,
  release_notes text,
  min_supported_version text,          -- ниже этой версии запуск услуг запрещён
  is_mandatory boolean not null default false,
  is_active boolean not null default true,
  published_at timestamptz not null default now(),
  unique (platform, channel, build_number)
);

-- ---------- Заявки, коды, активации ----------
create table vehicles (
  vin char(17) primary key check (vin ~ '^[A-HJ-NPR-Z0-9]{17}$'),
  model_id int references car_models,
  firmware_seen text,
  first_seen_by uuid references masters,
  created_at timestamptz not null default now()
);

create table activation_requests (
  id uuid primary key default gen_random_uuid(),
  master_id uuid not null references masters,
  vin char(17) not null check (vin ~ '^[A-HJ-NPR-Z0-9]{17}$'),
  model_id int references car_models,
  service_ids int[] not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);

create table activation_codes (
  code text primary key,
  request_id uuid not null references activation_requests,
  master_id uuid not null references masters,
  vin char(17) not null,
  service_ids int[] not null,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);

create table activations (
  id uuid primary key default gen_random_uuid(),
  master_id uuid not null references masters,
  vin char(17) not null,
  service_id int not null references services,
  scenario_id uuid references scenarios,
  code text references activation_codes,
  status text not null default 'running' check (status in ('running','success','failed')),
  credits int not null default 0,
  app_version text,                    -- версия приложения, выполнившего услугу
  device_info jsonb,
  log text,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
create index on activations (vin, service_id) where status = 'success';

create table refund_requests (
  id uuid primary key default gen_random_uuid(),
  activation_id uuid not null references activations,
  master_id uuid not null references masters,
  reason text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);

-- ---------- Права (RLS) ----------
alter table admins enable row level security;
alter table masters enable row level security;
alter table balance_ledger enable row level security;
alter table master_balance enable row level security;
alter table brands enable row level security;
alter table car_models enable row level security;
alter table firmwares enable row level security;
alter table services enable row level security;
alter table model_services enable row level security;
alter table payloads enable row level security;
alter table scenarios enable row level security;
alter table app_releases enable row level security;
alter table vehicles enable row level security;
alter table activation_requests enable row level security;
alter table activation_codes enable row level security;
alter table activations enable row level security;
alter table refund_requests enable row level security;

-- Каталоги читают все вошедшие мастера, пишет админ
do $$ declare t text; begin
  foreach t in array array['brands','car_models','firmwares','services','model_services','app_releases'] loop
    execute format('create policy %I_read on %I for select to authenticated using (is_active)', t, t);
    execute format('create policy %I_admin on %I for all to authenticated using (nox_is_admin()) with check (nox_is_admin())', t, t);
  end loop;
end $$;

-- Свои данные
create policy masters_self on masters for select to authenticated using (id = auth.uid() or nox_is_admin());
create policy balance_self on master_balance for select to authenticated using (master_id = auth.uid() or nox_is_admin());
create policy ledger_self on balance_ledger for select to authenticated using (master_id = auth.uid() or nox_is_admin());
create policy req_self on activation_requests for select to authenticated using (master_id = auth.uid() or nox_is_admin());
create policy req_insert on activation_requests for insert to authenticated with check (master_id = auth.uid());
create policy code_self on activation_codes for select to authenticated using (master_id = auth.uid() or nox_is_admin());
create policy act_self on activations for select to authenticated using (master_id = auth.uid() or nox_is_admin());
create policy refund_self on refund_requests for select to authenticated using (master_id = auth.uid() or nox_is_admin());
create policy refund_insert on refund_requests for insert to authenticated with check (master_id = auth.uid());
create policy refund_admin on refund_requests for update to authenticated using (nox_is_admin());
create policy admins_admin on admins for select to authenticated using (nox_is_admin());
-- payloads, scenarios, vehicles: политик нет, значит клиенту недоступны напрямую.
-- Доступ только через Edge Functions (service role).

-- ---------- Стартовые данные ----------
insert into brands (code, title) values ('changan', 'Changan');

insert into car_models (brand_id, code, title, sort_order)
select b.id, v.code, v.title, v.ord from brands b,
(values ('q05','Changan Q05',10),('uni-z','Changan UNI-Z',20),('cs75-pro','Changan CS75 Pro',30),
        ('cs55-plus','Changan CS55 Plus',40),('uni-v','Changan UNI-V',50)) as v(code,title,ord)
where b.code = 'changan';

insert into services (code, title, sort_order) values
 ('russify','Русификация и установка приложений',10),
 ('voice','Установка голосового управления',20),
 ('debloat','Удаление китайских приложений',30),
 ('reboot','Перезагрузка автомобиля',40),
 ('sysapps','Установка системных приложений',50),
 ('cluster','Вывод приложений на приборную панель',60);

insert into model_services (model_id, service_id)
select m.id, s.id from car_models m cross join services s;
-- Цены (price_credits) задаются админом позже.

-- ===== supabase/migrations/0002_jobs.sql =====
-- Выполнение услуг: серверная проверка баланса и VIN, выдача шагов сценария,
-- доступ к зашифрованным файлам только на время выполнения задания.

alter table payloads add column if not exists enc_key text;   -- base64, 32 байта AES-256. Клиенту недоступен напрямую.
alter table payloads alter column enc_key_id drop not null;  -- ключ хранится в enc_key, ссылка не нужна

-- Приватные хранилища
insert into storage.buckets (id, name, public) values ('payloads', 'payloads', false) on conflict do nothing;
insert into storage.buckets (id, name, public) values ('releases', 'releases', false) on conflict do nothing;

-- Файл сценария можно скачать только в рамках своего активного задания (status = 'running').
create policy payloads_read_running_job on storage.objects for select to authenticated
using (
  bucket_id = 'payloads' and exists (
    select 1
    from activations a
    join scenarios s on s.id = a.scenario_id
    join payloads p on p.storage_path = storage.objects.name
    where a.master_id = auth.uid()
      and a.status = 'running'
      and s.steps @> jsonb_build_array(jsonb_build_object('payload_id', p.id))
  )
);

-- Установщик обновлений доступен любому вошедшему мастеру
create policy releases_read on storage.objects for select to authenticated
using (bucket_id = 'releases');

-- Нормализация VIN
create function normalize_vin(p_vin text) returns text language sql immutable as
$$ select upper(btrim(p_vin)) $$;

-- Старт задания. Возвращает job_id, цену и шаги с данными для скачивания и расшифровки.
create function start_job(
  p_vin text, p_service_id int, p_model_id int, p_app_version text, p_device jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  v_vin text := normalize_vin(p_vin);
  v_price int;
  v_scenario scenarios;
  v_job uuid;
  v_repeat boolean;
  v_balance int;
  v_steps jsonb;
begin
  if uid is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists (select 1 from masters where id = uid and status = 'active') then
    raise exception 'MASTER_BLOCKED';
  end if;
  if v_vin !~ '^[A-HJ-NPR-Z0-9]{17}$' then raise exception 'VIN_INVALID'; end if;

  select coalesce(ms.price_override, s.price_credits) into v_price
  from model_services ms join services s on s.id = ms.service_id
  where ms.model_id = p_model_id and ms.service_id = p_service_id and ms.is_active and s.is_active;
  if v_price is null then raise exception 'SERVICE_UNAVAILABLE'; end if;

  -- сценарий для прошивки ГУ (version_pattern сравнивается как LIKE с ro.build.display.id)
  select sc.* into v_scenario
  from scenarios sc join firmwares f on f.id = sc.firmware_id
  where sc.service_id = p_service_id and f.model_id = p_model_id
    and sc.is_active and f.is_active
    and coalesce(p_device->>'build', '') like f.version_pattern
  order by sc.version desc limit 1;
  if v_scenario.id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;

  -- повтор той же услуги на тот же VIN бесплатный
  v_repeat := exists (select 1 from activations
                      where vin = v_vin and service_id = p_service_id and status = 'success');
  if v_repeat then v_price := 0; end if;

  insert into master_balance (master_id) values (uid) on conflict do nothing;
  select credits into v_balance from master_balance where master_id = uid for update;
  if v_balance < v_price then raise exception 'INSUFFICIENT_BALANCE'; end if;

  insert into vehicles (vin, model_id, firmware_seen, first_seen_by)
  values (v_vin, p_model_id, p_device->>'build', uid) on conflict (vin) do nothing;

  insert into activations (master_id, vin, service_id, scenario_id, credits, app_version, device_info)
  values (uid, v_vin, p_service_id, v_scenario.id, v_price, p_app_version, p_device)
  returning id into v_job;

  if v_price > 0 then
    update master_balance set credits = credits - v_price, updated_at = now() where master_id = uid;
    insert into balance_ledger (master_id, amount, reason, activation_id)
    values (uid, -v_price, 'charge', v_job);
  end if;

  select coalesce(jsonb_agg(
           case when e.step ? 'payload_id' then
             e.step || jsonb_build_object(
               'storage_path', p.storage_path, 'size_bytes', p.size_bytes,
               'sha256', p.sha256, 'enc_key', p.enc_key, 'kind', p.kind)
           else e.step end
           order by e.ord), '[]'::jsonb)
  into v_steps
  from jsonb_array_elements(v_scenario.steps) with ordinality as e(step, ord)
  left join payloads p on e.step ? 'payload_id' and p.id = (e.step->>'payload_id')::uuid;

  return jsonb_build_object('job_id', v_job, 'price', v_price, 'repeat', v_repeat, 'steps', v_steps);
end $$;

-- Завершение задания. Автоматического возврата нет: при сбое мастер подаёт заявку, решает админ.
create function finish_job(p_job_id uuid, p_success boolean, p_log text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update activations
  set status = case when p_success then 'success' else 'failed' end,
      log = left(p_log, 20000), finished_at = now()
  where id = p_job_id and master_id = auth.uid() and status = 'running';
  if not found then raise exception 'JOB_NOT_FOUND'; end if;
end $$;

create function request_refund(p_activation_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from activations
                 where id = p_activation_id and master_id = auth.uid()
                   and status = 'failed' and credits > 0) then
    raise exception 'REFUND_NOT_ALLOWED';
  end if;
  insert into refund_requests (activation_id, master_id, reason)
  values (p_activation_id, auth.uid(), p_reason);
end $$;

-- Задания, зависшие в 'running' (закрыли программу, выдернули кабель), закрываются как failed.
create function expire_stale_jobs() returns void language sql security definer set search_path = public as $$
  update activations set status = 'failed', finished_at = now(), log = coalesce(log, 'timeout')
  where status = 'running' and created_at < now() - interval '30 minutes'
$$;

-- ---------- Админ ----------
create function admin_topup(p_master uuid, p_amount int, p_note text default 'topup') returns void
language plpgsql security definer set search_path = public as $$
begin
  if not nox_is_admin() then raise exception 'FORBIDDEN'; end if;
  insert into master_balance (master_id, credits) values (p_master, 0) on conflict do nothing;
  update master_balance set credits = credits + p_amount, updated_at = now() where master_id = p_master;
  insert into balance_ledger (master_id, amount, reason, created_by) values (p_master, p_amount, p_note, auth.uid());
end $$;

create function admin_decide_refund(p_refund_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r refund_requests; a activations;
begin
  if not nox_is_admin() then raise exception 'FORBIDDEN'; end if;
  select * into r from refund_requests where id = p_refund_id and status = 'pending' for update;
  if r.id is null then raise exception 'REFUND_NOT_FOUND'; end if;
  update refund_requests set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = auth.uid(), decided_at = now() where id = r.id;
  if p_approve then
    select * into a from activations where id = r.activation_id;
    update master_balance set credits = credits + a.credits, updated_at = now() where master_id = a.master_id;
    insert into balance_ledger (master_id, amount, reason, activation_id, created_by)
    values (a.master_id, a.credits, 'refund', a.id, auth.uid());
  end if;
end $$;

revoke all on function start_job, finish_job, request_refund, expire_stale_jobs, admin_topup, admin_decide_refund from public;
grant execute on function start_job, finish_job, request_refund, admin_topup, admin_decide_refund to authenticated;

-- Шаги сценария (steps) задаются админом в jsonb, поддерживаются типы:
--   {"type":"install_apk","title":"...","payload_id":"<uuid>"}   APK потоком в память ГУ
--   {"type":"run_script","title":"...","payload_id":"<uuid>"}    sh-скрипт потоком в stdin
--   {"type":"shell","title":"...","cmd":"settings put ..."}      короткая команда
--   {"type":"uninstall","title":"...","packages":["com.a","com.b"]}
--   {"type":"reboot","title":"..."}

-- ===== supabase/migrations/0003_custom_apk.sql =====
-- Услуги установки, для которых мастер может добавить свои APK, и предпросмотр основного пакета.

alter table services add column if not exists allow_custom_apks boolean not null default false;
update services set allow_custom_apks = true where code in ('russify', 'voice', 'sysapps');

-- Предпросмотр основного пакета для окна «Настройка пакета установки».
-- Возвращает только названия шагов, цену и признак бесплатного повтора. Файлы и ключи не раскрываются.
create function scenario_preview(
  p_vin text, p_service_id int, p_model_id int, p_device jsonb
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_vin text := normalize_vin(p_vin);
  v_price int;
  v_scenario scenarios;
  v_repeat boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  select coalesce(ms.price_override, s.price_credits) into v_price
  from model_services ms join services s on s.id = ms.service_id
  where ms.model_id = p_model_id and ms.service_id = p_service_id and ms.is_active and s.is_active;
  if v_price is null then raise exception 'SERVICE_UNAVAILABLE'; end if;

  select sc.* into v_scenario
  from scenarios sc join firmwares f on f.id = sc.firmware_id
  where sc.service_id = p_service_id and f.model_id = p_model_id
    and sc.is_active and f.is_active
    and coalesce(p_device->>'build', '') like f.version_pattern
  order by sc.version desc limit 1;
  if v_scenario.id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;

  v_repeat := exists (select 1 from activations
                      where vin = v_vin and service_id = p_service_id and status = 'success');

  return jsonb_build_object(
    'price', case when v_repeat then 0 else v_price end,
    'repeat', v_repeat,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('type', e.step->>'type', 'title', e.step->>'title') order by e.ord)
      from jsonb_array_elements(v_scenario.steps) with ordinality as e(step, ord)
    ), '[]'::jsonb)
  );
end $$;

revoke all on function scenario_preview from public;
grant execute on function scenario_preview to authenticated;

-- ===== supabase/migrations/0004_seed_scenarios.sql =====
-- Сценарии без файлов (из nox.bat): [3] удаление китайских приложений и [4] перезагрузка.
-- Остальные услуги публикуются утилитой tool/publish_package.dart, потому что требуют загрузки файлов.

-- Прошивка «любая» для каждой модели (version_pattern сравнивается как LIKE с ro.build.display.id)
insert into firmwares (model_id, version_pattern, notes)
select m.id, '%', 'любая прошивка' from car_models m
where not exists (select 1 from firmwares f where f.model_id = m.id and f.version_pattern = '%');

insert into scenarios (service_id, firmware_id, version, steps)
select s.id, f.id, 1,
  case s.code
    when 'debloat' then jsonb_build_array(jsonb_build_object(
      'type', 'uninstall',
      'title', 'Удаление китайских приложений',
      'packages', jsonb_build_array(
        'com.tinnove.scenemode',
        'com.tinnove.wecarnavi',
        'com.tinnove.wechatlink',
        'com.changan.appmarket',
        'com.tinnove.netease.music',
        'com.wtcl.electronicdirections',
        'com.wt.phonelink')))
    else jsonb_build_array(jsonb_build_object('type', 'reboot', 'title', 'Перезагрузка автомобиля'))
  end
from services s
join firmwares f on f.version_pattern = '%'
where s.code in ('debloat', 'reboot')
on conflict (service_id, firmware_id, version) do nothing;

-- Предпросмотр основного пакета: шаги с "hidden": true (технические, например передача каждого файла) не показываются.
create or replace function scenario_preview(
  p_vin text, p_service_id int, p_model_id int, p_device jsonb
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_vin text := normalize_vin(p_vin);
  v_price int;
  v_scenario scenarios;
  v_repeat boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  select coalesce(ms.price_override, s.price_credits) into v_price
  from model_services ms join services s on s.id = ms.service_id
  where ms.model_id = p_model_id and ms.service_id = p_service_id and ms.is_active and s.is_active;
  if v_price is null then raise exception 'SERVICE_UNAVAILABLE'; end if;

  select sc.* into v_scenario
  from scenarios sc join firmwares f on f.id = sc.firmware_id
  where sc.service_id = p_service_id and f.model_id = p_model_id
    and sc.is_active and f.is_active
    and coalesce(p_device->>'build', '') like f.version_pattern
  order by sc.version desc limit 1;
  if v_scenario.id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;

  v_repeat := exists (select 1 from activations
                      where vin = v_vin and service_id = p_service_id and status = 'success');

  return jsonb_build_object(
    'price', case when v_repeat then 0 else v_price end,
    'repeat', v_repeat,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('type', e.step->>'type', 'title', e.step->>'title') order by e.ord)
      from jsonb_array_elements(v_scenario.steps) with ordinality as e(step, ord)
      where not coalesce((e.step->>'hidden')::boolean, false)
    ), '[]'::jsonb)
  );
end $$;

-- ===== supabase/migrations/0005_streaming.sql =====
-- Трансляции для администратора (docs/STREAMING.md): экран ноутбука мастера, экран ГУ, камера.
-- Видео идёт через LiveKit; здесь только запросы, статусы и журнал.

-- Базы, поставленные до переименования is_admin -> nox_is_admin, получают новое имя
-- (на свежей базе функция уже есть и просто перезаписывается тем же телом).
create or replace function nox_is_admin() returns boolean language sql stable security definer
set search_path = public as
$$ select exists (select 1 from admins where user_id = auth.uid()) $$;

-- Согласие мастера на трансляции (галочка при первом входе).
alter table masters add column if not exists stream_consent_at timestamptz;

create table if not exists stream_sessions (
  id uuid primary key default gen_random_uuid(),
  master_id uuid not null references masters on delete cascade,
  requested_by uuid not null references auth.users,
  sources text[] not null check (sources <@ array['screen-laptop','screen-hu','camera']::text[] and cardinality(sources) > 0),
  status text not null default 'requested' check (status in ('requested','live','ended')),
  created_at timestamptz not null default now(),
  started_at timestamptz,
  ended_at timestamptz
);
create index if not exists stream_sessions_open on stream_sessions (master_id) where status <> 'ended';

alter table stream_sessions enable row level security;

-- Админ: всё. Мастер: видит свои запросы (чтобы показать плашку), статус меняет только через функцию ниже.
drop policy if exists stream_admin on stream_sessions;
drop policy if exists stream_master_read on stream_sessions;
create policy stream_admin on stream_sessions for all to authenticated
  using (nox_is_admin()) with check (nox_is_admin());
create policy stream_master_read on stream_sessions for select to authenticated
  using (master_id = auth.uid());

-- Мастер меняет статус только через эту функцию: live (начал) или ended (остановил сам).
create or replace function master_stream_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('live','ended') then raise exception 'BAD_STATUS'; end if;
  update stream_sessions
     set status = p_status,
         started_at = case when p_status = 'live' then coalesce(started_at, now()) else started_at end,
         ended_at = case when p_status = 'ended' then now() else ended_at end
   where id = p_id and master_id = auth.uid() and status <> 'ended';
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

-- Согласие мастера (один раз; дальше трансляции идут с плашкой без повторного вопроса).
create or replace function master_stream_consent() returns void
language sql security definer set search_path = public as $$
  update masters set stream_consent_at = coalesce(stream_consent_at, now()) where id = auth.uid();
$$;

-- Запросы приходят в приложение мастера мгновенно (Supabase Realtime).
do $$ begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and tablename = 'stream_sessions') then
    alter publication supabase_realtime add table stream_sessions;
  end if;
end $$;

-- ===== supabase/migrations/0006_registration.sql =====
-- Самостоятельная регистрация мастеров: через почту и через Telegram.
-- Новый мастер получает статус pending и работает только после одобрения админом.

alter table masters drop constraint if exists masters_status_check;
alter table masters add constraint masters_status_check
  check (status in ('pending','active','blocked'));
alter table masters add column if not exists email text;
alter table masters add column if not exists telegram_id bigint unique;
alter table masters add column if not exists telegram_username text;
alter table masters add column if not exists created_via text not null default 'admin'
  check (created_via in ('admin','email','telegram'));

-- Новый пользователь Supabase Auth -> строка мастера (pending) и нулевой баланс.
-- Данные регистрации приходят в raw_user_meta_data: name, phone, telegram_id, telegram_username, via.
create or replace function on_auth_user_created() returns trigger
language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into masters (id, name, phone, status, email, telegram_id, telegram_username, created_via)
  values (
    new.id,
    coalesce(nullif(trim(m->>'name'), ''), split_part(new.email, '@', 1)),
    nullif(trim(m->>'phone'), ''),
    'pending',
    case when m->>'via' = 'telegram' then null else new.email end,
    (m->>'telegram_id')::bigint,
    m->>'telegram_username',
    case when m->>'via' in ('email','telegram') then m->>'via' else 'admin' end
  )
  on conflict (id) do nothing;
  insert into master_balance (master_id) values (new.id) on conflict do nothing;
  return new;
end $$;

drop trigger if exists auth_user_created on auth.users;
create trigger auth_user_created after insert on auth.users
  for each row execute function on_auth_user_created();

-- Одобрение / блокировка мастера админом.
create or replace function admin_set_master_status(p_master uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not nox_is_admin() then raise exception 'FORBIDDEN'; end if;
  if p_status not in ('pending','active','blocked') then raise exception 'BAD_STATUS'; end if;
  update masters set status = p_status where id = p_master;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

-- Вход через Telegram: одноразовый код, который бот подтверждает по /start <код>.
-- Доступ только у Edge Function (service_role); клиентам таблица закрыта.
create table if not exists telegram_logins (
  nonce text primary key,
  created_at timestamptz not null default now(),
  telegram_id bigint,
  telegram_username text,
  telegram_name text,
  confirmed_at timestamptz,
  consumed_at timestamptz
);
alter table telegram_logins enable row level security;

-- ===== supabase/migrations/0007_owner_admin.sql =====
-- Владелец всегда администратор: почта wardecsfly@gmail.com и Telegram 8106761823.
-- 1) колонка masters.role ('master' | 'admin');
-- 2) nox_is_admin() = запись в admins ИЛИ masters.role = 'admin';
-- 3) при создании аккаунта владельца (почта или Telegram) он сразу админ и одобрен (status = 'active').
-- Статус «одобрен» в этой базе называется 'active'. Скрипт можно запускать повторно.

alter table masters add column if not exists role text not null default 'master';
alter table masters drop constraint if exists masters_role_check;
alter table masters add constraint masters_role_check check (role in ('master','admin'));

create or replace function is_owner_identity(p_email text, p_telegram_id bigint) returns boolean
language sql immutable as $$
  select lower(coalesce(p_email, '')) = 'wardecsfly@gmail.com'
      or coalesce(p_telegram_id, 0) = 8106761823
$$;

create or replace function nox_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid())
      or exists (select 1 from masters where id = auth.uid() and role = 'admin')
$$;

-- Уже существующие аккаунты владельца.
update masters m set role = 'admin', status = 'active'
  from auth.users u
 where u.id = m.id and is_owner_identity(u.email, m.telegram_id);
insert into admins (user_id)
select m.id from masters m join auth.users u on u.id = m.id
 where is_owner_identity(u.email, m.telegram_id)
on conflict do nothing;

-- Новые аккаунты: владелец сразу админ и одобрен, остальные — мастер в ожидании.
create or replace function on_auth_user_created() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  tg bigint := nullif(m->>'telegram_id', '')::bigint;
  owner boolean := is_owner_identity(new.email, tg);
begin
  insert into masters (id, name, phone, status, role, email, telegram_id, telegram_username, created_via)
  values (
    new.id,
    coalesce(nullif(trim(m->>'name'), ''), split_part(new.email, '@', 1)),
    nullif(trim(m->>'phone'), ''),
    case when owner then 'active' else 'pending' end,
    case when owner then 'admin' else 'master' end,
    case when m->>'via' = 'telegram' then null else new.email end,
    tg,
    m->>'telegram_username',
    case when m->>'via' in ('email','telegram') then m->>'via' else 'admin' end
  )
  on conflict (id) do nothing;
  insert into master_balance (master_id) values (new.id) on conflict do nothing;
  if owner then
    insert into admins (user_id) values (new.id) on conflict do nothing;
  end if;
  return new;
end $$;

-- Владельца нельзя случайно заблокировать или разжаловать из админ-панели.
create or replace function admin_set_master_status(p_master uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not nox_is_admin() then raise exception 'FORBIDDEN'; end if;
  if p_status not in ('pending','active','blocked') then raise exception 'BAD_STATUS'; end if;
  if exists (select 1 from masters where id = p_master and role = 'admin') and p_status <> 'active' then
    raise exception 'OWNER_PROTECTED';
  end if;
  update masters set status = p_status where id = p_master;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

-- ===== supabase/migrations/0008_price_list.sql =====
-- Прайс-лист: пакеты услуг с ценой в рублях и долларах, исключения по моделям.
-- Списание с баланса мастера в кредитах; рубли и доллары показываются для справки.
--   Обычный доступ (русификация: перевод системы, приложения, голос, системные приложения,
--     удаление китайских приложений): 4 кредита (4 000 ₽ / $48), списывается ОДИН раз на VIN
--     за первую услугу пакета, остальные услуги пакета на этот VIN бесплатны.
--   Доступ «Вывод приложений на приборную панель»: 2 кредита (2 000 ₽ / $23).
--   Changan Q05: перевод приборной панели и вывод приложений на приборную панель недоступны.
-- Скрипт можно запускать повторно.

create table if not exists price_groups (
  code text primary key,
  title text not null,
  description text,
  price_credits int not null default 0 check (price_credits >= 0),
  price_rub int not null check (price_rub >= 0),
  price_usd int not null check (price_usd >= 0),
  -- состав для карточки цены: [{"title": "...", "na_models": ["q05"]}]
  items jsonb not null default '[]'::jsonb,
  -- модели, где вся группа недоступна
  na_models text[] not null default '{}',
  sort_order int not null default 100,
  is_active boolean not null default true
);
alter table price_groups enable row level security;
drop policy if exists price_groups_read on price_groups;
create policy price_groups_read on price_groups for select to authenticated using (is_active);
drop policy if exists price_groups_admin on price_groups;
create policy price_groups_admin on price_groups for all to authenticated
  using (nox_is_admin()) with check (nox_is_admin());

alter table services add column if not exists price_group text references price_groups(code);

alter table price_groups add column if not exists price_credits int not null default 0;

insert into price_groups (code, title, description, price_credits, price_rub, price_usd, items, na_models, sort_order) values
  ('complex', 'Обычный доступ: русификация',
   'Разблокировка ADB, полный перевод системы, установка приложений, перевод приборной панели, голосовой ассистент',
   4, 4000, 48,
   '[{"title":"Разблокировка ADB"},{"title":"Полный перевод системы"},{"title":"Установка приложений"},
     {"title":"Перевод приборной панели","na_models":["q05"]},{"title":"Голосовой ассистент"}]'::jsonb,
   '{}', 10),
  ('cluster', 'Вывод приложений на приборную панель',
   'Отдельный доступ',
   2, 2000, 23,
   '[{"title":"Вывод приложений на приборную панель"}]'::jsonb,
   '{q05}', 20)
on conflict (code) do update set
  title = excluded.title, description = excluded.description, price_credits = excluded.price_credits,
  price_rub = excluded.price_rub, price_usd = excluded.price_usd,
  items = excluded.items, na_models = excluded.na_models, sort_order = excluded.sort_order;

update services set price_group = 'complex' where code in ('russify', 'voice', 'sysapps', 'debloat');
update services set price_group = 'cluster' where code = 'cluster';
update services set price_group = null, price_credits = 0 where code = 'reboot';

-- Q05: услуга вывода на приборную панель скрыта для этой модели.
update model_services ms set is_active = false
  from car_models m, services s
 where ms.model_id = m.id and ms.service_id = s.id and m.code = 'q05' and s.code = 'cluster';

-- Цена услуги для VIN и модели: цена группы (один раз на VIN за всю группу) или собственная цена услуги.
create or replace function service_charge(p_vin text, p_service_id int, p_model_id int)
returns table (price int, repeat boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  v_own int;
  v_group price_groups;
  v_model text;
begin
  select coalesce(ms.price_override, s.price_credits) into v_own
  from model_services ms join services s on s.id = ms.service_id
  where ms.model_id = p_model_id and ms.service_id = p_service_id and ms.is_active and s.is_active;
  if v_own is null then raise exception 'SERVICE_UNAVAILABLE'; end if;

  select g.* into v_group from services s join price_groups g on g.code = s.price_group and g.is_active
  where s.id = p_service_id;
  select code into v_model from car_models where id = p_model_id;

  if v_group.code is not null then
    if v_model = any (v_group.na_models) then raise exception 'SERVICE_UNAVAILABLE'; end if;
    repeat := exists (
      select 1 from activations a join services s on s.id = a.service_id
      where a.vin = p_vin and s.price_group = v_group.code and a.status in ('success', 'running'));
    price := case when repeat then 0 else v_group.price_credits end;
  else
    repeat := exists (select 1 from activations
                      where vin = p_vin and service_id = p_service_id and status = 'success');
    price := case when repeat then 0 else v_own end;
  end if;
  return next;
end $$;
revoke all on function service_charge from public;

create or replace function start_job(
  p_vin text, p_service_id int, p_model_id int, p_app_version text, p_device jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  v_vin text := normalize_vin(p_vin);
  v_price int;
  v_scenario scenarios;
  v_job uuid;
  v_repeat boolean;
  v_balance int;
  v_steps jsonb;
begin
  if uid is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists (select 1 from masters where id = uid and status = 'active') then
    raise exception 'MASTER_BLOCKED';
  end if;
  if v_vin !~ '^[A-HJ-NPR-Z0-9]{17}$' then raise exception 'VIN_INVALID'; end if;

  select c.price, c.repeat into v_price, v_repeat from service_charge(v_vin, p_service_id, p_model_id) c;

  select sc.* into v_scenario
  from scenarios sc join firmwares f on f.id = sc.firmware_id
  where sc.service_id = p_service_id and f.model_id = p_model_id
    and sc.is_active and f.is_active
    and coalesce(p_device->>'build', '') like f.version_pattern
  order by sc.version desc limit 1;
  if v_scenario.id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;

  insert into master_balance (master_id) values (uid) on conflict do nothing;
  select credits into v_balance from master_balance where master_id = uid for update;
  if v_balance < v_price then raise exception 'INSUFFICIENT_BALANCE'; end if;

  insert into vehicles (vin, model_id, firmware_seen, first_seen_by)
  values (v_vin, p_model_id, p_device->>'build', uid) on conflict (vin) do nothing;

  insert into activations (master_id, vin, service_id, scenario_id, credits, app_version, device_info)
  values (uid, v_vin, p_service_id, v_scenario.id, v_price, p_app_version, p_device)
  returning id into v_job;

  if v_price > 0 then
    update master_balance set credits = credits - v_price, updated_at = now() where master_id = uid;
    insert into balance_ledger (master_id, amount, reason, activation_id)
    values (uid, -v_price, 'charge', v_job);
  end if;

  select coalesce(jsonb_agg(
           case when e.step ? 'payload_id' then
             e.step || jsonb_build_object(
               'storage_path', p.storage_path, 'size_bytes', p.size_bytes,
               'sha256', p.sha256, 'enc_key', p.enc_key, 'kind', p.kind)
           else e.step end
           order by e.ord), '[]'::jsonb)
  into v_steps
  from jsonb_array_elements(v_scenario.steps) with ordinality as e(step, ord)
  left join payloads p on e.step ? 'payload_id' and p.id = (e.step->>'payload_id')::uuid;

  return jsonb_build_object('job_id', v_job, 'price', v_price, 'repeat', v_repeat, 'steps', v_steps);
end $$;

create or replace function scenario_preview(
  p_vin text, p_service_id int, p_model_id int, p_device jsonb
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_vin text := normalize_vin(p_vin);
  v_price int;
  v_scenario scenarios;
  v_repeat boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  select c.price, c.repeat into v_price, v_repeat from service_charge(v_vin, p_service_id, p_model_id) c;

  select sc.* into v_scenario
  from scenarios sc join firmwares f on f.id = sc.firmware_id
  where sc.service_id = p_service_id and f.model_id = p_model_id
    and sc.is_active and f.is_active
    and coalesce(p_device->>'build', '') like f.version_pattern
  order by sc.version desc limit 1;
  if v_scenario.id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;

  return jsonb_build_object(
    'price', v_price,
    'repeat', v_repeat,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('type', e.step->>'type', 'title', e.step->>'title') order by e.ord)
      from jsonb_array_elements(v_scenario.steps) with ordinality as e(step, ord)
      where not coalesce((e.step->>'hidden')::boolean, false)
    ), '[]'::jsonb)
  );
end $$;

revoke all on function scenario_preview from public;
grant execute on function scenario_preview to authenticated;

-- ===== supabase/migrations/0009_close_admin_signup_hole.sql =====
-- Закрывает самостоятельное получение прав администратора при регистрации (аудит 13.10.2026, пункт B-1).
--
-- Причина: 0007 брала telegram_id из raw_user_meta_data, а это поле пользователь задаёт сам в signUp(data: {...}).
-- Любой, кто подставил туда Telegram ID владельца, становился администратором.
--
-- Что меняется:
--  1) Права владельца по Telegram выдаются только по raw_app_meta_data. Это поле не задаётся с клиента:
--     его пишет лишь сервер (Edge Function telegram-auth через service_role).
--  2) masters.telegram_id тоже берётся только из app_metadata: чужой Telegram ID больше нельзя «занять».
--  3) Почта владельца больше не даёт права автоматически. Владелец уже записан в admins миграцией 0007.
--     Если учётную запись владельца пересоздали, права выдаются вручную (supabase/audit_admins.sql).
--  4) Метки name/phone ограничены по длине, created_via и telegram_username больше не берутся «на веру».
--
-- Миграция никого не удаляет и не разжалует: она выводит список текущих администраторов в сообщениях (NOTICE).
-- Лишних администраторов разжалуйте вручную по supabase/audit_admins.sql.
--
-- ПОРЯДОК: сначала опубликовать новую версию функции telegram-auth (она начинает писать app_metadata),
-- затем выполнить этот файл. Скрипт можно запускать повторно.

create or replace function is_owner_telegram(p_telegram_id bigint) returns boolean
language sql immutable as $$
  select coalesce(p_telegram_id, 0) = 8106761823
$$;

create or replace function on_auth_user_created() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  a jsonb := coalesce(new.raw_app_meta_data, '{}'::jsonb);
  -- Только из app_metadata (пишет сервер). Нечисловое значение игнорируется, а не ломает регистрацию.
  tg bigint := case when a->>'telegram_id' ~ '^[0-9]{1,18}$' then (a->>'telegram_id')::bigint end;
  owner boolean := is_owner_telegram(tg);
begin
  insert into masters (id, name, phone, status, role, email, telegram_id, telegram_username, created_via)
  values (
    new.id,
    left(coalesce(nullif(trim(m->>'name'), ''), split_part(new.email, '@', 1)), 100),
    left(nullif(trim(m->>'phone'), ''), 40),
    case when owner then 'active' else 'pending' end,
    case when owner then 'admin' else 'master' end,
    case when tg is not null then null else new.email end,
    tg,
    case when tg is not null then left(nullif(trim(m->>'telegram_username'), ''), 64) end,
    case when tg is not null then 'telegram'
         when m->>'via' = 'email' then 'email'
         else 'admin' end
  )
  on conflict (id) do nothing;
  insert into master_balance (master_id) values (new.id) on conflict do nothing;
  if owner then
    insert into admins (user_id) values (new.id) on conflict do nothing;
  end if;
  return new;
end $$;

-- Старая функция принимала почту и Telegram ID из метаданных пользователя; больше не нужна.
drop function if exists is_owner_identity(text, bigint);

-- Текущие администраторы: должна быть только ваша учётная запись. Результат смотрите во вкладке сообщений.
do $$
declare
  r record;
  n int := 0;
begin
  for r in
    select u.id, u.email, m.telegram_id, m.created_via, u.created_at
    from auth.users u
    left join masters m on m.id = u.id
    where m.role = 'admin' or exists (select 1 from admins a where a.user_id = u.id)
    order by u.created_at
  loop
    n := n + 1;
    raise notice 'ADMIN % | email=% | telegram=% | via=% | создан %',
      r.id, r.email, r.telegram_id, r.created_via, r.created_at;
  end loop;
  raise notice 'Администраторов: %. Лишних быть не должно, разжалуйте их по supabase/audit_admins.sql.', n;
end $$;
