-- Alman Usulü v2: etkinlikler (birden çok defter), katılımcılar (en fazla 10,
-- giriş hesabına bağlı ya da misafir), eşit olmayan bölüşme, kayıt düzenleme.
-- Mevcut kayıtlar "Genel" etkinliğine taşınır, veri kaybı yok.

-- ---------------------------------------------------------------- yeni tablolar
create table if not exists hesap.events (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(name) between 1 and 60),
  created_by  text not null references hesap.users(email),
  created_at  timestamptz not null default now()
);

create table if not exists hesap.participants (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references hesap.events(id) on delete cascade,
  name        text not null check (length(name) between 1 and 40),
  user_email  text references hesap.users(email),
  sort        int not null default 0,
  created_at  timestamptz not null default now(),
  unique (event_id, name)
);
create unique index if not exists participants_event_user_idx on hesap.participants(event_id, user_email) where user_email is not null;

alter table hesap.events       enable row level security;
alter table hesap.participants enable row level security;
revoke all on all tables in schema hesap from anon, authenticated;

-- expenses: yeni kolonlar
alter table hesap.expenses
  add column if not exists event_id   uuid references hesap.events(id) on delete cascade,
  add column if not exists payer_pid  uuid references hesap.participants(id),
  add column if not exists split_mode text not null default 'equal' check (split_mode in ('equal','amount','shares')),
  add column if not exists shares     jsonb not null default '[]'::jsonb,   -- [{"p":uuid,"amount":12.34,"w":1}]
  add column if not exists updated_at timestamptz;

-- ---------------------------------------------------------------- mevcut veriyi taşı
do $$
declare ev uuid; e record; n int; base numeric; rest int; i int; sh jsonb; pid uuid; amt numeric;
begin
  if exists (select 1 from hesap.expenses where event_id is null) or not exists (select 1 from hesap.events) then
    insert into hesap.events(name, created_by)
      values ('Genel', (select email from hesap.users order by sort limit 1)) returning id into ev;
    insert into hesap.participants(event_id, name, user_email, sort)
      select ev, name, email, sort from hesap.users order by sort;

    for e in select * from hesap.expenses where event_id is null loop
      n := cardinality(e.split);
      base := floor(e.amount * 100 / n) / 100;
      rest := round(e.amount * 100) - round(base * 100) * n;
      sh := '[]'::jsonb;
      for i in 1..n loop
        select id into pid from hesap.participants where event_id = ev and user_email = e.split[i];
        amt := base + (case when rest > 0 then 0.01 else 0 end);
        if rest > 0 then rest := rest - 1; end if;
        sh := sh || jsonb_build_object('p', pid, 'amount', amt, 'w', 1);
      end loop;
      update hesap.expenses set
        event_id  = ev,
        payer_pid = (select id from hesap.participants where event_id = ev and user_email = e.payer),
        split_mode = 'equal',
        shares = sh
      where id = e.id;
    end loop;
  end if;
end $$;

alter table hesap.expenses alter column event_id set not null;
alter table hesap.expenses alter column payer_pid set not null;
alter table hesap.expenses drop column if exists payer;
alter table hesap.expenses drop column if exists split;
create index if not exists expenses_event_idx on hesap.expenses(event_id, spent_on desc, created_at desc);

-- ---------------------------------------------------------------- eski API'yi kaldır
drop function if exists public.hesap_add_expense(text, text, text, text, numeric, text, date, text[]);
drop function if exists public.hesap_delete_expense(text, text, uuid);
drop function if exists public.hesap_get(text, text);

-- ---------------------------------------------------------------- yardımcılar
create or replace function hesap.event_json(p_event uuid)
returns jsonb language sql stable set search_path = hesap, public as $$
  select jsonb_build_object(
    'id', ev.id, 'name', ev.name, 'created_by', ev.created_by, 'created_at', ev.created_at,
    'participants', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'email', user_email) order by sort, created_at)
                              from hesap.participants where event_id = ev.id), '[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'kind', kind, 'payer', payer_pid, 'amount', amount, 'description', description,
        'spent_on', spent_on, 'split_mode', split_mode, 'shares', shares,
        'created_by', created_by, 'created_at', created_at, 'updated_at', updated_at)
        order by spent_on desc, created_at desc) from hesap.expenses where event_id = ev.id), '[]'::jsonb)
  ) from hesap.events ev where ev.id = p_event;
$$;

-- ---------------------------------------------------------------- API
create or replace function public.hesap_get(p_email text, p_pass text)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text;
begin
  me := hesap.check_login(p_email, p_pass);
  return jsonb_build_object(
    'me', me,
    'users', (select jsonb_agg(jsonb_build_object('email', email, 'name', name) order by sort) from hesap.users),
    'events', coalesce((select jsonb_agg(jsonb_build_object(
        'id', ev.id, 'name', ev.name, 'created_at', ev.created_at,
        'participant_count', (select count(*) from hesap.participants where event_id = ev.id),
        'expense_count', (select count(*) from hesap.expenses where event_id = ev.id),
        'total', (select coalesce(sum(amount),0) from hesap.expenses where event_id = ev.id and kind = 'expense'),
        'last_at', (select max(created_at) from hesap.expenses where event_id = ev.id))
        order by coalesce((select max(created_at) from hesap.expenses where event_id = ev.id), ev.created_at) desc)
        from hesap.events ev), '[]'::jsonb)
  );
end $$;

create or replace function public.hesap_event(p_email text, p_pass text, p_event uuid)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; j jsonb;
begin
  me := hesap.check_login(p_email, p_pass);
  j := hesap.event_json(p_event);
  if j is null then raise exception 'etkinlik bulunamadı'; end if;
  return j || jsonb_build_object('me', me);
end $$;

