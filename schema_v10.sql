-- Payday v10: ilk 7 hesap gerçek olmayan adreslerle (ör. fehim@gmail.com) açılmıştı. Bu adreslerin
-- gerçek sahibi "Şifremi unuttum" ile hesabı ele geçirebilirdi; bu hesaplara e-posta gönderilmez.
-- Kişi gerçek adresini doğrulayınca mail_ok yeniden açılır.
alter table hesap.users add column if not exists mail_ok boolean not null default true;
update hesap.users set mail_ok = false where created_at < '2026-10-22 15:00:00+00';

create or replace function public.hesap_srv_token(p_email text, p_kind text)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare u hesap.users%rowtype;
begin
  select * into u from hesap.users where email = lower(trim(coalesce(p_email, '')));
  if u.email is null or not u.mail_ok or p_kind not in ('verify', 'reset') then return null; end if;
  if p_kind = 'verify' and u.email_verified_at is not null then return null; end if;
  return jsonb_build_object('email', u.email, 'name', u.name, 'token', hesap.new_token(u.email, p_kind));
end $$;
revoke all on function public.hesap_srv_token(text, text) from public, anon, authenticated;
grant execute on function public.hesap_srv_token(text, text) to service_role;
