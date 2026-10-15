// Проверка 20261015_04: начисление/списание, сверка, защита баланса.
// Нужен файл stubs.sql с заглушками Supabase (возьмите блок db.exec из run.mjs).
import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const repo = process.argv[2];
const db = new PGlite({ extensions: { pgcrypto } });
await db.exec(readFileSync('stubs.sql', 'utf8'));
const dir = join(repo, 'supabase', 'migrations');
const all = readdirSync(dir).filter(f => f.endsWith('.sql')).sort();
const before = all.filter(f => f <= '0011_z' || f.startsWith('20261015_01'));
for (const f of before) await db.exec(readFileSync(join(dir, f), 'utf8'));

let failed = 0;
const check = (n, c, x = '') => { console.log(c ? 'PASS ' : 'FAIL ', n, x); if (!c) failed++; };
const as = async (id, fn) => { await db.exec(`set request.jwt.claim.sub = '${id}'`); try { return await fn(); } finally { await db.exec('reset request.jwt.claim.sub'); } };
const err = async (fn) => { try { await fn(); return null; } catch (e) { return e.message; } };

const user = async (email) => (await db.query(`insert into auth.users (email, raw_user_meta_data) values ($1, '{"via":"email"}') returning id`, [email])).rows[0].id;
const admin = await user('admin@x');
await db.query(`insert into admins (user_id) values ($1)`, [admin]);
const m = await user('m@x');
const oma = await user('oma@x');
// как в бою: админ пополнил на 10000 через функцию, а 100 вписали в таблицу напрямую
await as(admin, () => db.query(`select admin_topup($1, 10000)`, [oma]));
await db.query(`update master_balance set credits = credits + 100 where master_id = $1`, [oma]);

// применяем миграцию контроля кредитов
await db.exec(readFileSync(join(dir, '20261015_04_credit_control.sql'), 'utf8'));
const bal = async (id) => (await db.query('select credits from master_balance where master_id=$1', [id])).rows[0].credits;
const ledger = async (id) => (await db.query('select coalesce(sum(amount),0)::int s from balance_ledger where master_id=$1', [id])).rows[0].s;

check('сверка: баланс OMA не изменился (10100)', await bal(oma) === 10100);
check('сверка: журнал OMA теперь тоже 10100', await ledger(oma) === 10100);

const r1 = await as(admin, () => db.query(`select admin_adjust_credits($1, 50, 'пополнение наличными') as v`, [m]));
check('начисление +50', r1.rows[0].v === 50 && await bal(m) === 50 && await ledger(m) === 50);
const r2 = await as(admin, () => db.query(`select admin_adjust_credits($1, -20, 'ошибочное начисление') as v`, [m]));
check('списание -20', r2.rows[0].v === 30 && await bal(m) === 30 && await ledger(m) === 30);
check('списать больше, чем есть, нельзя', (await err(() => as(admin, () => db.query(`select admin_adjust_credits($1, -31, 'тест')`, [m])))) ?.includes('NOT_ENOUGH_CREDITS'));
check('без причины нельзя', (await err(() => as(admin, () => db.query(`select admin_adjust_credits($1, 5, '')`, [m])))) ?.includes('REASON_REQUIRED'));
check('мастер не может себе начислить', (await err(() => as(m, () => db.query(`select admin_adjust_credits($1, 5, 'хочу')`, [m])))) ?.includes('FORBIDDEN'));
const note = (await db.query(`select note from balance_ledger where master_id=$1 and amount=-20`, [m])).rows[0]?.note;
check('причина записана в журнал', note === 'ошибочное начисление');

check('ручная правка баланса мимо журнала отклоняется',
  (await err(() => db.query(`update master_balance set credits = credits + 500 where master_id = $1`, [m]))) ?.includes('BALANCE_WITHOUT_LEDGER'));
check('после отказа баланс не изменился', await bal(m) === 30);

// функции программы продолжают работать
await as(admin, () => db.query(`select admin_topup($1, 7)`, [m]));
check('admin_topup работает', await bal(m) === 37 && await ledger(m) === 37);
const newbie = await user('new@x');
check('новый мастер регистрируется (баланс 0)', await bal(newbie) === 0);

console.log(failed ? `\nПРОВАЛЕНО: ${failed}` : '\nВСЁ ПРОЙДЕНО');
process.exit(failed ? 1 : 0);
