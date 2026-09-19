-- Alman Usulü v4: isteğe bağlı IBAN (girilirse ad soyad zorunlu), herkes görebilir.

alter table hesap.users
  add column if not exists full_name text,
  add column if not exists iban text;

create or replace function hesap.iban_ok(p text) returns boolean language plpgsql immutable as $$
declare s text; n text; c char; i int;
begin
  if p !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$' then return false; end if;
  if left(p, 2) = 'TR' and length(p) <> 26 then return false; end if;
  s := substr(p, 5) || left(p, 4);
  n := '';
  for i in 1..length(s) loop
    c := substr(s, i, 1);
    n := n || (case when c between '0' and '9' then c else (ascii(c) - 55)::text end);
  end loop;
  -- mod 97, parça parça
  declare r int := 0; j int;
  begin
    for j in 1..length(n) loop r := (r * 10 + substr(n, j, 1)::int) % 97; end loop;
    return r = 1;
  end;
end $$;

create or replace function public.hesap_set_bank(p_email text, p_pass text, p_full_name text, p_iban text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; ib text; fn text;
begin
  me := hesap.check_login(p_email, p_pass);
  ib := upper(regexp_replace(coalesce(p_iban, ''), '\s', '', 'g'));
  fn := trim(coalesce(p_full_name, ''));
  if ib <> '' then
    if fn = '' or fn !~ '\S+\s+\S+' then raise exception 'IBAN girerken ad soyad zorunlu'; end if;
    if not hesap.iban_ok(ib) then raise exception 'IBAN geçersiz'; end if;
  end if;
  update hesap.users set full_name = nullif(fn, ''), iban = nullif(ib, '') where email = me;
end $$;

create or replace function public.hesap_get(p_email text, p_pass text)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text;
begin
  me := hesap.check_login(p_email, p_pass);
  return jsonb_build_object(
    'me', me,
    'users', (select jsonb_agg(jsonb_build_object('email', email, 'name', name, 'token', token, 'full_name', full_name, 'iban', iban) order by sort) from hesap.users),
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
  return j || jsonb_build_object('me', me,
    'users', (select jsonb_agg(jsonb_build_object('email', email, 'name', name, 'token', token, 'full_name', full_name, 'iban', iban) order by sort) from hesap.users));
end $$;

grant execute on function public.hesap_set_bank(text, text, text, text) to anon, authenticated;
