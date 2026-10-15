// Проверка миграции 20261015_01: бесплатный повтор только для того же ГУ.
// Запуск: как run.mjs (см. его шапку), затем node repeat_test.mjs <путь к репозиторию>
import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const repo = process.argv[2];
const db = new PGlite({ extensions: { pgcrypto } });
await db.exec(`
  create role anon nologin; create role authenticated nologin; create role service_role nologin;
  create schema auth;
  create table auth.users (id uuid primary key default gen_random_uuid(), email text unique,
    email_confirmed_at timestamptz, raw_user_meta_data jsonb, raw_app_meta_data jsonb,
    created_at timestamptz not null default now(), last_sign_in_at timestamptz);
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  create schema storage;
  create table storage.buckets (id text primary key, name text, public boolean);
  create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
  alter table storage.objects enable row level security;
  create publication supabase_realtime;
`);
const dir = join(repo, 'supabase', 'migrations');
const files = readdirSync(dir).filter(f => f.endsWith('.sql')).sort()
  .filter(f => f <= '0011' || f.startsWith('0011') || f.startsWith('20261015'));
for (const f of files) {
  try { await db.exec(readFileSync(join(dir, f), 'utf8')); console.log('OK   ', f); }
  catch (e) { console.log('FAIL ', f, '->', e.message); process.exit(1); }
}

let failed = 0;
const check = (name, cond, extra = '') => { console.log(cond ? 'PASS ' : 'FAIL ', name, extra); if (!cond) failed++; };
const asUser = async (id, fn) => {
  await db.exec(`set request.jwt.claim.sub = '${id}'`);
  try { return await fn(); } finally { await db.exec(`reset request.jwt.claim.sub`); }
};
const newMaster = async (email) => {
  const id = (await db.query(`insert into auth.users (email, raw_user_meta_data) values ($1, '{"via":"email"}') returning id`, [email])).rows[0].id;
  await db.query(`update masters set status = 'active' where id = $1`, [id]);
  await db.query(`update master_balance set credits = 100 where master_id = $1`, [id]);
  return id;
};

// Услуга со сценарием и платной группой: берём ту, у которой есть сценарий для модели.
const svc = (await db.query(`
  select s.id as sid, s.price_group, f.model_id as mid
  from scenarios sc join services s on s.id = sc.service_id join firmwares f on f.id = sc.firmware_id
  where sc.is_active order by s.price_group nulls last limit 1`)).rows[0];
await db.query(`update services set price_credits = 4 where id = $1`, [svc.sid]);
await db.query(`update price_groups set price_credits = 4`);
console.log('услуга', svc);

const VIN = 'LS5A3ABC1NA000123';
const A = await newMaster('a@example.com');
const B = await newMaster('b@example.com');
const dev = (hu, serial = hu) => JSON.stringify({ build: 'X', model: 'Q05', serial, hu_serial: hu });
const devOld = (serial) => JSON.stringify({ build: 'X', model: 'Q05', serial }); // старая версия программы

const start = (who, device) => asUser(who, async () =>
  (await db.query(`select start_job($1, $2, $3, '2.0.14+14', $4::jsonb) as r`, [VIN, svc.sid, svc.mid, device])).rows[0].r);
const preview = (who, device) => asUser(who, async () =>
  (await db.query(`select scenario_preview($1, $2, $3, $4::jsonb) as r`, [VIN, svc.sid, svc.mid, device])).rows[0].r);

const first = await start(A, dev('HU-111'));
check('первый раз платно', first.price === 4, JSON.stringify({ price: first.price }));
await asUser(A, () => db.query(`select finish_job($1, true, 'ok')`, [first.job_id]));

check('та же машина, тот же мастер: бесплатно', (await preview(A, dev('HU-111'))).price === 0);
check('та же машина, другой мастер: бесплатно', (await preview(B, dev('HU-111'))).price === 0);
check('другая машина с тем же VIN: платно', (await preview(A, dev('HU-222'))).price === 4);
check('другой мастер, другая машина, тот же VIN: платно', (await preview(B, dev('HU-333'))).price === 4);
check('старая версия по USB, та же машина: бесплатно', (await preview(A, devOld('HU-111'))).price === 0);
check('старая версия по сети (IP:порт): платно', (await preview(A, devOld('192.168.1.5:5555'))).price === 4);
check('без номера ГУ: платно', (await preview(A, JSON.stringify({ build: 'X' }))).price === 4);

const again = await start(A, dev('HU-222'));
check('start_job на другой машине списывает 4', again.price === 4 && again.repeat === false);
const bal = (await db.query('select credits from master_balance where master_id = $1', [A])).rows[0].credits;
check('баланс A = 100 - 4 - 4', bal === 92, `credits=${bal}`);

// Права: аноним не вызывает функции
const anonDenied = async (sql) => {
  await db.exec('set role anon');
  try { await db.query(sql); return false; } catch { return true; } finally { await db.exec('reset role'); }
};
check('anon не может вызвать service_charge', await anonDenied(`select * from service_charge('${VIN}', 1, 1, 'x')`));
check('anon не может вызвать start_job', await anonDenied(`select start_job('${VIN}', 1, 1, 'v', '{}'::jsonb)`));

console.log(failed ? `\nПРОВАЛЕНО: ${failed}` : '\nВСЁ ПРОЙДЕНО');
process.exit(failed ? 1 : 0);
