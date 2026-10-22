// Payday: kayıt, onay e-postasını yeniden gönderme, şifre sıfırlama e-postası.
//
// Payday kullanıcıları hesap şemasındadır (hesap.users); majka-panel'in Supabase Auth'u
// (auth.users) ve diğer uygulamalar KULLANILMAZ. Bu fonksiyon hesap_srv_* fonksiyonlarını
// service_role ile çağırır, linki e-postayla gönderir. Link uygulamada #verify/… ya da
// #reset/… olarak açılır ve hesap_verify / hesap_reset_password ile tamamlanır.
//
// E-posta SMTP ile (465/SSL; Supabase Edge 25 ve 587'ye izin vermez) gider. Anahtarlar
// PAYDAY_ önekli; başka uygulamanın e-posta ayarına geri dönüş (fallback) YOK:
//   PAYDAY_SMTP_HOST, PAYDAY_SMTP_PORT (varsayılan 465), PAYDAY_SMTP_USER, PAYDAY_SMTP_PASS,
//   PAYDAY_MAIL_FROM (varsayılan "Payday <PAYDAY_SMTP_USER>")
// JWT doğrulaması KAPALI (herkese açık kayıt formu); IP başına dakikada 5 istek.

import nodemailer from "npm:nodemailer@6.9.16";

const APP_URL = "https://majkasolutions.github.io/alman-usulu/";
const ORIGINS = ["https://majkasolutions.github.io", "http://localhost:8765", "http://localhost:8766"];
const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SMTP = {
  host: Deno.env.get("PAYDAY_SMTP_HOST") ?? "",
  port: Number(Deno.env.get("PAYDAY_SMTP_PORT") ?? "465"),
  user: Deno.env.get("PAYDAY_SMTP_USER") ?? "",
  pass: Deno.env.get("PAYDAY_SMTP_PASS") ?? "",
};
const FROM = Deno.env.get("PAYDAY_MAIL_FROM") ?? `Payday <${SMTP.user}>`;

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

function esc(s: string) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function mail(kind: "verify" | "reset", name: string, link: string) {
  const [subject, intro, button, note] = kind === "verify"
    ? ["Payday hesabını onayla", "Payday'e hoş geldin! Hesabını açmak için e-posta adresini onayla.", "E-postamı onayla", "Link 48 saat geçerli."]
    : ["Payday şifre sıfırlama", "Şifreni sıfırlamak için aşağıdaki düğmeye tıkla. Bu isteği sen yapmadıysan e-postayı yok sayabilirsin.", "Yeni şifre belirle", "Link 1 saat geçerli."];
  const html = `<div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;max-width:480px;margin:0 auto;padding:24px;color:#111">
  <h2 style="margin:0 0 12px">Payday</h2>
  <p>Merhaba ${esc(name)},</p><p>${intro}</p>
  <p style="margin:24px 0"><a href="${link}" style="background:#2563eb;color:#fff;padding:12px 20px;border-radius:10px;text-decoration:none;font-weight:600">${button}</a></p>
  <p style="color:#666;font-size:13px">${note} Düğme çalışmazsa bu adresi tarayıcına yapıştır:<br><a href="${link}" style="color:#2563eb;word-break:break-all">${link}</a></p>
</div>`;
  const text = `Merhaba ${name},\n\n${intro}\n\n${link}\n\n${note}`;
  return { subject, html, text };
}

async function send(to: string, kind: "verify" | "reset", name: string, token: string) {
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

  let b: Record<string, string> = {};
  try { b = await req.json(); } catch { return out(400, { ok: false, error: "json" }); }
  if (b.website) return out(200, { ok: true }); // bal küpü
  if (!SB_URL || !SB_KEY) { console.error("payday-auth: SUPABASE_URL/SERVICE_ROLE_KEY yok"); return out(500, { ok: false, error: "config" }); }
  const smtpOk = SMTP.host && SMTP.user && SMTP.pass;

  try {
    if (b.action === "register") {
      const r = await srv("hesap_srv_register", { p_email: b.email, p_name: b.name, p_pass: b.password });
      if (!r) return out(500, { ok: false, error: "db" });
      if (!smtpOk) { console.error("payday-auth: PAYDAY_SMTP_* yok"); return out(200, { ok: true, mail: false }); }
      try { await send(r.email, "verify", r.name, r.token); } catch (e) { console.error("payday-auth smtp", String(e).slice(0, 300)); return out(200, { ok: true, mail: false }); }
      console.log("payday-auth register", r.email);
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
