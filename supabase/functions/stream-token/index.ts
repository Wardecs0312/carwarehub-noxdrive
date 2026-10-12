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

  const lkUrl = Deno.env.get("LIVEKIT_URL");
  const lkKey = Deno.env.get("LIVEKIT_API_KEY");
  const lkSecret = Deno.env.get("LIVEKIT_API_SECRET");
  if (!lkUrl || !lkKey || !lkSecret) return json({ error: "STREAMING_NOT_CONFIGURED" }, 503);

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
