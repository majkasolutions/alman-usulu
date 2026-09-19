-- Alman Usulü v5: piyon tekilliği (aynı amblemi iki kişi alamaz).
-- Mevcut çakışma: Fehim ve Gizem 🛵 — sıralamada sonra gelenin (Gizem) piyonu boşaltılır, yeniden seçer.
update hesap.users u set token = null
 where token is not null and exists (select 1 from hesap.users o where o.token = u.token and o.sort < u.sort);
create unique index if not exists users_token_uniq on hesap.users(token) where token is not null;

create or replace function public.hesap_set_token(p_email text, p_pass text, p_token text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; other text;
begin
  me := hesap.check_login(p_email, p_pass);
  if length(p_token) > 8 then raise exception 'geçersiz piyon'; end if;
  select name into other from hesap.users where token = nullif(p_token, '') and email <> me;
  if other is not null then raise exception 'Bu piyonu % aldı, başka seç', other; end if;
  update hesap.users set token = nullif(p_token, '') where email = me;
end $$;