-- p_participants: [{"name":"Fehim","email":"fehim@gmail.com"},{"name":"Ali"}]
create or replace function public.hesap_create_event(p_email text, p_pass text, p_name text, p_participants jsonb)
returns uuid language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; ev uuid; it jsonb; i int := 0;
begin
  me := hesap.check_login(p_email, p_pass);
  if jsonb_array_length(coalesce(p_participants, '[]'::jsonb)) < 1 then raise exception 'en az bir katılımcı gerekli'; end if;
  if jsonb_array_length(p_participants) > 10 then raise exception 'en fazla 10 katılımcı'; end if;
  insert into hesap.events(name, created_by) values (trim(p_name), me) returning id into ev;
  for it in select * from jsonb_array_elements(p_participants) loop
    i := i + 1;
    insert into hesap.participants(event_id, name, user_email, sort)
      values (ev, trim(it->>'name'), nullif(it->>'email',''), i);
  end loop;
  return ev;
end $$;

create or replace function public.hesap_rename_event(p_email text, p_pass text, p_event uuid, p_name text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
begin
  perform hesap.check_login(p_email, p_pass);
  update hesap.events set name = trim(p_name) where id = p_event;
end $$;

create or replace function public.hesap_delete_event(p_email text, p_pass text, p_event uuid)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
begin
  perform hesap.check_login(p_email, p_pass);
  delete from hesap.events where id = p_event;
end $$;

create or replace function public.hesap_add_participant(p_email text, p_pass text, p_event uuid, p_name text, p_user_email text)
returns uuid language plpgsql security definer set search_path = hesap, extensions, public as $$
declare pid uuid; n int;
begin
  perform hesap.check_login(p_email, p_pass);
  select count(*) into n from hesap.participants where event_id = p_event;
  if n >= 10 then raise exception 'en fazla 10 katılımcı'; end if;
  insert into hesap.participants(event_id, name, user_email, sort)
    values (p_event, trim(p_name), nullif(p_user_email,''), n + 1) returning id into pid;
  return pid;
end $$;

create or replace function public.hesap_remove_participant(p_email text, p_pass text, p_event uuid, p_participant uuid)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
begin
  perform hesap.check_login(p_email, p_pass);
  if exists (select 1 from hesap.expenses where event_id = p_event
             and (payer_pid = p_participant or shares @> jsonb_build_array(jsonb_build_object('p', p_participant)))) then
    raise exception 'bu kişinin kaydı var, önce onları düzenleyin';
  end if;
  if (select count(*) from hesap.participants where event_id = p_event) <= 1 then
    raise exception 'son katılımcı silinemez';
  end if;
  delete from hesap.participants where id = p_participant and event_id = p_event;
end $$;

-- p_id null → yeni kayıt; dolu → güncelle.  p_shares: [{"p":uuid,"amount":12.34,"w":1}]
create or replace function public.hesap_save_expense(
  p_email text, p_pass text, p_id uuid, p_event uuid, p_kind text, p_payer uuid,
  p_amount numeric, p_description text, p_spent_on date, p_split_mode text, p_shares jsonb)
returns uuid language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; e uuid; n int; total_cents bigint; sum_cents bigint;
begin
  me := hesap.check_login(p_email, p_pass);
  if not exists (select 1 from hesap.participants where id = p_payer and event_id = p_event) then
    raise exception 'ödeyen bu etkinlikte değil';
  end if;
  n := jsonb_array_length(coalesce(p_shares, '[]'::jsonb));
  if n = 0 then raise exception 'en az bir kişi seçin'; end if;
  if (select count(distinct s->>'p') from jsonb_array_elements(p_shares) s
      join hesap.participants pt on pt.id = (s->>'p')::uuid and pt.event_id = p_event) <> n then
    raise exception 'paylaşım listesi hatalı';
  end if;
  total_cents := round(p_amount * 100);
  select sum(round((s->>'amount')::numeric * 100)) into sum_cents from jsonb_array_elements(p_shares) s;
  if sum_cents <> total_cents then raise exception 'paylar toplamı tutara eşit değil'; end if;
  if exists (select 1 from jsonb_array_elements(p_shares) s where (s->>'amount')::numeric < 0) then
    raise exception 'pay eksi olamaz';
  end if;
  if p_kind = 'payment' and (n <> 1 or (p_shares->0->>'p')::uuid = p_payer) then
    raise exception 'ödeme başka bir kişiye yapılır';
  end if;

  if p_id is null then
    insert into hesap.expenses(event_id, kind, payer_pid, amount, description, spent_on, split_mode, shares, created_by)
    values (p_event, coalesce(p_kind,'expense'), p_payer, round(p_amount,2), trim(p_description),
            coalesce(p_spent_on, current_date), coalesce(p_split_mode,'equal'), p_shares, me)
    returning id into e;
  else
    update hesap.expenses set
      kind = coalesce(p_kind,'expense'), payer_pid = p_payer, amount = round(p_amount,2),
      description = trim(p_description), spent_on = coalesce(p_spent_on, current_date),
      split_mode = coalesce(p_split_mode,'equal'), shares = p_shares, updated_at = now()
    where id = p_id and event_id = p_event returning id into e;
    if e is null then raise exception 'kayıt bulunamadı'; end if;
  end if;
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
  public.hesap_event(text, text, uuid),
  public.hesap_create_event(text, text, text, jsonb),
  public.hesap_rename_event(text, text, uuid, text),
  public.hesap_delete_event(text, text, uuid),
  public.hesap_add_participant(text, text, uuid, text, text),
  public.hesap_remove_participant(text, text, uuid, uuid),
  public.hesap_save_expense(text, text, uuid, uuid, text, uuid, numeric, text, date, text, jsonb),
  public.hesap_delete_expense(text, text, uuid)
to anon, authenticated;
