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
  .filter(f => f <= '0011' || f.startsWith('0011') || f.startsWith('20261015') || f.startsWith('20261016'));
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

console.log(failed ? `\nПРОВАЛЕНО: ${failed}` : '\nВСЁ ПРОЙДЕНО');
process.exit(failed ? 1 : 0);
