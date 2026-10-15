// Вход и регистрация мастера через Telegram-бота + заявки на одобрение администратору.
//
// 1. Программа: {action:"start"} -> одноразовый код и ссылка t.me/<бот>?start=<код>.
// 2. Мастер жмёт «Старт» в боте -> Telegram присылает сюда webhook, код подтверждается.
// 3. Программа опрашивает {action:"poll", nonce} -> при подтверждении получает token_hash
//    и входит через supabase.auth.verifyOTP(type: magiclink). Новый мастер создаётся со статусом pending:
//    работать он не может, пока админ не одобрит.
// 4. О каждом новом мастере (Telegram или почта, {action:"notify_signup"}) бот пишет всем админам,
//    у которых привязан Telegram, сообщение с кнопками «Одобрить» / «Отклонить».
//
// Секрет (задаёт владелец): TELEGRAM_BOT_TOKEN. Необязательные: TELEGRAM_BOT_USERNAME (по умолчанию
// NoxDrive_Bot), TELEGRAM_WEBHOOK_SECRET (по умолчанию выводится из токена бота).
// Подключение бота к функции: админ нажимает «Подключить Telegram-бота» в админ-панели ({action:"setup_webhook"}).
// Функция деплоится с выключенной проверкой JWT (webhook Telegram приходит без него).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

const CODE_TTL_MS = 10 * 60 * 1000;
const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN");
const botUsername = Deno.env.get("TELEGRAM_BOT_USERNAME") ?? "NoxDrive_Bot";

// Секрет webhook: из переменной или SHA-256 от токена бота (знает только сервер; Telegram допускает [A-Za-z0-9_-]).
async function getWebhookSecret(): Promise<string> {
  const fromEnv = Deno.env.get("TELEGRAM_WEBHOOK_SECRET");
  if (fromEnv) return fromEnv;
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${botToken}:nox-webhook`));
  return Array.from(new Uint8Array(d), (x) => x.toString(16).padStart(2, "0")).join("");
}

// Подключение бота к этой функции. Только для админа (проверка по его входу в программе).
async function setupWebhook(req: Request) {
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: isAdmin } = await db.rpc("nox_is_admin");
  if (isAdmin !== true) return json({ error: "FORBIDDEN" }, 403);
  const url = `${Deno.env.get("SUPABASE_URL")}/functions/v1/telegram-auth`;
  const r = await tg("setWebhook", {
    url,
    secret_token: await getWebhookSecret(),
    allowed_updates: ["message", "callback_query"],
  });
  return json({ ok: r.ok === true, description: r.description }, r.ok ? 200 : 502);
}

async function tg(method: string, body: unknown): Promise<any> {
  const r = await fetch(`https://api.telegram.org/bot${botToken}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return r.json().catch(() => ({}));
}

const reply = (chatId: number, text: string) => tg("sendMessage", { chat_id: chatId, text });

const newNonce = () => {
  const b = new Uint8Array(24);
  crypto.getRandomValues(b);
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
};

const fresh = (createdAt: string) => Date.now() - Date.parse(createdAt) < CODE_TTL_MS;

// Защита от подсунутой ссылки входа (аудит 13.10.2026, B-4): после «Старт» бот присылает 6-значный код,
// и вход завершается, только когда этот код введён в программе. Ссылку можно подсунуть, а код приходит
// только в Telegram того, кто входит.
const MAX_CODE_ATTEMPTS = 5;
// Старый вход без кода (программы до 2.0.15) разрешён на переходный период, кроме администраторов.
// Выключить полностью: секрет TELEGRAM_LEGACY_LOGIN=off.
const legacyLoginAllowed = () => (Deno.env.get("TELEGRAM_LEGACY_LOGIN") ?? "on").toLowerCase() !== "off";

const newLoginCode = () => {
  const b = new Uint32Array(1);
  crypto.getRandomValues(b);
  return String(b[0] % 1_000_000).padStart(6, "0");
};

async function codeHash(nonce: string, code: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${nonce}:${code}`));
  return Array.from(new Uint8Array(d), (x) => x.toString(16).padStart(2, "0")).join("");
}

// Telegram ID администраторов (таблица admins или masters.role = 'admin').
async function adminChats(): Promise<number[]> {
  const { data: rows } = await admin.from("admins").select("user_id");
  const ids = (rows ?? []).map((r: any) => r.user_id);
  const { data: ms } = await admin.from("masters").select("id, telegram_id, role").not("telegram_id", "is", null);
  return (ms ?? [])
    .filter((m: any) => ids.includes(m.id) || m.role === "admin")
    .map((m: any) => Number(m.telegram_id));
}

async function isAdminTelegram(telegramId: number): Promise<boolean> {
  return (await adminChats()).includes(Number(telegramId));
}

// Примерный регион заявителя по IP-адресу его устройства (страна, область, город).
// Определяется сервисом ipwho.is; при VPN показывает регион VPN-сервера.
async function regionOf(req: Request): Promise<string | null> {
  const ip = (req.headers.get("x-forwarded-for") ?? req.headers.get("x-real-ip") ?? "")
    .split(",")[0].trim();
  if (!ip) return null;
  try {
    const r = await fetch(`https://ipwho.is/${encodeURIComponent(ip)}?lang=ru`, {
      signal: AbortSignal.timeout(4000),
    });
    const g = await r.json();
    if (!g?.success) return null;
    return [g.country, g.region, g.city].filter(Boolean).join(", ") || null;
  } catch {
    return null;
  }
}

