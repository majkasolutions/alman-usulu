-- Payday v11: users.email değişince bağlı tüm satırlar da güncellensin (ON UPDATE CASCADE).
-- Kişi gerçek e-postasını girdiğinde etkinlikleri, kayıtları ve arkadaşlıkları kaybolmasın.
alter table hesap.expenses drop constraint expenses_created_by_fkey, add constraint expenses_created_by_fkey foreign key (created_by) references hesap.users(email) on update cascade;
alter table hesap.expenses drop constraint expenses_updated_by_fkey, add constraint expenses_updated_by_fkey foreign key (updated_by) references hesap.users(email) on update cascade;
alter table hesap.events drop constraint events_created_by_fkey, add constraint events_created_by_fkey foreign key (created_by) references hesap.users(email) on update cascade;
alter table hesap.participants drop constraint participants_invited_by_fkey, add constraint participants_invited_by_fkey foreign key (invited_by) references hesap.users(email) on update cascade;
alter table hesap.participants drop constraint participants_user_email_fkey, add constraint participants_user_email_fkey foreign key (user_email) references hesap.users(email) on update cascade;
alter table hesap.auth_tokens drop constraint auth_tokens_email_fkey, add constraint auth_tokens_email_fkey foreign key (email) references hesap.users(email) on update cascade;
alter table hesap.friendships drop constraint friendships_a_fkey, add constraint friendships_a_fkey foreign key (a) references hesap.users(email) on update cascade;
alter table hesap.friendships drop constraint friendships_b_fkey, add constraint friendships_b_fkey foreign key (b) references hesap.users(email) on update cascade;
alter table hesap.friendships drop constraint friendships_requested_by_fkey, add constraint friendships_requested_by_fkey foreign key (requested_by) references hesap.users(email) on update cascade;

-- Ömercan'ın gerçek adresi (kendisinin isteğiyle; uydurma omercan@gmail.com kaldırıldı)
update hesap.users set email = 'omercanalp@gmail.com', mail_ok = true where email = 'omercan@gmail.com';
