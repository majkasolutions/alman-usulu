-- Payday v9: e-postayla kayıt + onay, şifre sıfırlama, arkadaşlık, etkinlik daveti.
-- Her şey hesap şemasında; majka-panel'deki Supabase Auth (auth.users) ve diğer uygulamalar kullanılmaz.
-- E-postaları payday-auth Edge Function'ı gönderir (PAYDAY_ önekli SMTP anahtarları).
-- Silme yok: arkadaşlıktan çıkarma/ret durum alanıyla, davet reddi katılımcıyı misafire çevirerek yapılır.

-- ---------------------------------------------------------------- tablolar
alter table hesap.users
  add column if not exists email_verified_at timestamptz,
  add column if not exists created_at timestamptz not null default now();
update hesap.users set email_verified_at = now() where email_verified_at is null;  -- mevcut hesaplar onaylı

create table if not exists hesap.auth_tokens (
  id          uuid primary key default gen_random_uuid(),
  email       text not null references hesap.users(email),
  kind        text not null check (kind in ('verify', 'reset')),
  token_hash  text not null unique,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists auth_tokens_email_idx on hesap.auth_tokens(email, kind, created_at desc);

-- a < b; requested_by isteği gönderen
create table if not exists hesap.friendships (
  a            text not null references hesap.users(email),
  b            text not null references hesap.users(email),
  requested_by text not null references hesap.users(email),
  status       text not null check (status in ('pending', 'accepted', 'removed')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (a, b),
  check (a < b)
);

alter table hesap.participants
  add column if not exists status text not null default 'accepted',
  add column if not exists invited_by text references hesap.users(email);
alter table hesap.participants drop constraint if exists participants_status_check;
alter table hesap.participants add constraint participants_status_check check (status in ('invited', 'accepted'));

alter table hesap.auth_tokens enable row level security;
alter table hesap.friendships enable row level security;
revoke all on all tables in schema hesap from anon, authenticated;

-- mevcut hesaplar: aynı etkinlikte olanlar arkadaş
insert into hesap.friendships(a, b, requested_by, status)
select distinct least(p1.user_email, p2.user_email), greatest(p1.user_email, p2.user_email), least(p1.user_email, p2.user_email), 'accepted'
from hesap.participants p1 join hesap.participants p2 on p1.event_id = p2.event_id
where p1.user_email is not null and p2.user_email is not null and p1.user_email < p2.user_email
on conflict (a, b) do nothing;

-- ---------------------------------------------------------------- yardımcılar
create or replace function hesap.check_login(p_email text, p_pass text)
returns text language plpgsql security definer set search_path = hesap, extensions, public as $$
declare u hesap.users%rowtype;
begin
  select * into u from hesap.users where email = lower(trim(p_email));
  if u.email is null or u.pass_hash <> extensions.crypt(p_pass, u.pass_hash) then
    raise exception 'E-posta veya şifre hatalı' using errcode = '28000';
  end if;
  if u.email_verified_at is null then
    raise exception 'E-posta adresin henüz onaylanmadı. Gelen kutundaki linke tıkla.' using errcode = '28000', hint = 'unverified';
  end if;
  return u.email;
end $$;

create or replace function hesap.are_friends(x text, y text)
returns boolean language sql stable set search_path = hesap, public as $$
  select exists (select 1 from hesap.friendships where a = least(x, y) and b = greatest(x, y) and status = 'accepted');
$$;

-- davet bekleyen katılımcı etkinliği göremez
create or replace function hesap.can_see(p_event uuid, p_me text)
returns boolean language sql stable set search_path = hesap, public as $$
  select exists (select 1 from hesap.events where id = p_event and created_by = p_me)
      or exists (select 1 from hesap.participants where event_id = p_event and user_email = p_me and status = 'accepted');
$$;

-- p_me'nin görebileceği kullanıcılar: kendisi, arkadaşları, bekleyen istekler, ortak etkinliktekiler, davet edenler.
-- friend: arkadaş mı; req: 'in' (bana gelen) / 'out' (benim gönderdiğim) bekleyen istek; member: ortak etkinlikte mi.
-- IBAN/ad soyad yalnızca kendisi, arkadaşlar ve ortak etkinliktekiler için.
create or replace function hesap.visible_users(p_me text)
returns jsonb language sql stable set search_path = hesap, public as $$
  with f as (
    select case when a = p_me then b else a end as email, status, requested_by
      from hesap.friendships where (a = p_me or b = p_me) and status <> 'removed'
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
      'member', m.email is not null,
      'full_name', case when u.email = p_me or f.status = 'accepted' or m.email is not null then u.full_name end,
      'iban', case when u.email = p_me or f.status = 'accepted' or m.email is not null then u.iban end) order by u.sort), '[]'::jsonb)
  from ids join hesap.users u on u.email = ids.email
  left join f on f.email = u.email left join m on m.email = u.email;
$$;