// Сообщение админам о новом мастере с кнопками.
async function notifyAdmins(masterId: string, region: string | null) {
  const { data: m } = await admin.from("masters")
    .select("id, name, phone, email, telegram_username, created_via, status")
    .eq("id", masterId).maybeSingle();
  if (!m || m.status !== "pending") return;
  const lines = [
    "Новая заявка на регистрацию мастера",
    `Имя: ${m.name}`,
    m.telegram_username ? `Telegram: @${m.telegram_username}` : null,
    m.phone ? `Телефон: ${m.phone}` : null,
    m.email ? `Почта: ${m.email}` : null,
    `Регион: ${region ?? "не удалось определить"}`,
    `Через: ${m.created_via === "telegram" ? "Telegram" : "почту"}`,
  ].filter(Boolean).join("\n");
  for (const chat of await adminChats()) {
    await tg("sendMessage", {
      chat_id: chat,
      text: lines,
      reply_markup: {
        inline_keyboard: [[
          { text: "✅ Одобрить", callback_data: `ap:${m.id}` },
          { text: "❌ Отклонить", callback_data: `rj:${m.id}` },
        ]],
      },
    });
  }
}

// Нажатие кнопки «Одобрить» / «Отклонить» админом.
async function onCallback(cb: any) {
  const data: string = cb?.data ?? "";
  const [kind, masterId] = data.split(":");
  if (!masterId || !(kind === "ap" || kind === "rj")) return;
  if (!(await isAdminTelegram(cb.from?.id))) {
    await tg("answerCallbackQuery", { callback_query_id: cb.id, text: "Только для администратора" });
    return;
  }
  const status = kind === "ap" ? "active" : "blocked";
  const { data: m } = await admin.from("masters")
    .update({ status }).eq("id", masterId).eq("role", "master")
    .select("name, telegram_id").maybeSingle();
  const result = !m
    ? "Мастер не найден"
    : kind === "ap" ? `✅ Одобрено: ${m.name}` : `❌ Отклонено: ${m.name}`;
  await tg("answerCallbackQuery", { callback_query_id: cb.id, text: result });
  if (cb.message) {
    await tg("editMessageText", {
      chat_id: cb.message.chat.id,
      message_id: cb.message.message_id,
      text: `${cb.message.text}\n\n${result}`,
    });
  }
  if (m?.telegram_id) {
    await reply(
      Number(m.telegram_id),
      kind === "ap"
        ? "Ваша заявка одобрена. Откройте программу nox.drive и нажмите «Проверить» — можно работать."
        : "Ваша заявка на регистрацию отклонена администратором.",
    );
  }
}

async function onTelegramUpdate(update: any) {
  if (update?.callback_query) return onCallback(update.callback_query);
  const msg = update?.message;
  const text: string = msg?.text ?? "";
  const from = msg?.from;
  if (!from || !text.startsWith("/start")) return;
  const nonce = text.split(" ")[1]?.trim();
  if (!nonce) {
    await reply(msg.chat.id, "Чтобы войти, нажмите «Войти через Telegram» в программе nox.drive.");
    return;
  }
  const { data: row } = await admin.from("telegram_logins").select("*").eq("nonce", nonce).maybeSingle();
  if (!row || row.confirmed_at || !fresh(row.created_at)) {
    await reply(msg.chat.id, "Код входа устарел. Нажмите «Войти через Telegram» в программе ещё раз.");
    return;
  }
  const code = newLoginCode();
  await admin.from("telegram_logins").update({
    telegram_id: from.id,
    telegram_username: from.username ?? null,
    telegram_name: [from.first_name, from.last_name].filter(Boolean).join(" "),
    confirmed_at: new Date().toISOString(),
    code_hash: await codeHash(nonce, code),
    code_attempts: 0,
  }).eq("nonce", nonce);
  const { data: master } = await admin.from("masters").select("status").eq("telegram_id", from.id).maybeSingle();
  if (master?.status === "blocked") {
    await reply(msg.chat.id, "Доступ закрыт администратором.");
    return;
  }
  await reply(
    msg.chat.id,
    `Код входа в nox.drive: ${code}\n\n` +
      "Введите его в программе на своём компьютере. Никому не сообщайте этот код, даже «поддержке». " +
      "Если вы сейчас не нажимали «Войти через Telegram» в программе nox.drive, ничего не вводите: " +
      "кто-то пытается войти под вашим аккаунтом." +
      (master?.status === "active"
        ? ""
        : "\n\nПосле входа заявка на регистрацию уйдёт администратору. Как только он её одобрит, я пришлю сообщение."),
  );
}

