-- Payday v13: oturum anahtarı, Hesabım (ad / e-posta / şifre değiştirme, hesap silme),
-- arkadaş engelleme, gizlilik onayı, hatalı girişte kilit.
--
-- Oturum: hesap_login şifreyi bir kez doğrular ve "pds_…" anahtarı verir; uygulama şifre yerine
-- bunu saklar ve p_pass olarak gönderir. check_login ikisini de kabul eder (eski oturumlar ilk
-- açılışta anahtara çevrilir). Anahtarın yalnızca sha256 özeti saklanır; 90 gün kullanılmazsa düşer.
-- Hesap silme: kişisel veriler silinir (ad, e-posta, şifre, IBAN); etkinliklerdeki kayıtlar
-- bozulmasın diye kişi o etkinliklerde adıyla misafir olarak kalır.

-- ---------------------------------------------------------------- tablolar
alter table hesap.users
  add column if not exists failed_logins int not null default 0,
  add column if not exists locked_until timestamptz,
  add column if not exists privacy_accepted_at timestamptz,
  add column if not exists deleted_at timestamptz;

create table if not exists hesap.sessions (
  id           uuid primary key default gen_random_uuid(),
  email        text not null references hesap.users(email) on update cascade,
  token_hash   text not null unique,
  device       text,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz not null default now(),
  expires_at   timestamptz not null,
  revoked_at   timestamptz
);
create index if not exists sessions_email_idx on hesap.sessions(email);
alter table hesap.sessions enable row level security;

alter table hesap.auth_tokens add column if not exists new_email text;
alter table hesap.auth_tokens drop constraint if exists auth_tokens_kind_check;
alter table hesap.auth_tokens add constraint auth_tokens_kind_check check (kind in ('verify', 'reset', 'email'));

alter table hesap.friendships drop constraint if exists friendships_status_check;
alter table hesap.friendships add constraint friendships_status_check check (status in ('pending', 'accepted', 'removed', 'blocked'));
revoke all on all tables in schema hesap from anon, authenticated;

-- e-posta değişince (ON UPDATE CASCADE) a < b sırası bozulmasın
create or replace function hesap.friendships_norm()
returns trigger language plpgsql as $$
declare t text;
begin
  if new.a > new.b then t := new.a; new.a := new.b; new.b := t; end if;
  return new;
end $$;
create or replace trigger friendships_norm before insert or update on hesap.friendships
  for each row execute function hesap.friendships_norm();

-- ---------------------------------------------------------------- giriş / oturum
create or replace function hesap.check_login(p_email text, p_pass text)
returns text language plpgsql security definer set search_path = hesap, extensions, public as $$
declare u hesap.users%rowtype; em text := lower(trim(coalesce(p_email, ''))); sid uuid;
begin
  if left(coalesce(p_pass, ''), 4) = 'pds_' then
    update hesap.sessions set last_used_at = now(), expires_at = now() + interval '90 days'
      where token_hash = encode(extensions.digest(p_pass, 'sha256'), 'hex')
        and email = em and revoked_at is null and expires_at > now()
      returning id into sid;
    if sid is null then
      raise exception 'Oturumun sona erdi, tekrar giriş yap' using errcode = '28000', hint = 'session';
    end if;
    return em;
  end if;
  select * into u from hesap.users where email = em;
  if u.email is null or u.pass_hash <> extensions.crypt(p_pass, u.pass_hash) then
    raise exception 'E-posta veya şifre hatalı' using errcode = '28000';
  end if;
  if u.email_verified_at is null then
    raise exception 'E-posta adresin henüz onaylanmadı. Gelen kutundaki linke tıkla.' using errcode = '28000', hint = 'unverified';
  end if;
  return u.email;
end $$;

