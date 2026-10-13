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

// Сообщение админам о новом мастере с кнопками.
async function notifyAdmins(masterId: string) {
  const { data: m } = await admin.from("masters")
    .select("id, name, phone, email, telegram_username, created_via, status")
    .eq("id", masterId).maybeSingle();
  if (!m || m.status !== "pending") return;
  const lines = [
    "Новая заявка на регистрацию мастера",
    `Имя: ${m.name}`,
    m.phone ? `Телефон: ${m.phone}` : null,
    m.email ? `Почта: ${m.email}` : null,
    m.telegram_username ? `Telegram: @${m.telegram_username}` : null,
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
  await admin.from("telegram_logins").update({
    telegram_id: from.id,
    telegram_username: from.username ?? null,
    telegram_name: [from.first_name, from.last_name].filter(Boolean).join(" "),
    confirmed_at: new Date().toISOString(),
  }).eq("nonce", nonce);
  const { data: master } = await admin.from("masters").select("status").eq("telegram_id", from.id).maybeSingle();
  await reply(
    msg.chat.id,
    master?.status === "active"
      ? "Вход подтверждён. Вернитесь в программу nox.drive."
      : master?.status === "blocked"
      ? "Доступ закрыт администратором."
      : "Заявка на регистрацию отправлена администратору. Как только он её одобрит, я пришлю сообщение, и можно будет работать.",
  );
}

async function poll(nonce: string) {
  const { data: row } = await admin.from("telegram_logins").select("*").eq("nonce", nonce).maybeSingle();
  if (!row || row.consumed_at) return json({ status: "invalid" });
  if (!row.confirmed_at) return json({ status: fresh(row.created_at) ? "pending" : "expired" });

  // Мастер с этим Telegram уже есть? Иначе регистрируем нового (статус pending через триггер).
  const email = `tg-${row.telegram_id}@telegram.nox.drive`;
  const { data: master } = await admin.from("masters").select("id").eq("telegram_id", row.telegram_id).maybeSingle();
  if (!master) {
    const { data: created, error } = await admin.auth.admin.createUser({
      email,
      email_confirm: true,
      user_metadata: {
        via: "telegram",
        name: row.telegram_name || row.telegram_username || `Telegram ${row.telegram_id}`,
        telegram_id: row.telegram_id,
        telegram_username: row.telegram_username,
      },
    });
    if (error && !String(error.message).includes("already")) return json({ status: "error" }, 500);
    if (created?.user) await notifyAdmins(created.user.id);
  }
  const { data: link, error } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  if (error) return json({ status: "error" }, 500);
  await admin.from("telegram_logins").update({ consumed_at: new Date().toISOString() }).eq("nonce", nonce);
  return json({ status: "ok", email, token_hash: link.properties.hashed_token });
}

// Регистрация по почте: программа сообщает о новой заявке, бот пишет админам.
// Без спама: только для мастера в ожидании, созданного не раньше 10 минут назад.
async function notifySignup(email: unknown) {
  if (typeof email !== "string" || !email.includes("@")) return json({ error: "BAD_REQUEST" }, 400);
  const { data: m } = await admin.from("masters")
    .select("id, status, created_at").ilike("email", email.trim()).maybeSingle();
  if (m && m.status === "pending" && fresh(m.created_at)) await notifyAdmins(m.id);
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
    const { error } = await admin.from("telegram_logins").insert({ nonce });
    if (error) return json({ error: "DB_ERROR" }, 500);
    return json({ nonce, link: `https://t.me/${botUsername}?start=${nonce}` });
  }
  if (body.action === "poll" && typeof body.nonce === "string") return poll(body.nonce);
  if (body.action === "notify_signup") return notifySignup(body.email);
  if (body.action === "setup_webhook") return setupWebhook(req);
  return json({ error: "BAD_REQUEST" }, 400);
});