async function poll(nonce: string, req: Request, proto: number, code: unknown) {
  const { data: row } = await admin.from("telegram_logins").select("*").eq("nonce", nonce).maybeSingle();
  if (!row || row.consumed_at) return json({ status: "invalid" });
  if (!row.confirmed_at) return json({ status: fresh(row.created_at) ? "pending" : "expired" });
  // Подтверждённый, но не забранный вовремя код тоже устаревает.
  if (!fresh(row.created_at)) return json({ status: "expired" });

  if (proto >= 2) {
    // Новый вход: нужен код, который бот прислал в Telegram.
    if (typeof code !== "string" || !/^[0-9]{6}$/.test(code)) return json({ status: "need_code" });
    if ((row.code_attempts ?? 0) >= MAX_CODE_ATTEMPTS) return json({ status: "invalid" });
    if (!row.code_hash || row.code_hash !== await codeHash(nonce, code)) {
      const attempts = (row.code_attempts ?? 0) + 1;
      await admin.from("telegram_logins").update({ code_attempts: attempts }).eq("nonce", nonce);
      if (attempts >= MAX_CODE_ATTEMPTS) {
        await admin.from("telegram_logins").update({ consumed_at: new Date().toISOString() }).eq("nonce", nonce);
        return json({ status: "invalid" });
      }
      return json({ status: "bad_code", attempts_left: MAX_CODE_ATTEMPTS - attempts });
    }
  } else {
    // Старый вход без кода: только на переходный период и никогда для администраторов.
    if (!legacyLoginAllowed() || (await isAdminTelegram(row.telegram_id))) {
      return json({ status: "update_required" });
    }
  }

  // Мастер с этим Telegram уже есть? Иначе регистрируем нового (статус pending через триггер).
  const email = `tg-${row.telegram_id}@telegram.nox.drive`;
  const { data: master } = await admin.from("masters").select("id").eq("telegram_id", row.telegram_id).maybeSingle();
  if (!master) {
    const { data: created, error } = await admin.auth.admin.createUser({
      email,
      email_confirm: true,
      // Права и привязку к Telegram база читает только отсюда: app_metadata не задаётся с клиента
      // (user_metadata пользователь может подставить сам при signUp, см. миграцию 0009).
      app_metadata: { telegram_id: row.telegram_id },
      user_metadata: {
        via: "telegram",
        name: row.telegram_name || row.telegram_username || `Telegram ${row.telegram_id}`,
        telegram_id: row.telegram_id,
        telegram_username: row.telegram_username,
      },
    });
    if (error && !String(error.message).includes("already")) return json({ status: "error" }, 500);
    if (created?.user) await notifyAdmins(created.user.id, await regionOf(req));
  }
  const { data: link, error } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  if (error) return json({ status: "error" }, 500);
  await admin.from("telegram_logins").update({ consumed_at: new Date().toISOString() }).eq("nonce", nonce);
  return json({ status: "ok", email, token_hash: link.properties.hashed_token });
}

// Регистрация по почте: программа сообщает о новой заявке, бот пишет админам.
// Без спама: только для мастера в ожидании, созданного не раньше 10 минут назад.
async function notifySignup(email: unknown, req: Request) {
  if (typeof email !== "string" || !email.includes("@")) return json({ error: "BAD_REQUEST" }, 400);
  const { data: m } = await admin.from("masters")
    .select("id, status, created_at").ilike("email", email.trim()).maybeSingle();
  if (m && m.status === "pending" && fresh(m.created_at)) await notifyAdmins(m.id, await regionOf(req));
  return json({ ok: true });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (!botToken) return json({ error: "TELEGRAM_NOT_CONFIGURED" }, 503);

  // Webhook Telegram: проверяется секрет, заданный при setWebhook.
  if (req.headers.get("X-Telegram-Bot-Api-Secret-Token") !== null) {
    if (req.headers.get("X-Telegram-Bot-Api-Secret-Token") !== await getWebhookSecret()) {
      return new Response("forbidden", { status: 403 });
    }
    await onTelegramUpdate(await req.json().catch(() => null));
    return new Response("ok");
  }

  const body = await req.json().catch(() => ({}));
  if (body.action === "start") {
    // Программа присылает свой код (48 hex); если его нет или он неверный, создаём свой.
    const nonce = typeof body.nonce === "string" && /^[0-9a-f]{32,128}$/.test(body.nonce)
      ? body.nonce
      : newNonce();
    // Старые коды входа не копятся: всё, что старше суток, удаляется.
    await admin.from("telegram_logins").delete().lt("created_at", new Date(Date.now() - 86_400_000).toISOString());
    const { error } = await admin.from("telegram_logins").insert({ nonce });
    if (error) return json({ error: "DB_ERROR" }, 500);
    return json({ nonce, link: `https://t.me/${botUsername}?start=${nonce}` });
  }
  if (body.action === "poll" && typeof body.nonce === "string") {
    return poll(body.nonce, req, Number(body.proto) || 1, body.code);
  }
  if (body.action === "notify_signup") return notifySignup(body.email, req);
  if (body.action === "setup_webhook") return setupWebhook(req);
  return json({ error: "BAD_REQUEST" }, 400);
});