-- hata fırlatmaz ({error}) ki hatalı deneme sayacı geri alınmasın; 10 hatada 15 dk kilit
create or replace function public.hesap_login(p_email text, p_pass text, p_device text default null)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare u hesap.users%rowtype; em text := lower(trim(coalesce(p_email, ''))); raw text;
begin
  select * into u from hesap.users where email = em;
  if u.email is null then return jsonb_build_object('error', 'E-posta veya şifre hatalı'); end if;
  if u.locked_until > now() then
    return jsonb_build_object('error', 'Çok fazla hatalı deneme. 15 dakika sonra tekrar dene ya da şifreni sıfırla.');
  end if;
  if u.pass_hash <> extensions.crypt(coalesce(p_pass, ''), u.pass_hash) then
    update hesap.users set
      failed_logins = case when failed_logins + 1 >= 10 then 0 else failed_logins + 1 end,
      locked_until  = case when failed_logins + 1 >= 10 then now() + interval '15 minutes' else locked_until end
      where email = em;
    return jsonb_build_object('error', 'E-posta veya şifre hatalı');
  end if;
  if u.email_verified_at is null then
    return jsonb_build_object('error', 'E-posta adresin henüz onaylanmadı. Gelen kutundaki linke tıkla.', 'code', 'unverified');
  end if;
  update hesap.users set failed_logins = 0, locked_until = null where email = em;
  raw := 'pds_' || encode(extensions.gen_random_bytes(32), 'hex');
  insert into hesap.sessions(email, token_hash, device, expires_at)
    values (em, encode(extensions.digest(raw, 'sha256'), 'hex'), left(p_device, 160), now() + interval '90 days');
  return jsonb_build_object('email', em, 'token', raw);
end $$;

create or replace function public.hesap_logout(p_email text, p_pass text)
returns void language sql security definer set search_path = hesap, extensions, public as $$
  update hesap.sessions set revoked_at = now()
   where token_hash = encode(extensions.digest(coalesce(p_pass, ''), 'sha256'), 'hex') and revoked_at is null;
$$;

-- ---------------------------------------------------------------- kullanıcılar (engelleme dahil)
-- blocked: yalnızca engelleyen görür; engellenen için kayıt yokmuş gibi davranılır.
create or replace function hesap.visible_users(p_me text)
returns jsonb language sql stable set search_path = hesap, public as $$
  with f as (
    select case when a = p_me then b else a end as email, status, requested_by
      from hesap.friendships
     where (a = p_me or b = p_me) and status <> 'removed'
       and not (status = 'blocked' and requested_by <> p_me)
  ), m as (
    select distinct p.user_email as email from hesap.participants p
      where p.user_email is not null and hesap.can_see(p.event_id, p_me)
  ), i as (
    select distinct invited_by as email from hesap.participants
      where user_email = p_me and status = 'invited' and invited_by is not null
  ), ids as (
    select p_me as email union select email from f union select email from m union select email from i
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'email', u.email, 'name', u.name, 'token', u.token,
      'friend', coalesce(f.status = 'accepted', false),
      'req', case when f.status = 'pending' then case when f.requested_by = p_me then 'out' else 'in' end end,
      'blocked', coalesce(f.status = 'blocked', false),
      'member', m.email is not null,
      'full_name', case when u.email = p_me or f.status = 'accepted' or m.email is not null then u.full_name end,
      'iban', case when u.email = p_me or f.status = 'accepted' or m.email is not null then u.iban end) order by u.sort), '[]'::jsonb)
  from ids join hesap.users u on u.email = ids.email
  left join f on f.email = u.email left join m on m.email = u.email;
$$;

create or replace function public.hesap_get(p_email text, p_pass text)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text;
begin
  me := hesap.check_login(p_email, p_pass);
  return jsonb_build_object(
    'me', me,
    'account', (select jsonb_build_object('email', email, 'name', name, 'mail_ok', mail_ok) from hesap.users where email = me),
    'users', hesap.visible_users(me),
    'invites', coalesce((select jsonb_agg(jsonb_build_object(
        'event', ev.id, 'name', ev.name, 'by', p.invited_by,
        'by_name', (select name from hesap.users where email = p.invited_by),
        'participant_count', (select count(*) from hesap.participants where event_id = ev.id)) order by p.created_at desc)
        from hesap.participants p join hesap.events ev on ev.id = p.event_id
        where p.user_email = me and p.status = 'invited'), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object(
        'id', ev.id, 'name', ev.name, 'currency', ev.currency, 'created_at', ev.created_at,
        'participant_count', (select count(*) from hesap.participants where event_id = ev.id),
        'expense_count', (select count(*) from hesap.expenses where event_id = ev.id),
        'total', (select coalesce(sum(amount),0) from hesap.expenses where event_id = ev.id and kind = 'expense'),
        'last_at', (select max(created_at) from hesap.expenses where event_id = ev.id))
        order by coalesce((select max(created_at) from hesap.expenses where event_id = ev.id), ev.created_at) desc)
        from hesap.events ev where hesap.can_see(ev.id, me)), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------- arkadaşlık + engelleme
