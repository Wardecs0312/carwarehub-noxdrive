// Проверка миграции 20261015_01: бесплатный повтор только для того же ГУ.
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
  .filter(f => f <= '0011' || f.startsWith('0011') || f.startsWith('20261015') || (f.startsWith('20261016_0') && !f.includes('alish')) || f.startsWith('20261018_01') || f.startsWith('20261018_03'));
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
  await db.transaction(async (tx) => {
    await tx.query(`update master_balance set credits = 100 where master_id = $1`, [id]);
    await tx.query(`insert into balance_ledger (master_id, amount, reason) values ($1, 100, 'topup')`, [id]);
  });
  return id;
};

const A = await newMaster('a@example.com');
const B = await newMaster('b@example.com');
const hdr = (ip) => db.exec(`set request.headers = '{"x-forwarded-for":"${ip}, 10.0.0.1"}'`);
const geo = JSON.stringify({ ip: '5.59.1.1', country: 'Кыргызстан', city: 'Бишкек' });

await hdr('5.59.1.1');
await asUser(A, () => db.query(`select master_login_event('2.0.21+21', 'windows', 'PC-1', $1::jsonb)`, [geo]));
await asUser(A, () => db.query(`select master_login_event('2.0.21+21', 'windows', 'PC-1', $1::jsonb)`, [geo]));
let ev = (await db.query(`select * from login_events where master_id = $1`, [A])).rows;
check('вход записан один раз (повтор за минуту игнорируется)', ev.length === 1);
check('IP взят с сервера', ev[0].ip === '5.59.1.1', ev[0].ip);
check('страна и город', ev[0].country === 'Кыргызстан' && ev[0].city === 'Бишкек');

await asUser(A, () => db.query(`select master_heartbeat('job', '2.0.21+21', 'windows', 'PC-1', null)`));
let p = (await db.query(`select * from master_presence where master_id = $1`, [A])).rows[0];
check('сердцебиение: статус job, страна сохранилась', p.activity === 'job' && p.country === 'Кыргызстан');
await asUser(A, () => db.query(`select master_heartbeat('hack', null, null, null, null)`));
p = (await db.query(`select * from master_presence where master_id = $1`, [A])).rows[0];
check('неизвестный статус → online, версия не затёрта', p.activity === 'online' && p.app_version === '2.0.21+21');

// RLS: B не видит A, видит себя
await asUser(B, () => db.query(`select master_heartbeat('online', 'v', 'web', 'phone', null)`));
const seen = async (who, table) => { await db.exec('set role authenticated'); try {
  return await asUser(who, async () => (await db.query(`select master_id from ${table}`)).rows.map(r => r.master_id)); } finally { await db.exec('reset role'); } };
const bSees = await seen(B, 'master_presence');
check('мастер видит только себя', bSees.length === 1 && bSees[0] === B);
check('мастер не видит чужие входы', (await seen(B, 'login_events')).length === 0);

const anonDenied = async (sql) => { await db.exec('set role anon'); try { await db.query(sql); return false; } catch { return true; } finally { await db.exec('reset role'); } };
check('anon не вызывает heartbeat', await anonDenied(`select master_heartbeat('online', 'v', 'w', 'd', null)`));
check('anon не читает присутствие', await anonDenied(`select * from master_presence`));

// Вход на сайт по нику: почта выдаётся только для админа.
await db.query(`alter table masters add column if not exists telegram_username text`);
await db.query(`alter table masters add column if not exists role text default 'master'`);
await db.query(`update masters set telegram_username = 'AdminNick', role = 'admin' where id = $1`, [A]);
await db.query(`update masters set telegram_username = 'MasterNick' where id = $1`, [B]);
const loginEmail = async (u) => { await db.exec('set role anon'); try {
  return (await db.query(`select admin_login_email($1) as e`, [u])).rows[0].e; } finally { await db.exec('reset role'); } };
check('ник админа → его почта', (await loginEmail('@adminnick')) === 'a@example.com');
check('ник мастера → ничего', (await loginEmail('MasterNick')) === null);
check('несуществующий ник → ничего', (await loginEmail('@nobody')) === null);


