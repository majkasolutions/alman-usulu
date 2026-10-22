# Payday (eski adı: Alman Usulü)

Arkadaş grubunun harcama defteri (Splitwise benzeri). Tek sayfa, GitHub Pages'te yayınlanır.

- Canlı: https://majkasolutions.github.io/alman-usulu/
- Veri: `majka-panel` Supabase projesi, `hesap` şeması. Tablolar dışarıya kapalı; tek erişim `public.hesap_*` fonksiyonları, her çağrı e-posta+şifreyi sunucuda doğrular (`schema.sql`).
- Kayıt uygulamadan e-postayla yapılır (onay linki gerekir); kullanıcılar `hesap.users` tablosundadır, majka-panel'in Supabase Auth'u kullanılmaz (bkz. v9).

Şemayı uygulamak (sırayla, Supabase'e bağlı bir klasörden):

```bash
supabase db query --linked -f schema.sql
supabase db query --linked -f seed.local.sql
supabase db query --linked -f schema_v2.sql   # etkinlikler, katılımcılar, bölüşme, düzenleme
# ... schema_v3–v5 sırayla
supabase db query --linked -f schema_v6.sql   # etkinlik başına para birimi (TRY/USD/EUR/DKK/SEK/NOK)
supabase db query --linked -f schema_v7.sql   # aynı etkinlikte farklı birimlerle kayıt (kur kayda sabitlenir)
supabase db query --linked -f schema_v8.sql   # etkinliği yalnızca katılımcıları ve oluşturan görür
supabase db query --linked -f schema_v9.sql   # kayıt + e-posta onayı, arkadaşlık, etkinlik daveti
supabase functions deploy payday-auth --no-verify-jwt
```

## Özellikler (v2)

- Birden çok etkinlik/tatil defteri; her etkinlikte en fazla 10 katılımcı (giriş hesabı ya da misafir adı).
- Bölüşme: eşit / tutara göre / paya göre. Borç ödemesi kaydı.
- Kayıt düzenleme ve silme; "kim kime ne verecek" en az transferle hesaplanır.
- Logo/ikonlar `icons/` (SVG kaynak `logo.svg`, iOS ana ekran `apple-touch-icon.png`, manifest).

## Para birimleri (v6–v7)

- Her etkinliğin bir **ana birimi** var (TRY, USD, EUR, DKK, SEK, NOK); bakiye ve "kim kime ne verecek" bu birimde hesaplanır.
- Kayıtlar istenen birimde girilebilir. Kur, Avrupa Merkez Bankası'nın kayıt tarihindeki günlük kurundan otomatik gelir ([frankfurter.dev](https://frankfurter.dev)); elle değiştirilebilir. Kur kayda sabitlenir, sonradan değişmez.
- Kayıtta girilen tutar ve ana birim karşılığı birlikte görünür ("DKK 300,00 · ≈ €40,20"). Başka birimde kayıt varken ana birim değiştirilemez.

## Görünürlük (v8)

- Bir etkinliği yalnızca **katılımcıları** (giriş hesabıyla eklenenler) ve **oluşturan kişi** görür. Kural sunucuda uygulanır: liste, detay ve tüm değişiklik fonksiyonları kontrol eder; yetkisiz erişimde "etkinlik bulunamadı" denir.
- Bir kişiyi etkinliğe eklemek ona erişim verir; kendini çıkaran (oluşturan değilse) erişimini kaybeder.

## Kayıt, arkadaşlar, davetler (v9)

- **Kayıt:** ad + e-posta + şifre (en az 8). E-postaya gelen onay linkine tıklanmadan giriş yapılamaz. "Şifremi unuttum" e-postayla sıfırlama linki gönderir (1 saat geçerli).
- **Ayrılık:** Payday kullanıcıları yalnızca `hesap.users` tablosunda; majka-panel'in Supabase Auth'u (`auth.users`) ve diğer uygulamalar kullanılmaz. Onay/sıfırlama linkleri `hesap.auth_tokens`'ta (yalnızca sha256 özeti) tutulur.
- **E-posta:** `payday-auth` Edge Function'ı SMTP ile (465/SSL) gönderir. Gönderen info@majkasolutions.com (Turhost/GoDaddy, `smtpout.secureserver.net:465`); gereken tek gizli anahtar Supabase → Edge Functions → Secrets'taki `PAYDAY_SMTP_PASS`. `PAYDAY_SMTP_HOST/PORT/USER` ve `PAYDAY_MAIL_FROM` ile varsayılanlar değiştirilebilir.
- **Arkadaşlık:** e-postayla istek gönderilir, karşı taraf kabul eder. Yalnızca arkadaşlar etkinliğe davet edilebilir.
- **Davet:** davet edilen kişi kabul edene kadar etkinliği göremez; reddederse adıyla misafir olarak kalır (kayıtlar bozulmaz).
- **Görünürlük:** başkalarının IBAN'ı yalnızca arkadaşlara ve ortak etkinliktekilere görünür.
