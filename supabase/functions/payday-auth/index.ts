// Payday: kayıt, onay e-postasını yeniden gönderme, şifre sıfırlama, e-posta değiştirme.
//
// Payday kullanıcıları hesap şemasındadır (hesap.users); majka-panel'in Supabase Auth'u
// (auth.users) ve diğer uygulamalar KULLANILMAZ. Bu fonksiyon hesap_srv_* fonksiyonlarını
// service_role ile çağırır, linki e-postayla gönderir. Link uygulamada #verify/… ya da
// #reset/… ya da #email/… olarak açılır ve hesap_verify / hesap_reset_password / hesap_confirm_email
// ile tamamlanır.
//
// E-posta SMTP ile (465/SSL; Supabase Edge 25 ve 587'ye izin vermez) gider. Anahtarlar
// PAYDAY_ önekli; başka uygulamanın e-posta ayarına geri dönüş (fallback) YOK. Gerekli tek gizli
// anahtar PAYDAY_SMTP_PASS; PAYDAY_SMTP_HOST/PORT/USER ve PAYDAY_MAIL_FROM isteğe bağlı (varsayılanlar aşağıda).
// JWT doğrulaması KAPALI (herkese açık kayıt formu); IP başına dakikada 5 istek.

import nodemailer from "npm:nodemailer@6.9.16";
import { APP_URL, type Kind, mail } from "./mail.ts";

const ORIGINS = ["https://majkasolutions.github.io", "http://localhost:8765", "http://localhost:8766"];
const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
// info@majkasolutions.com Turhost'un kendi e-posta sunucusunda (MX: srvm06.trwww.com; SPF de trwww.com);
// yalnızca şifre gizli anahtar.
const SMTP = {
  host: Deno.env.get("PAYDAY_SMTP_HOST") || "srvm06.trwww.com",
  port: Number(Deno.env.get("PAYDAY_SMTP_PORT") || "465"),
  user: Deno.env.get("PAYDAY_SMTP_USER") || "info@majkasolutions.com",
  pass: Deno.env.get("PAYDAY_SMTP_PASS") ?? "",
};
const FROM = Deno.env.get("PAYDAY_MAIL_FROM") || `Payday <${SMTP.user}>`;

const hits = new Map<string, number[]>();
function limited(ip: string) {
  const now = Date.now();
  const arr = (hits.get(ip) ?? []).filter((t) => now - t < 60_000);
  arr.push(now);
  hits.set(ip, arr);
  return arr.length > 5;
}

function cors(origin: string) {
  return {
    "Access-Control-Allow-Origin": ORIGINS.includes(origin) ? origin : ORIGINS[0],
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "content-type, apikey, authorization, x-client-info",
    "Content-Type": "application/json",
  };
}

async function srv(fn: string, args: Record<string, unknown>) {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}` },
    body: JSON.stringify(args),
  });
  const body = await r.json().catch(() => null);
  if (!r.ok) throw new Error(body?.message ?? `db ${r.status}`);
  return body as { email: string; name: string; token: string } | null;
}

async function send(to: string, kind: Kind, name: string, token: string) {
  const link = `${APP_URL}#${kind}/${token}`;
  const m = mail(kind, name, link);
  const t = nodemailer.createTransport({ host: SMTP.host, port: SMTP.port, secure: SMTP.port === 465, auth: { user: SMTP.user, pass: SMTP.pass } });
  await t.sendMail({ from: FROM, to, subject: m.subject, text: m.text, html: m.html });
}

Deno.serve(async (req) => {
  const headers = cors(req.headers.get("origin") ?? "");
  const out = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return out(405, { ok: false, error: "method" });

  const ip = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "?";
  if (limited(ip)) return out(429, { ok: false, error: "Çok fazla deneme, bir dakika sonra tekrar dene." });

  let b: Record<string, string | boolean> = {};
  try { b = await req.json(); } catch { return out(400, { ok: false, error: "json" }); }
  if (b.website) return out(200, { ok: true }); // bal küpü
  if (!SB_URL || !SB_KEY) { console.error("payday-auth: SUPABASE_URL/SERVICE_ROLE_KEY yok"); return out(500, { ok: false, error: "config" }); }
  const smtpOk = SMTP.host && SMTP.user && SMTP.pass;

  try {
    if (b.action === "register") {
      const r = await srv("hesap_srv_register", { p_email: b.email, p_name: b.name, p_pass: b.password, p_consent: b.consent === true });
      if (!r) return out(500, { ok: false, error: "db" });
      if (!smtpOk) { console.error("payday-auth: PAYDAY_SMTP_* yok"); return out(200, { ok: true, mail: false }); }
      try { await send(r.email, "verify", r.name, r.token); } catch (e) { console.error("payday-auth smtp", String(e).slice(0, 300)); return out(200, { ok: true, mail: false }); }
      console.log("payday-auth register", r.email);
      return out(200, { ok: true, mail: true });
    }
    if (b.action === "change_email") {
      // oturum anahtarıyla doğrulanır; onay linki YENİ adrese gider, adres ancak tıklanınca değişir
      const r = await srv("hesap_srv_email_change", { p_email: b.email, p_pass: b.session, p_new_email: b.new_email });
      if (!r) return out(500, { ok: false, error: "db" });
      if (!smtpOk) { console.error("payday-auth: PAYDAY_SMTP_* yok"); return out(200, { ok: true, mail: false }); }
      try { await send(r.email, "email", r.name, r.token); } catch (e) { console.error("payday-auth smtp", String(e).slice(0, 300)); return out(200, { ok: true, mail: false }); }
      console.log("payday-auth change_email", r.email);
      return out(200, { ok: true, mail: true });
    }
    if (b.action === "resend" || b.action === "forgot") {
      const kind = b.action === "resend" ? "verify" : "reset";
      // kullanıcı yoksa da "ok" döner (hangi adresin kayıtlı olduğu belli olmasın)
      const r = await srv("hesap_srv_token", { p_email: b.email, p_kind: kind });
      if (r) {
        if (!smtpOk) { console.error("payday-auth: PAYDAY_SMTP_* yok"); return out(200, { ok: true, mail: false }); }
        try { await send(r.email, kind, r.name, r.token); } catch (e) { console.error("payday-auth smtp", String(e).slice(0, 300)); return out(200, { ok: true, mail: false }); }
        console.log("payday-auth", b.action, r.email);
      }
      return out(200, { ok: true, mail: true });
    }
    return out(400, { ok: false, error: "action" });
  } catch (e) {
    return out(400, { ok: false, error: (e as Error).message });
  }
});
