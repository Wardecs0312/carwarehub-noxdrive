// Проверка миграций Supabase на настоящем PostgreSQL (PGlite, без Docker и без доступа к вашей базе).
// Прогоняет supabase/migrations/*.sql по порядку на заглушках схем auth/storage и пробует атаку
// «админом через регистрацию» (аудит 13.10.2026, B-1).
//
// Запуск (папка с зависимостью создаётся отдельно, в репозиторий ничего не ставится):
//   mkdir %TEMP%\pglite-test && cd %TEMP%\pglite-test && npm init -y && npm i @electric-sql/pglite --ignore-scripts
//   copy <репозиторий>\tool\migration_test\run.mjs . && node run.mjs <путь к репозиторию> [последняя миграция, по умолчанию 0009]
// Контроль: `node run.mjs <репозиторий> 0008` обязан показать FAIL по пунктам «атака через user_metadata».
// Прогон миграций 0001-0009 на PGlite с заглушками схем Supabase (auth, storage, роли).
import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const repo = process.argv[2];
const upTo = process.argv[3] ?? '0009';
process.on("uncaughtException", e => { console.log("ОШИБКА:", String(e.message||e).slice(0,300)); process.exit(2); });
const db = new PGlite({ extensions: { pgcrypto } });

// --- заглушки Supabase ---
await db.exec(`
  create role anon nologin; create role authenticated nologin; create role service_role nologin;
  create schema auth;
  create table auth.users (
    id uuid primary key default gen_random_uuid(),
    email text unique,
    email_confirmed_at timestamptz,
    raw_user_meta_data jsonb,
    raw_app_meta_data jsonb,
    created_at timestamptz not null default now(),
    last_sign_in_at timestamptz
  );
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
  .filter(f => f.slice(0, 4) <= upTo);
for (const f of files) {
  try {
    await db.exec(readFileSync(join(dir, f), 'utf8'));
    console.log('OK   ', f);
  } catch (e) {
    console.log('FAIL ', f, '->', e.message);
    process.exit(1);
  }
}

// --- проверки ---
const OWNER_TG = 8106761823;
let failed = 0;
const check = (name, cond, extra = '') => {
  console.log(cond ? 'PASS ' : 'FAIL ', name, extra);
  if (!cond) failed++;
};
const insertUser = async (email, meta, app) => {
  const r = await db.query(
    `insert into auth.users (email, raw_user_meta_data, raw_app_meta_data)
     values ($1, $2::jsonb, $3::jsonb) returning id`,
    [email, JSON.stringify(meta), JSON.stringify(app)]);
  return r.rows[0].id;
};
const master = async (id) =>
  (await db.query('select role, status, telegram_id, created_via, email, telegram_username from masters where id=$1', [id])).rows[0];
const inAdmins = async (id) =>
  (await db.query('select 1 from admins where user_id=$1', [id])).rows.length > 0;
const asUser = async (id, fn) => {
  await db.exec(`set request.jwt.claim.sub = '${id}'`);
  try { return await fn(); } finally { await db.exec(`reset request.jwt.claim.sub`); }
};

// 1. Атака из аудита: telegram_id владельца в user_metadata при обычной регистрации.
{
  const id = await insertUser('attacker@example.com',
    { via: 'telegram', telegram_id: OWNER_TG, telegram_username: 'x', name: 'evil' }, {});
  const m = await master(id);
  check('атака через user_metadata: НЕ администратор', m.role === 'master' && m.status === 'pending', JSON.stringify(m));
  check('атака через user_metadata: нет записи в admins', !(await inAdmins(id)));
  check('атака через user_metadata: telegram_id не присвоен', m.telegram_id === null);
  check('атака через user_metadata: nox_is_admin() = false',
    await asUser(id, async () => (await db.query('select nox_is_admin() as a')).rows[0].a === false));
}

// 2. Тот же приём с почтой владельца (учётной записи ещё нет).
{
  const id = await insertUser('wardecsfly@gmail.com', { via: 'email' }, {});
  const m = await master(id);
  check('почта владельца без app_metadata: НЕ администратор', m.role === 'master' && m.status === 'pending');
  await db.query('delete from master_balance where master_id=$1', [id]);
  await db.query('delete from masters where id=$1', [id]);
  await db.query('delete from auth.users where id=$1', [id]);
}

// 3. Законный владелец через Telegram: app_metadata пишет сервер.
{
  const id = await insertUser(`tg-${OWNER_TG}@telegram.nox.drive`,
    { via: 'telegram', name: 'Owner', telegram_id: OWNER_TG }, { telegram_id: OWNER_TG });
  const m = await master(id);
  check('владелец по app_metadata: admin + active', m.role === 'admin' && m.status === 'active', JSON.stringify(m));
  check('владелец по app_metadata: есть в admins', await inAdmins(id));
  check('владелец по app_metadata: created_via = telegram', m.created_via === 'telegram');
  check('владелец по app_metadata: nox_is_admin() = true',
    await asUser(id, async () => (await db.query('select nox_is_admin() as a')).rows[0].a === true));
}

// 4. Обычный мастер через Telegram: pending.
{
  const id = await insertUser('tg-111@telegram.nox.drive',
    { via: 'telegram', name: 'Master', telegram_id: 111 }, { telegram_id: 111 });
  const m = await master(id);
  check('мастер Telegram: pending/master, telegram_id сохранён',
    m.role === 'master' && m.status === 'pending' && String(m.telegram_id) === '111', JSON.stringify(m));
}

// 5. Обычная регистрация по почте.
{
  const id = await insertUser('master@example.com', { via: 'email', name: 'Иван', phone: '+996' }, {});
  const m = await master(id);
  check('почта: pending/master/email', m.role === 'master' && m.status === 'pending' && m.created_via === 'email' && m.email === 'master@example.com', JSON.stringify(m));
}

// 6. Занять чужой Telegram ID через user_metadata нельзя: настоящий пользователь регистрируется без ошибки.
{
  await insertUser('squat@example.com', { via: 'telegram', telegram_id: 222 }, {});
  let ok = true;
  try { await insertUser('tg-222@telegram.nox.drive', { via: 'telegram', telegram_id: 222 }, { telegram_id: 222 }); }
  catch (e) { ok = false; console.log('     ', e.message); }
  check('занять чужой telegram_id через user_metadata нельзя', ok);
}

// 7. Мусор в app_metadata не ломает регистрацию.
{
  let ok = true;
  try { await insertUser('junk@example.com', {}, { telegram_id: 'abc; drop table masters' }); } catch { ok = false; }
  check('нечисловой telegram_id в app_metadata игнорируется', ok);
}

// 8. Длинные метки обрезаются.
{
  const id = await insertUser('long@example.com', { name: 'A'.repeat(500) }, {});
  const r = (await db.query('select length(name) as n from masters where id=$1', [id])).rows[0];
  check('имя обрезается до 100', r.n === 100, String(r.n));
}

// 9. Старая функция удалена, повторный запуск миграции проходит.
{
  const r = await db.query(`select count(*)::int as n from pg_proc where proname = 'is_owner_identity'`);
  check('is_owner_identity удалена', r.rows[0].n === 0);
  try {
    await db.exec(readFileSync(join(dir, files[files.length - 1]), 'utf8'));
    check('повторный запуск 0009 проходит', true);
  } catch (e) { check('повторный запуск 0009 проходит', false, e.message); }
}

console.log(failed === 0 ? '\nВСЕ ПРОВЕРКИ ПРОЙДЕНЫ' : `\nПРОВАЛЕНО: ${failed}`);
process.exit(failed === 0 ? 0 : 1);
