-- Payday v12: Dila'nın gerçek adresi (Ömercan'ın isteğiyle; uydurma dila@gmail.com kaldırıldı).
update hesap.users set email = 'dilaarslan35@gmail.com', mail_ok = true
where email = 'dila@gmail.com' and not exists (select 1 from hesap.users where email = 'dilaarslan35@gmail.com');