create or replace function public.hesap_friend_request(p_email text, p_pass text, p_target text)
returns text language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; t text; f hesap.friendships%rowtype;
begin
  me := hesap.check_login(p_email, p_pass);
  t := lower(trim(coalesce(p_target, '')));
  if t = me then raise exception 'Kendini ekleyemezsin'; end if;
  if not exists (select 1 from hesap.users where email = t and email_verified_at is not null) then
    raise exception 'Bu e-postayla kayıtlı Payday kullanıcısı yok';
  end if;
  select * into f from hesap.friendships where a = least(me, t) and b = greatest(me, t);
  if f.a is not null and f.status = 'blocked' then
    if f.requested_by = me then raise exception 'Bu kişiyi engelledin; önce engeli kaldır'; end if;
    raise exception 'Bu e-postayla kayıtlı Payday kullanıcısı yok';
  end if;
  if f.a is not null and f.status = 'accepted' then raise exception 'Zaten arkadaşsınız'; end if;
  if f.a is not null and f.status = 'pending' and f.requested_by = t then
    update hesap.friendships set status = 'accepted', updated_at = now() where a = f.a and b = f.b;
    return 'accepted';
  end if;
  if f.a is not null and f.status = 'pending' then raise exception 'İstek zaten gönderildi'; end if;
  insert into hesap.friendships(a, b, requested_by, status) values (least(me, t), greatest(me, t), me, 'pending')
    on conflict (a, b) do update set requested_by = me, status = 'pending', updated_at = now();
  return 'pending';
end $$;

