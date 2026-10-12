// Вход и регистрация мастера через Telegram-бота.
//
// 1. Программа: {action:"start"} -> одноразовый код и ссылка t.me/<бот>?start=<код>.
// 2. Мастер жмёт «Старт» в боте -> Telegram присылает сюда webhook, код подтверждается.
// 3. Программа опрашивает {action:"poll", nonce} -> при подтверждении получает token_hash
//    и входит через supabase.auth.verifyOTP(type: magiclink). Новый мастер создаётся со статусом pending.
//
// Секреты (задаёт владелец): TELEGRAM_BOT_TOKEN, TELEGRAM_BOT_USERNAME, TELEGRAM_WEBHOOK_SECRET.
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
const botUsername = Deno.env.get("TELEGRAM_BOT_USERNAME");
const webhookSecret = Deno.env.get("TELEGRAM_WEBHOOK_SECRET");

const newNonce = () => {
  const b = new Uint8Array(24);
  crypto.getRandomValues(b);
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
};

const fresh = (createdAt: string) => Date.now() - Date.parse(createdAt) < CODE_TTL_MS;

async function reply(chatId: number, text: string) {
  await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text }),
  });
}

async function onTelegramUpdate(update: any) {
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
  await reply(msg.chat.id, "Вход подтверждён. Вернитесь в программу nox.drive.");
}

async function poll(nonce: string) {
  const { data: row } = await admin.from("telegram_logins").select("*").eq("nonce", nonce).maybeSingle();
  if (!row || row.consumed_at) return json({ status: "invalid" });
  if (!row.confirmed_at) return json({ status: fresh(row.created_at) ? "pending" : "expired" });

  // Мастер с этим Telegram уже есть? Иначе регистрируем нового (статус pending через триггер).
  const email = `tg-${row.telegram_id}@telegram.nox.drive`;
  const { data: master } = await admin.from("masters").select("id").eq("telegram_id", row.telegram_id).maybeSingle();
  if (!master) {
    const { error } = await admin.auth.admin.createUser({
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
  }
  const { data: link, error } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  if (error) return json({ status: "error" }, 500);
  await admin.from("telegram_logins").update({ consumed_at: new Date().toISOString() }).eq("nonce", nonce);
  return json({ status: "ok", email, token_hash: link.properties.hashed_token });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (!botToken || !botUsername || !webhookSecret) return json({ error: "TELEGRAM_NOT_CONFIGURED" }, 503);

  // Webhook Telegram: проверяется секрет, заданный при setWebhook.
  if (req.headers.get("X-Telegram-Bot-Api-Secret-Token") !== null) {
    if (req.headers.get("X-Telegram-Bot-Api-Secret-Token") !== webhookSecret) {
      return new Response("forbidden", { status: 403 });
    }
    await onTelegramUpdate(await req.json().catch(() => null));
    return new Response("ok");
  }

  const body = await req.json().catch(() => ({}));
  if (body.action === "start") {
    const nonce = newNonce();
    await admin.from("telegram_logins").insert({ nonce });
    return json({ nonce, link: `https://t.me/${botUsername}?start=${nonce}` });
  }
  if (body.action === "poll" && typeof body.nonce === "string") return poll(body.nonce);
  return json({ error: "BAD_REQUEST" }, 400);
});
