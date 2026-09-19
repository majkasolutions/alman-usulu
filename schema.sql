-- Alman Usulü: 4 arkadaşın harcama defteri (Splitwise benzeri).
-- Tablolar `hesap` şemasında, dışarıya KAPALI (RLS açık, politika yok).
-- Tek erişim yolu: public.hesap_* fonksiyonları; her çağrı e-posta+şifreyi
-- sunucuda doğrular (pgcrypto/crypt). Kayıt yok, şifre değişimi yok.

create extension if not exists pgcrypto with schema extensions;
create schema if not exists hesap;

create table if not exists hesap.users (
  email       text primary key,
  name        text not null,
  pass_hash   text not null,
  sort        int  not null default 0
);

create table if not exists hesap.expenses (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null default 'expense' check (kind in ('expense','payment')),
  payer        text not null references hesap.users(email),
  amount       numeric(12,2) not null check (amount > 0),
  description  text not null check (length(description) between 1 and 120),
  spent_on     date not null default current_date,
  split        text[] not null check (cardinality(split) >= 1),
  created_by   text not null references hesap.users(email),
  created_at   timestamptz not null default now()
);
create index if not exists expenses_date_idx on hesap.expenses(spent_on desc, created_at desc);

alter table hesap.users    enable row level security;
alter table hesap.expenses enable row level security;
revoke all on all tables in schema hesap from anon, authenticated;

-- Kullanıcılar seed.local.sql ile eklenir (repoya girmez; şifre içerir).

-- ---------------------------------------------------------------- yardımcı
create or replace function hesap.check_login(p_email text, p_pass text)
returns text language plpgsql security definer set search_path = hesap, extensions, public as $$
declare u hesap.users%rowtype;
begin
  select * into u from hesap.users where email = lower(trim(p_email));
  if u.email is null or u.pass_hash <> extensions.crypt(p_pass, u.pass_hash) then
    raise exception 'E-posta veya şifre hatalı' using errcode = '28000';
  end if;
  return u.email;
end $$;

-- ---------------------------------------------------------------- API
create or replace function public.hesap_get(p_email text, p_pass text)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text;
begin
  me := hesap.check_login(p_email, p_pass);
  return jsonb_build_object(
    'me', me,
    'users', (select jsonb_agg(jsonb_build_object('email', email, 'name', name) order by sort) from hesap.users),
    'expenses', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'kind', kind, 'payer', payer, 'amount', amount, 'description', description,
        'spent_on', spent_on, 'split', to_jsonb(split), 'created_by', created_by, 'created_at', created_at)
        order by spent_on desc, created_at desc) from hesap.expenses), '[]'::jsonb)
  );
end $$;

create or replace function public.hesap_add_expense(
  p_email text, p_pass text, p_kind text, p_payer text, p_amount numeric,
  p_description text, p_spent_on date, p_split text[])
returns uuid language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; e uuid; n int;
begin
  me := hesap.check_login(p_email, p_pass);
  if not exists (select 1 from hesap.users where email = p_payer) then raise exception 'ödeyen tanınmıyor'; end if;
  select count(distinct s) into n from unnest(p_split) s join hesap.users u on u.email = s;
  if n = 0 or n <> cardinality(p_split) then raise exception 'paylaşım listesi hatalı'; end if;
  if p_kind = 'payment' and (n <> 1 or p_split[1] = p_payer) then raise exception 'ödeme tek kişiye yapılır'; end if;
  insert into hesap.expenses(kind, payer, amount, description, spent_on, split, created_by)
  values (coalesce(p_kind,'expense'), p_payer, round(p_amount, 2), trim(p_description),
          coalesce(p_spent_on, current_date), p_split, me)
  returning id into e;
  return e;
end $$;

create or replace function public.hesap_delete_expense(p_email text, p_pass text, p_expense uuid)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
begin
  perform hesap.check_login(p_email, p_pass);
  delete from hesap.expenses where id = p_expense;
end $$;

grant execute on function
  public.hesap_get(text, text),
  public.hesap_add_expense(text, text, text, text, numeric, text, date, text[]),
  public.hesap_delete_expense(text, text, uuid)
to anon, authenticated;
