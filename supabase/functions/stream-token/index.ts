// Выдача токенов LiveKit для трансляций (docs/STREAMING.md).
// Мастер: право публиковать только в свою комнату master-<uuid> и только при открытом запросе админа.
// Админ: право смотреть любую комнату, публиковать нельзя.
// Секреты (задаёт владелец: supabase secrets set ...): LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { AccessToken } from "npm:livekit-server-sdk@2.6.1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  // Основные имена секретов и частые варианты (пробелы по краям значений убираются).
  const env = (...names: string[]) => {
    for (const n of names) {
      const v = Deno.env.get(n)?.trim();
      if (v) return v;
    }
    return undefined;
  };
  let lkUrl = env("LIVEKIT_URL", "LIVEKIT_WS_URL", "LIVEKIT_HOST", "LIVEKIT_SERVER_URL", "livekit_url");
  const lkKey = env("LIVEKIT_API_KEY", "LIVEKIT_KEY", "livekit_api_key");
  const lkSecret = env("LIVEKIT_API_SECRET", "LIVEKIT_SECRET", "livekit_api_secret");
  if (lkUrl?.startsWith("https://")) lkUrl = "wss://" + lkUrl.slice("https://".length);
  if (!lkUrl || !lkKey || !lkSecret) {
    // Только имена недостающих секретов, без значений.
    const missing = [
      !lkUrl && "LIVEKIT_URL",
      !lkKey && "LIVEKIT_API_KEY",
      !lkSecret && "LIVEKIT_API_SECRET",
    ].filter(Boolean);
    const seen = Object.keys(Deno.env.toObject()).filter((k) => /livekit/i.test(k));
    return json({ error: "STREAMING_NOT_CONFIGURED", missing, seen }, 503);
  }

  // Клиент от имени вызывающего пользователя: RLS и nox_is_admin() работают как в приложении.
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await db.auth.getUser();
  if (!user) return json({ error: "UNAUTHORIZED" }, 401);

  const body = await req.json().catch(() => ({}));
  const { data: isAdmin } = await db.rpc("nox_is_admin");

  let room: string;
  let grant: { canPublish: boolean; canSubscribe: boolean };
  if (isAdmin && typeof body.master_id === "string") {
    room = `master-${body.master_id}`;
    grant = { canPublish: false, canSubscribe: true };
  } else {
    // Мастер: только при открытом запросе трансляции (RLS отдаёт только его строки).
    const { data: open } = await db
      .from("stream_sessions")
      .select("id")
      .eq("master_id", user.id)
      .neq("status", "ended")
      .limit(1);
    if (!open?.length) return json({ error: "NO_STREAM_REQUEST" }, 403);
    room = `master-${user.id}`;
    grant = { canPublish: true, canSubscribe: false };
  }

  const at = new AccessToken(lkKey, lkSecret, {
    identity: `${isAdmin ? "admin" : "master"}-${user.id}`,
    ttl: "2h",
  });
  at.addGrant({ room, roomJoin: true, canPublishData: false, ...grant });
  return json({ url: lkUrl, token: await at.toJwt(), room });
});