-- ---------------------------------------------------------------- okuma
create or replace function public.hesap_get(p_email text, p_pass text)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text;
begin
  me := hesap.check_login(p_email, p_pass);
  return jsonb_build_object(
    'me', me,
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

create or replace function hesap.event_json(p_event uuid)
returns jsonb language sql stable set search_path = hesap, public as $$
  select jsonb_build_object(
    'id', ev.id, 'name', ev.name, 'currency', ev.currency, 'created_by', ev.created_by, 'created_at', ev.created_at,
    'participants', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'email', user_email, 'status', status) order by sort, created_at)
                              from hesap.participants where event_id = ev.id), '[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'kind', kind, 'payer', payer_pid, 'amount', amount, 'description', description,
        'spent_on', spent_on, 'split_mode', split_mode, 'shares', shares,
        'orig_currency', orig_currency, 'orig_amount', orig_amount, 'fx_rate', fx_rate,
        'created_by', created_by, 'created_at', created_at, 'updated_by', updated_by, 'updated_at', updated_at)
        order by spent_on desc, created_at desc) from hesap.expenses where event_id = ev.id), '[]'::jsonb)
  ) from hesap.events ev where ev.id = p_event;
$$;

create or replace function public.hesap_event(p_email text, p_pass text, p_event uuid)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; j jsonb;
begin
  me := hesap.check_login(p_email, p_pass);
  perform hesap.require_event(p_event, me);
  j := hesap.event_json(p_event);
  if j is null then raise exception 'etkinlik bulunamadı'; end if;
  return j || jsonb_build_object('me', me, 'users', hesap.visible_users(me));
end $$;

-- ---------------------------------------------------------------- etkinlik + davet
-- hesabı olan katılımcılar arkadaş olmalı; davet olarak eklenir (kendisi hariç)
create or replace function public.hesap_create_event(p_email text, p_pass text, p_name text, p_participants jsonb)
returns uuid language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; ev uuid; it jsonb; i int := 0; em text;
begin
  me := hesap.check_login(p_email, p_pass);
  if jsonb_array_length(coalesce(p_participants, '[]'::jsonb)) < 1 then raise exception 'en az bir katılımcı gerekli'; end if;
  if jsonb_array_length(p_participants) > 10 then raise exception 'en fazla 10 katılımcı'; end if;
  insert into hesap.events(name, created_by) values (trim(p_name), me) returning id into ev;
  for it in select * from jsonb_array_elements(p_participants) loop
    i := i + 1;
    em := lower(nullif(trim(it->>'email'), ''));
    if em is not null and em <> me and not hesap.are_friends(me, em) then
      raise exception 'Sadece arkadaşlarını davet edebilirsin';
    end if;
    insert into hesap.participants(event_id, name, user_email, sort, status, invited_by)
      values (ev, trim(it->>'name'), em, i,
              case when em is null or em = me then 'accepted' else 'invited' end,
              case when em is not null and em <> me then me end);
  end loop;
  return ev;
end $$;

create or replace function public.hesap_add_participant(p_email text, p_pass text, p_event uuid, p_name text, p_user_email text)
returns uuid language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; pid uuid; n int; em text;
begin
  me := hesap.check_login(p_email, p_pass);
  perform hesap.require_event(p_event, me);
  em := lower(nullif(trim(p_user_email), ''));
  if em is not null and em <> me and not hesap.are_friends(me, em) then
    raise exception 'Sadece arkadaşlarını davet edebilirsin';
  end if;
  select count(*) into n from hesap.participants where event_id = p_event;
  if n >= 10 then raise exception 'en fazla 10 katılımcı'; end if;
  insert into hesap.participants(event_id, name, user_email, sort, status, invited_by)
    values (p_event, trim(p_name), em, n + 1,
            case when em is null or em = me then 'accepted' else 'invited' end,
            case when em is not null and em <> me then me end)
    returning id into pid;
  return pid;
end $$;

