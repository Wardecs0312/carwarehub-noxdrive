-- CarWareHubNoxDrive: начальная схема.
-- Каталоги (бренды, модели, прошивки, услуги, сценарии) хранятся в данных,
-- приложение загружает их динамически. Новая модель или услуга = строка в таблице.

create extension if not exists pgcrypto;

-- ---------- Администраторы и мастера ----------
create table admins (user_id uuid primary key references auth.users on delete cascade);

create function is_admin() returns boolean language sql stable security definer as
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
    execute format('create policy %I_admin on %I for all to authenticated using (is_admin()) with check (is_admin())', t, t);
  end loop;
end $$;

-- Свои данные
create policy masters_self on masters for select to authenticated using (id = auth.uid() or is_admin());
create policy balance_self on master_balance for select to authenticated using (master_id = auth.uid() or is_admin());
create policy ledger_self on balance_ledger for select to authenticated using (master_id = auth.uid() or is_admin());
create policy req_self on activation_requests for select to authenticated using (master_id = auth.uid() or is_admin());
create policy req_insert on activation_requests for insert to authenticated with check (master_id = auth.uid());
create policy code_self on activation_codes for select to authenticated using (master_id = auth.uid() or is_admin());
create policy act_self on activations for select to authenticated using (master_id = auth.uid() or is_admin());
create policy refund_self on refund_requests for select to authenticated using (master_id = auth.uid() or is_admin());
create policy refund_insert on refund_requests for insert to authenticated with check (master_id = auth.uid());
create policy refund_admin on refund_requests for update to authenticated using (is_admin());
create policy admins_admin on admins for select to authenticated using (is_admin());
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
