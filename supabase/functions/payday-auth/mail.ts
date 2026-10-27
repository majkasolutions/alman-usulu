// Payday e-posta şablonları (onay, şifre sıfırlama).
// E-posta istemcileri için: tablo düzeni, satır içi stiller, SVG yok (logo PNG), dış CSS yok.
// Renkler uygulamayla aynı: lacivert başlık, #2563eb düğme, logodaki dört dilim rengi.

export const APP_URL = "https://majkasolutions.github.io/alman-usulu/";
const LOGO = `${APP_URL}icons/icon-192.png`;
const SLICES = ["#a78bfa", "#fbbf24", "#38bdf8", "#f97316"];

function esc(s: string) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

export type Kind = "verify" | "reset" | "email";

const COPY: Record<Kind, { subject: string; preheader: string; title: string; intro: string; button: string; note: string; outro: string }> = {
  verify: {
    subject: "Payday hesabını onayla",
    preheader: "Tek dokunuşla e-postanı onayla, arkadaşlarınla hesabı bölmeye başla.",
    title: "Hoş geldin!",
    intro: "Payday hesabın neredeyse hazır. Bu e-posta adresinin sana ait olduğunu doğrulamak için aşağıdaki düğmeye dokun.",
    button: "E-postamı onayla",
    note: "Bu link 48 saat geçerli.",
    outro: "Payday'e kaydolmadıysan bu e-postayı yok sayabilirsin; hesap açılmaz.",
  },
  reset: {
    subject: "Payday şifre sıfırlama",
    preheader: "Yeni şifreni belirlemek için linke dokun (1 saat geçerli).",
    title: "Şifreni mi unuttun?",
    intro: "Sorun değil. Aşağıdaki düğmeye dokunup yeni bir şifre belirleyebilirsin.",
    button: "Yeni şifre belirle",
    note: "Bu link 1 saat geçerli ve yalnızca bir kez kullanılabilir.",
    outro: "Şifre sıfırlamayı sen istemediysen bu e-postayı yok say; şifren değişmez.",
  },
  email: {
    subject: "Payday e-posta adresini doğrula",
    preheader: "Payday hesabının e-posta adresini bu adresle değiştirmek için onayla.",
    title: "Yeni e-postanı onayla",
    intro: "Payday hesabının e-posta adresini bu adresle değiştirmek istedin. Onaylamak için aşağıdaki düğmeye dokun; etkinliklerin, kayıtların ve arkadaşların aynen kalır.",
    button: "E-postamı onayla",
    note: "Bu link 48 saat geçerli.",
    outro: "Bu isteği sen yapmadıysan bu e-postayı yok say; hiçbir hesap değişmez.",
  },
};

const FEATURES = [
  ["🧾", "Harcamaları gir", "TL, €, $ ya da kron — kur otomatik çevrilir."],
  ["👥", "Arkadaşlarını davet et", "Etkinliği yalnızca davet ettiklerin görür."],
  ["🏁", "Kim kime ne borçlu?", "En az transferle ödeşme, tek bakışta."],
];

export function mail(kind: Kind, name: string, link: string) {
  const c = COPY[kind];
  const n = esc(name), l = esc(link);
  const slices = SLICES.map((col) => `<td width="25%" height="4" style="background:${col};font-size:0;line-height:0">&nbsp;</td>`).join("");
  const features = kind !== "verify" ? "" : `
          <tr><td style="padding:8px 32px 4px">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-top:1px solid #e5e7eb">
              <tr><td style="padding:20px 0 6px;font-size:12px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:#64748b">Payday'de seni neler bekliyor</td></tr>
              ${FEATURES.map(([icon, t, d]) => `
              <tr><td style="padding:8px 0">
                <table role="presentation" cellpadding="0" cellspacing="0"><tr>
                  <td width="40" valign="top" style="font-size:22px;line-height:28px">${icon}</td>
                  <td valign="top" style="font-size:15px;line-height:21px;color:#0f172a"><b>${t}</b><br><span style="font-size:14px;color:#64748b">${d}</span></td>
                </tr></table>
              </td></tr>`).join("")}
            </table>
          </td></tr>`;

  const html = `<!doctype html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light">
<meta name="supported-color-schemes" content="light">
<title>${esc(c.subject)}</title>
</head>
<body style="margin:0;padding:0;background:#f6f7f9;-webkit-text-size-adjust:100%">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:#f6f7f9">${esc(c.preheader)}&#8199;&#847;&#8199;&#847;&#8199;&#847;&#8199;&#847;&#8199;&#847;&#8199;&#847;</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f6f7f9">
  <tr><td align="center" style="padding:32px 16px">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif">

      <tr><td style="background:#172554;background-image:linear-gradient(135deg,#1e3a8a,#0f172a);border-radius:20px 20px 0 0;padding:28px 32px">
        <table role="presentation" cellpadding="0" cellspacing="0"><tr>
          <td><img src="${LOGO}" width="44" height="44" alt="" style="display:block;border:0;border-radius:11px"></td>
          <td style="padding-left:12px;font-size:22px;font-weight:800;letter-spacing:-.02em;color:#ffffff">Payday</td>
        </tr></table>
        <div style="margin-top:6px;font-size:13px;color:#cbd5e1">Kim ne ödedi, kim kime borçlu?</div>
      </td></tr>
      <tr><td style="font-size:0;line-height:0"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>${slices}</tr></table></td></tr>

      <tr><td style="background:#ffffff;border-radius:0 0 20px 20px;box-shadow:0 1px 3px rgba(15,23,42,.06)">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
          <tr><td style="padding:32px 32px 0">
            <div style="font-size:26px;line-height:32px;font-weight:800;letter-spacing:-.02em;color:#0f172a">${c.title}</div>
            <div style="margin-top:14px;font-size:16px;line-height:24px;color:#0f172a">Merhaba <b>${n}</b>,</div>
            <div style="margin-top:8px;font-size:16px;line-height:24px;color:#334155">${c.intro}</div>
          </td></tr>
          <tr><td style="padding:28px 32px 8px">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
              <td align="center" bgcolor="#2563eb" style="border-radius:12px">
                <a href="${l}" target="_blank" style="display:block;padding:15px 24px;font-size:16px;font-weight:700;color:#ffffff;text-decoration:none;border-radius:12px">${c.button} →</a>
              </td>
            </tr></table>
            <div style="margin-top:12px;text-align:center;font-size:13px;color:#64748b">⏳ ${c.note}</div>
          </td></tr>
          ${features}
          <tr><td style="padding:20px 32px 32px">
            <div style="background:#f1f5f9;border-radius:12px;padding:14px 16px;font-size:13px;line-height:19px;color:#64748b">
              Düğme çalışmazsa bu adresi tarayıcına yapıştır:<br>
              <a href="${l}" target="_blank" style="color:#2563eb;word-break:break-all;text-decoration:none">${l}</a>
            </div>
          </td></tr>
        </table>
      </td></tr>

      <tr><td style="padding:22px 24px 0;text-align:center;font-size:12px;line-height:18px;color:#94a3b8">
        ${c.outro}<br>
        <a href="${APP_URL}" target="_blank" style="color:#64748b;text-decoration:none;font-weight:600">Payday</a> · Majka Solutions
      </td></tr>

    </table>
  </td></tr>
</table>
</body>
</html>`;

  const text = `${c.title}\n\nMerhaba ${name},\n\n${c.intro}\n\n${c.button}: ${link}\n\n${c.note}\n\n${c.outro}\n\n— Payday · Majka Solutions`;
  return { subject: c.subject, html, text };
}