-- arkadaşlıktan çıkar / isteği geri al / kendi engelini kaldır (karşı tarafın engeline dokunmaz)
create or replace function public.hesap_friend_remove(p_email text, p_pass text, p_other text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; o text := lower(trim(p_other));
begin
  me := hesap.check_login(p_email, p_pass);
  update hesap.friendships set status = 'removed', updated_at = now()
    where a = least(me, o) and b = greatest(me, o) and status <> 'removed'
      and not (status = 'blocked' and requested_by <> me);
end $$;

-- engellenen kişi istek gönderemez, davet edilemez (arkadaş değil), listende görünmez
create or replace function public.hesap_friend_block(p_email text, p_pass text, p_other text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; o text := lower(trim(p_other));
begin
  me := hesap.check_login(p_email, p_pass);
  if o = me or not exists (select 1 from hesap.users where email = o) then raise exception 'kullanıcı bulunamadı'; end if;
  insert into hesap.friendships(a, b, requested_by, status) values (least(me, o), greatest(me, o), me, 'blocked')
    on conflict (a, b) do update set requested_by = me, status = 'blocked', updated_at = now()
    where hesap.friendships.status <> 'blocked';
end $$;

-- ---------------------------------------------------------------- Hesabım
create or replace function public.hesap_set_name(p_email text, p_pass text, p_name text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; nm text := trim(coalesce(p_name, ''));
begin
  me := hesap.check_login(p_email, p_pass);
  if length(nm) not between 2 and 40 then raise exception 'Ad 2–40 karakter olmalı'; end if;
  update hesap.users set name = nm where email = me;
  -- etkinliklerdeki adı da güncelle (o etkinlikte aynı ad başka birinde yoksa)
  update hesap.participants p set name = nm
   where p.user_email = me
     and not exists (select 1 from hesap.participants q where q.event_id = p.event_id and q.name = nm and q.id <> p.id);
end $$;

create or replace function public.hesap_change_password(p_email text, p_pass text, p_old text, p_new text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; u hesap.users%rowtype;
begin
  me := hesap.check_login(p_email, p_pass);
  select * into u from hesap.users where email = me;
  if u.pass_hash <> extensions.crypt(coalesce(p_old, ''), u.pass_hash) then raise exception 'Mevcut şifren yanlış'; end if;
  if length(coalesce(p_new, '')) < 8 then raise exception 'Yeni şifre en az 8 karakter olmalı'; end if;
  update hesap.users set pass_hash = extensions.crypt(p_new, extensions.gen_salt('bf')) where email = me;
  -- diğer cihazlardaki oturumlar kapanır, bu cihaz açık kalır
  update hesap.sessions set revoked_at = now()
   where email = me and revoked_at is null
     and token_hash <> encode(extensions.digest(coalesce(p_pass, ''), 'sha256'), 'hex');
end $$;

-- kişisel veriler silinir; etkinliklerdeki geçmiş kayıtlar bozulmasın diye kişi adıyla misafir olur
create or replace function public.hesap_delete_account(p_email text, p_pass text, p_confirm_pass text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; u hesap.users%rowtype;
begin
  me := hesap.check_login(p_email, p_pass);
  select * into u from hesap.users where email = me;
  if u.pass_hash <> extensions.crypt(coalesce(p_confirm_pass, ''), u.pass_hash) then raise exception 'Şifren yanlış'; end if;
  update hesap.participants set user_email = null, status = 'accepted' where user_email = me;
  update hesap.friendships set status = 'removed', updated_at = now() where me in (a, b);
  update hesap.auth_tokens set used_at = now() where email = me and used_at is null;
  update hesap.sessions set revoked_at = now() where email = me and revoked_at is null;
  update hesap.users set
    email = 'silindi-' || replace(gen_random_uuid()::text, '-', '') || '@payday.invalid',
    name = 'Silinmiş kullanıcı', pass_hash = extensions.crypt(encode(extensions.gen_random_bytes(24), 'hex'), extensions.gen_salt('bf')),
    full_name = null, iban = null, token = null, email_verified_at = null, mail_ok = false, deleted_at = now()
  where email = me;
end $$;

-- ---------------------------------------------------------------- e-posta değiştirme
create or replace function hesap.new_token(p_email text, p_kind text)
returns text language plpgsql security definer set search_path = hesap, extensions, public as $$
declare raw text;
begin
  if exists (select 1 from hesap.auth_tokens where email = p_email and kind = p_kind and created_at > now() - interval '60 seconds') then
    raise exception 'Biraz bekle, az önce e-posta gönderildi';
  end if;
  raw := encode(extensions.gen_random_bytes(24), 'hex');
  update hesap.auth_tokens set used_at = now() where email = p_email and kind = p_kind and used_at is null;
  insert into hesap.auth_tokens(email, kind, token_hash, expires_at)
    values (p_email, p_kind, encode(extensions.digest(raw, 'sha256'), 'hex'),
            now() + case when p_kind = 'reset' then interval '1 hour' else interval '48 hours' end);
  return raw;
end $$;

-- yalnızca payday-auth (service_role) çağırır; onay linki YENİ adrese gider
create or replace function public.hesap_srv_email_change(p_email text, p_pass text, p_new_email text)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; ne text := lower(trim(coalesce(p_new_email, ''))); raw text;
begin
  me := hesap.check_login(p_email, p_pass);
  if ne !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(ne) > 120 then raise exception 'Geçerli bir e-posta gir'; end if;
  if ne = me then raise exception 'Bu zaten şu anki e-postan'; end if;
  if exists (select 1 from hesap.users where email = ne) then raise exception 'Bu e-posta başka bir hesapta kayıtlı'; end if;
  raw := hesap.new_token(me, 'email');
  update hesap.auth_tokens set new_email = ne where token_hash = encode(extensions.digest(raw, 'sha256'), 'hex');
  return jsonb_build_object('email', ne, 'name', (select name from hesap.users where email = me), 'token', raw);
end $$;

create or replace function public.hesap_confirm_email(p_token text)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare em text; ne text;
begin
  update hesap.auth_tokens set used_at = now()
    where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
      and kind = 'email' and used_at is null and expires_at > now()
    returning email, new_email into em, ne;
  if em is null then raise exception 'Link geçersiz ya da süresi dolmuş'; end if;
  if exists (select 1 from hesap.users where email = ne) then raise exception 'Bu e-posta başka bir hesapta kayıtlı'; end if;
  update hesap.users set email = ne, mail_ok = true, email_verified_at = coalesce(email_verified_at, now()) where email = em;
  return jsonb_build_object('old', em, 'new', ne);
end $$;

-- ---------------------------------------------------------------- kayıt: gizlilik onayı
create or replace function public.hesap_srv_register(p_email text, p_name text, p_pass text, p_consent boolean)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare r jsonb;
begin
  if not coalesce(p_consent, false) then raise exception 'Devam etmek için gizlilik politikasını onaylamalısın'; end if;
  r := public.hesap_srv_register(p_email, p_name, p_pass);
  update hesap.users set privacy_accepted_at = now() where email = r->>'email';
  return r;
end $$;

-- ---------------------------------------------------------------- yetkiler
revoke all on function public.hesap_srv_register(text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.hesap_srv_email_change(text, text, text) from public, anon, authenticated;
grant execute on function public.hesap_srv_register(text, text, text, boolean) to service_role;
grant execute on function public.hesap_srv_email_change(text, text, text) to service_role;

grant execute on function
  public.hesap_login(text, text, text),
  public.hesap_logout(text, text),
  public.hesap_friend_block(text, text, text),
  public.hesap_set_name(text, text, text),
  public.hesap_change_password(text, text, text, text),
  public.hesap_delete_account(text, text, text),
  public.hesap_confirm_email(text)
to anon, authenticated;
