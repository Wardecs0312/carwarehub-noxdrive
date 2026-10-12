
-- Все миграции одним файлом для вставки в SQL Editor Supabase (собрано из supabase/migrations/0001-0004).
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
