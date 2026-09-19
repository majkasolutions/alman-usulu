# Alman Usulü

Arkadaş grubunun harcama defteri (Splitwise benzeri). Tek sayfa, GitHub Pages'te yayınlanır.

- Canlı: https://majkasolutions.github.io/alman-usulu/
- Veri: `majka-panel` Supabase projesi, `hesap` şeması. Tablolar dışarıya kapalı; tek erişim `public.hesap_*` fonksiyonları, her çağrı e-posta+şifreyi sunucuda doğrular (`schema.sql`).
- Hesaplar sabittir (kayıt/şifre değişimi yok); `seed.local.sql` ile eklenir (repoya girmez).

Şemayı uygulamak (sırayla, Supabase'e bağlı bir klasörden):

```bash
supabase db query --linked -f schema.sql
supabase db query --linked -f seed.local.sql
supabase db query --linked -f schema_v2.sql   # etkinlikler, katılımcılar, bölüşme, düzenleme
```

## Özellikler (v2)

- Birden çok etkinlik/tatil defteri; her etkinlikte en fazla 10 katılımcı (giriş hesabı ya da misafir adı).
- Bölüşme: eşit / tutara göre / paya göre. Borç ödemesi kaydı.
- Kayıt düzenleme ve silme; "kim kime ne verecek" en az transferle hesaplanır.
- Logo/ikonlar `icons/` (SVG kaynak `logo.svg`, iOS ana ekran `apple-touch-icon.png`, manifest).
