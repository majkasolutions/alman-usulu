# Devam notu (Claude Code oturumları arası)

Son güncelleme: 27 Ekim 2026 (bilgisayar). PR #5 canlıda (v13 + payday-auth yüklendi, squash f573f94). Çalışma dalı: `payday-yetkiler` (v14).

## Canlıda olanlar
- Para birimleri (etkinlik ana birimi + kayıt bazında farklı birim, ECB kuru) — PR #1.
- Etkinlik görünürlüğü (yalnızca katılımcılar) — PR #2.
- Kayıt + e-posta onayı, şifre sıfırlama, arkadaşlık, etkinlik daveti; `payday-auth` Edge Function (SMTP: Turhost `srvm06.trwww.com:465`, gizli anahtar `PAYDAY_SMTP_PASS`) — PR #3, #4.
- Veritabanında ayrıca: schema_v10, v11, v12 (canlıya uygulandı; PR #5 içinde repoya giriyor). Gerçek e-posta düzeltmeleri kişisel veri olduğu için repoda tutulmuyor (`*.local.sql`, .gitignore).

## v14 — yetkiler (dal `payday-yetkiler`)
- Kaydı yalnızca ekleyen ya da etkinlik sahibi düzenler/siler; silinen kayıt "Silinenler"den geri alınır (soft delete).
- Etkinlik silme, para birimi, başkasını çıkarma yalnızca sahipte; herkes kendisi ayrılabilir.
- Değişiklik geçmişi (`hesap.activity`, son 50 satır), ödemede alıcı "Aldım" onayı (tutar/kişi değişince düşer).
- v14 eski sayfayla da uyumlu (imzalar aynı), önce veritabanı sonra sayfa.
- Test: canlı veritabanında geri alınan işlemle 15 senaryo + sahte sunucuya karşı tarayıcıda iki kullanıcı görünümü.

## PR #5 (CANLI, 27.10)
- `schema_v13.sql`: oturum anahtarı (ham şifre yalnızca `hesap_login`'de, 10 hatada kilit), Hesabım (ad/e-posta/şifre değiştirme, hesap silme), arkadaş engelleme, gizlilik onayı, piyon izin listesi, eski fonksiyonlar dışarıya kapalı, bcrypt 10.
- `index.html`: Hesabım kartı, gerçek e-posta uyarısı, engelleme, oturum anahtarına otomatik geçiş, gizlilik onay kutusu.
- `privacy.html`: gizlilik politikası + KVKK aydınlatma metni (yayından önce hukukçuya gösterilmeli; unvan/adres eklenmeli).
- `supabase/functions/payday-auth/`: e-posta değiştirme akışı, gizlilik onayı, emojisiz konu satırları — **yüklenmedi** (v13'e ihtiyaç duyuyor).
- Tümü gerçek veritabanında geri alınan (rollback) işlemlerle ve Playwright ile sahte sunucuya karşı test edildi.

### Yayına alma sırası (birlikte yapılmalı)
1. `schema_v13.sql` uygula (Supabase MCP `apply_migration`; içinde `delete` ifadesi yok).
2. `payday-auth`'u `index.ts` + `mail.ts` ile yeniden yükle (`verify_jwt: false`).
3. PR #5'i **squash** ile birleştir (dalın eski commit'leri main'e girmesin).
Not: v13 sonrası herkes bir kez yeniden giriş yapabilir (eski oturumlar otomatik anahtara çevrilir).

## Karar bekleyenler
1. ~~PR #5 yayına alma~~ — yapıldı 27.10.
2. ~~2. adım~~ (v14, yukarıda) — yetkiler: kaydı yalnızca ekleyen ya da etkinlik sahibi düzenleyip silsin; etkinliği yalnızca sahip silsin / para birimini değiştirsin / başkasını çıkarsın; silinen kayıt geri alınabilsin (soft delete); değişiklik geçmişi (aktivite); ödemede alıcı onayı.
3. Ödeme Faz 1: "Öde" kartı (IBAN + ad + tutar + açıklama tek dokunuş, banka uygulaması kısayolu), "Gönderdim / Aldım", WhatsApp hatırlatma.
4. Dal geçmişi: main temiz (squash). Eski dal `claude/program-currency-options-tdlc3y` uzakta hâlâ duruyor → silinmeli (`git push origin --delete …`); PR #5 sayfasındaki eski commit'ler yalnızca GitHub desteğiyle silinir.

## Diğer yapılacaklar
- 3 hesabın e-postası hâlâ uydurma (bu hesaplara e-posta gönderilmiyor; Hesabım ile kendileri güncelleyebilecek).
- KVKK: yurt dışı aktarım için standart sözleşme + Kurum'a bildirim (hukukçu/mali müşavir).
- App Store (27.10 KARAR: çıkılacak): önce ayrı Supabase projesine taşıma; Apple Developer hesabı (mevcut bireysel hesap yeter), Capacitor ile iOS kabuğu, push bildirim, mağaza adı ("Payday: Hesap Bölüşme"), 1024px ikon, ekran görüntüleri, demo hesap.
- Gelir: lansmanda temel özellikler ücretsiz + bahşiş; sonra Etkinlik+ / Payday Plus (Apple IAP).
- Raporlar (kod denetimi, rakip analizi, ödeme/gelir) sohbette dosya olarak paylaşıldı; repoya konmadı (repo herkese açık).
