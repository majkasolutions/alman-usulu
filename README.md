# Alman Usulü

Arkadaş grubunun harcama defteri (Splitwise benzeri). Tek sayfa, GitHub Pages'te yayınlanır.

- Canlı: https://majkasolutions.github.io/alman-usulu/
- Veri: `majka-panel` Supabase projesi, `hesap` şeması. Tablolar dışarıya kapalı; tek erişim `public.hesap_*` fonksiyonları, her çağrı e-posta+şifreyi sunucuda doğrular (`schema.sql`).
- Hesaplar sabittir (kayıt/şifre değişimi yok); `seed.local.sql` ile eklenir (repoya girmez).

Şemayı uygulamak (bir kez, Supabase'e bağlı bir klasörden):

```bash
supabase db query --linked -f schema.sql
supabase db query --linked -f seed.local.sql
```