-- kabul: etkinliği görür. ret: hesapla bağı kopar, adıyla misafir olarak kalır (kayıtlar bozulmasın)
create or replace function public.hesap_invite_respond(p_email text, p_pass text, p_event uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text;
begin
  me := hesap.check_login(p_email, p_pass);
  if p_accept then
    update hesap.participants set status = 'accepted' where event_id = p_event and user_email = me and status = 'invited';
  else
    update hesap.participants set status = 'accepted', user_email = null where event_id = p_event and user_email = me and status = 'invited';
  end if;
  if not found then raise exception 'davet bulunamadı'; end if;
end $$;

-- ---------------------------------------------------------------- arkadaşlık
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

create or replace function public.hesap_friend_respond(p_email text, p_pass text, p_other text, p_accept boolean)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; o text := lower(trim(p_other));
begin
  me := hesap.check_login(p_email, p_pass);
  update hesap.friendships set status = case when p_accept then 'accepted' else 'removed' end, updated_at = now()
    where a = least(me, o) and b = greatest(me, o) and status = 'pending' and requested_by = o;
  if not found then raise exception 'istek bulunamadı'; end if;
end $$;

-- arkadaşlıktan çıkar ya da gönderilen isteği geri al (ortak etkinlikler etkilenmez)
create or replace function public.hesap_friend_remove(p_email text, p_pass text, p_other text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; o text := lower(trim(p_other));
begin
  me := hesap.check_login(p_email, p_pass);
  update hesap.friendships set status = 'removed', updated_at = now()
    where a = least(me, o) and b = greatest(me, o) and status <> 'removed';
end $$;

-- ---------------------------------------------------------------- kayıt / onay / şifre sıfırlama
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
            now() + case when p_kind = 'verify' then interval '48 hours' else interval '1 hour' end);
  return raw;
end $$;

-- yalnızca payday-auth (service_role) çağırır
create or replace function public.hesap_srv_register(p_email text, p_name text, p_pass text)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare em text := lower(trim(coalesce(p_email, ''))); nm text := trim(coalesce(p_name, '')); u hesap.users%rowtype;
begin
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(em) > 120 then raise exception 'Geçerli bir e-posta gir'; end if;
  if length(nm) not between 2 and 40 then raise exception 'Ad 2–40 karakter olmalı'; end if;
  if length(coalesce(p_pass, '')) < 8 then raise exception 'Şifre en az 8 karakter olmalı'; end if;
  select * into u from hesap.users where email = em;
  if u.email is not null and u.email_verified_at is not null then
    raise exception 'Bu e-posta zaten kayıtlı. Giriş yap ya da şifreni sıfırla.';
  end if;
  if u.email is null then
    insert into hesap.users(email, name, pass_hash, sort)
      values (em, nm, extensions.crypt(p_pass, extensions.gen_salt('bf')), coalesce((select max(sort) from hesap.users), 0) + 1);
  else
    update hesap.users set name = nm, pass_hash = extensions.crypt(p_pass, extensions.gen_salt('bf')) where email = em;
  end if;
  return jsonb_build_object('email', em, 'name', nm, 'token', hesap.new_token(em, 'verify'));
end $$;

-- onay e-postasını yeniden gönder / şifre sıfırlama: kullanıcı yoksa (ya da zaten onaylıysa) null döner
create or replace function public.hesap_srv_token(p_email text, p_kind text)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare u hesap.users%rowtype;
begin
  select * into u from hesap.users where email = lower(trim(coalesce(p_email, '')));
  if u.email is null or p_kind not in ('verify', 'reset') then return null; end if;
  if p_kind = 'verify' and u.email_verified_at is not null then return null; end if;
  return jsonb_build_object('email', u.email, 'name', u.name, 'token', hesap.new_token(u.email, p_kind));
end $$;

create or replace function hesap.use_token(p_token text, p_kind text)
returns text language plpgsql security definer set search_path = hesap, extensions, public as $$
declare em text;
begin
  update hesap.auth_tokens set used_at = now()
    where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
      and kind = p_kind and used_at is null and expires_at > now()
    returning email into em;
  if em is null then raise exception 'Link geçersiz ya da süresi dolmuş'; end if;
  return em;
end $$;

create or replace function public.hesap_verify(p_token text)
returns text language plpgsql security definer set search_path = hesap, extensions, public as $$
declare em text;
begin
  em := hesap.use_token(p_token, 'verify');
  update hesap.users set email_verified_at = coalesce(email_verified_at, now()) where email = em;
  return em;
end $$;

-- e-postadaki linke tıklayan adresin sahibidir: şifre değişir, adres de onaylanmış sayılır
create or replace function public.hesap_reset_password(p_token text, p_new_pass text)
returns text language plpgsql security definer set search_path = hesap, extensions, public as $$
declare em text;
begin
  if length(coalesce(p_new_pass, '')) < 8 then raise exception 'Şifre en az 8 karakter olmalı'; end if;
  em := hesap.use_token(p_token, 'reset');
  update hesap.users set pass_hash = extensions.crypt(p_new_pass, extensions.gen_salt('bf')),
                         email_verified_at = coalesce(email_verified_at, now()) where email = em;
  return em;
end $$;

-- ---------------------------------------------------------------- yetkiler
revoke all on function public.hesap_srv_register(text, text, text) from public, anon, authenticated;
revoke all on function public.hesap_srv_token(text, text) from public, anon, authenticated;
grant execute on function public.hesap_srv_register(text, text, text) to service_role;
grant execute on function public.hesap_srv_token(text, text) to service_role;
revoke all on function hesap.new_token(text, text) from public, anon, authenticated;
revoke all on function hesap.use_token(text, text) from public, anon, authenticated;

grant execute on function
  public.hesap_invite_respond(text, text, uuid, boolean),
  public.hesap_friend_request(text, text, text),
  public.hesap_friend_respond(text, text, text, boolean),
  public.hesap_friend_remove(text, text, text),
  public.hesap_verify(text),
  public.hesap_reset_password(text, text)
to anon, authenticated;