// --- зависшие задания и трансляции
await db.query(`insert into stream_sessions (master_id, requested_by, sources, status, created_at, started_at) values ($1,$1,'{camera}','live', now()-interval '1 hour', now()-interval '1 hour')`, [B]);
await db.query(`update master_presence set last_seen = now() - interval '10 minutes' where master_id = $1`, [B]);
await db.query(`insert into stream_sessions (master_id, requested_by, sources, status, created_at) values ($1,$1,'{camera}','live', now()-interval '1 hour')`, [A]);
await db.query(`update master_presence set last_seen = now() where master_id = $1`, [A]);
await db.query(`select expire_stale_jobs()`);
const st = (await db.query(`select master_id, status from stream_sessions`)).rows;
check('трансляция пропавшего мастера закрыта', st.find(r=>r.master_id===B).status==='ended');
check('трансляция мастера в сети не тронута', st.find(r=>r.master_id===A).status==='live');
await db.query(`update scenarios set steps = '[{"type":"shell","title":"x","cmd":"cmd overlay enable com.a"},{"type":"reboot","title":"r"}]'::jsonb where id = (select id from scenarios limit 1)`);
const mig = (await import('node:fs')).readFileSync(process.argv[2]+'/supabase/migrations/20261018_01_stale_jobs_streams_overlay.sql','utf8');
await db.exec(mig);
const steps = (await db.query(`select steps from scenarios where steps::text like '%overlay%' limit 1`)).rows[0].steps;
check('overlay: ignore_errors добавлен, порядок шагов тот же', steps[0].ignore_errors===true && steps[1].type==='reboot', JSON.stringify(steps));


// --- заранее скачанные файлы и пульс задания
await db.exec((await import('node:fs')).readFileSync(process.argv[2]+'/supabase/migrations/20261018_03_prefetch_heartbeat.sql','utf8'));
const pid = (await db.query(`insert into payloads (storage_path, kind, size_bytes, sha256) values ('voice/t.enc','bin',1,'00') returning id`)).rows[0].id;
await db.query(`update scenarios set steps = steps || jsonb_build_array(jsonb_build_object('type','push_file','payload_id',$1::text)) where id = (select s.id from scenarios s where s.is_active limit 1)`, [pid]);
const anyPay = (await db.query(`select p.storage_path, f.model_id from scenarios s join firmwares f on f.id=s.firmware_id cross join lateral jsonb_array_elements(s.steps) e join payloads p on p.id::text = e->>'payload_id' where s.is_active limit 1`)).rows[0];
if (anyPay) {
  const paths = await asUser(A, async () => (await db.query(`select payloads_for_model($1) as p`, [anyPay.model_id])).rows.map(r => r.p));
  check('активный мастер получает список файлов модели', paths.includes(anyPay.storage_path), paths.length);
  check('активный мастер может читать файл без услуги', (await asUser(A, async () => (await db.query(`select can_read_payload($1) as ok`, [anyPay.storage_path])).rows[0].ok)) === true);
  await db.query(`update masters set status='blocked' where id=$1`, [B]);
  check('заблокированный мастер — нет', (await asUser(B, async () => (await db.query(`select can_read_payload($1) as ok`, [anyPay.storage_path])).rows[0].ok)) === false);
} else console.log('нет сценариев с файлами в тестовой базе — проверка файлов пропущена');
const job = (await db.query(`insert into activations (master_id, vin, service_id, status, created_at) select $1, 'X', id, 'running', now()-interval '10 minutes' from services limit 1 returning id`, [A])).rows[0].id;
await asUser(A, () => db.query(`select job_heartbeat($1)`, [job]));
await db.query(`update activations set heartbeat_at = now() - interval '6 minutes' where id=$1`, [job]);
await db.query(`select expire_stale_jobs()`);
check('задание без отметок 6 минут снято', (await db.query(`select status from activations where id=$1`, [job])).rows[0].status === 'failed');

console.log(failed ? `\nПРОВАЛЕНО: ${failed}` : '\nВСЁ ПРОЙДЕНО');
process.exit(failed ? 1 : 0);
