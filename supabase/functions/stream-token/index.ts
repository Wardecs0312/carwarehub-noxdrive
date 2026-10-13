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
  // Имена сравниваются без невидимых символов и регистра: при копировании имени из чата
  // в него часто попадает, например, U+2060, и тогда точное имя не находится.
  const clean = (s: string) => s.replace(/[^A-Za-z0-9_]/g, "").toUpperCase();
  const all = Deno.env.toObject();
  const env = (...names: string[]) => {
    const value = (v?: string) => v?.replace(/[\u200B-\u200D\u2060\uFEFF]/g, "").trim() ?? "";
    // Сначала точное имя: если рядом остался старый секрет с невидимым символом в имени,
    // он не должен перекрыть новый, правильно названный.
    for (const n of names) {
      const v = value(all[n]);
      if (v) return v;
    }
    for (const n of names) {
      for (const [k, v] of Object.entries(all)) {
        if (clean(k) === clean(n) && value(v)) return value(v);
      }
    }
    return undefined;
  };
  let lkUrl: string | undefined = env("LIVEKIT_URL", "LIVEKIT_WS_URL", "LIVEKIT_HOST", "LIVEKIT_SERVER_URL", "livekit_url");
  // Из ключа и секрета убираются только пробелы, кавычки и невидимые символы из буфера обмена;
  // остальные символы (в секрете бывают «/», «+», «=») сохраняются как есть.
  const tidy = (s?: string) =>
    s?.replace(/[\s"'`\u200B-\u200D\u2060\uFEFF]/g, "");
  const lkKey = tidy(env("LIVEKIT_API_KEY", "LIVEKIT_KEY", "livekit_api_key"));
  const lkSecret = tidy(env("LIVEKIT_API_SECRET", "LIVEKIT_SECRET", "livekit_api_secret"));
  lkUrl = lkUrl?.replace(/["'\s]/g, "");
  if (lkUrl?.startsWith("https://")) lkUrl = "wss://" + lkUrl.slice("https://".length);
  // Только имена недостающих секретов, без значений.
  const notConfigured = () => {
    const missing = [
      !lkUrl && "LIVEKIT_URL",
      !lkKey && "LIVEKIT_API_KEY",
      !lkSecret && "LIVEKIT_API_SECRET",
    ].filter(Boolean);
    const seen = Object.keys(Deno.env.toObject()).filter((k) => /livekit/i.test(k));
    return json({ error: "STREAMING_NOT_CONFIGURED", missing, seen }, 503);
  };
  if (!lkUrl) return notConfigured();
  if (!lkKey) return notConfigured();
  if (!lkSecret) return notConfigured();

  const body = await req.json().catch(() => ({}));

  // Самопроверка настроек (без входа): секреты не раскрываются, только их форма и ответ LiveKit.
  if (body.action === "check") {
    const httpUrl = lkUrl.replace(/^wss:\/\//, "https://");
    // Прямой запрос к API LiveKit (ListRooms) с токеном, подписанным этими ключами:
    // 200 — ключи верны, 401 — LiveKit не принимает ключ или секрет.
    let livekit = "ok";
    try {
      const probe = new AccessToken(lkKey, lkSecret, { identity: "nox-check", ttl: "5m" });
      probe.addGrant({ roomList: true });
      const r = await fetch(`${httpUrl.replace(/\/$/, "")}/twirp/livekit.RoomService/ListRooms`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${await probe.toJwt()}` },
        body: "{}",
      });
      if (!r.ok) livekit = `HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`;
    } catch (e) {
      livekit = String((e as Error)?.message ?? e).slice(0, 200);
    }
    const shape = (s: string) => ({
      length: s.length,
      start: s.slice(0, 3),
      nonAscii: /[^\x21-\x7E]/.test(s),
    });
    return json({
      livekit,
      url: lkUrl.replace(/^wss:\/\//, "").split("/")[0],
      urlScheme: lkUrl.split("://")[0],
      key: shape(lkKey),
      secret: { length: lkSecret.length, nonAscii: /[^\x21-\x7E]/.test(lkSecret) },
      // Имена всех секретов LiveKit (без значений): видно, остались ли старые дубли с невидимыми символами.
      names: Object.keys(all).filter((k) => /livekit/i.test(k)).map((k) => k.replace(/[^\x20-\x7E]/g, (ch) => `<U+${ch.charCodeAt(0).toString(16).toUpperCase()}>`)),
    });
  }

  // Клиент от имени вызывающего пользователя: RLS и nox_is_admin() работают как в приложении.
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await db.auth.getUser();
  if (!user) return json({ error: "UNAUTHORIZED" }, 401);
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
