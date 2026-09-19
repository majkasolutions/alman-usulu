-- Alman Usulü v3: yarış piyonu (kişiye bağlı amblem) + kaydı kimin düzenlediği.

alter table hesap.users    add column if not exists token text;
alter table hesap.expenses add column if not exists updated_by text references hesap.users(email);

create or replace function public.hesap_set_token(p_email text, p_pass text, p_token text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text;
begin
  me := hesap.check_login(p_email, p_pass);
  if length(p_token) > 8 then raise exception 'geçersiz piyon'; end if;
  update hesap.users set token = nullif(p_token, '') where email = me;
end $$;

-- users listesine token, kayıtlara updated_by eklendi
create or replace function hesap.event_json(p_event uuid)
returns jsonb language sql stable set search_path = hesap, public as $$
  select jsonb_build_object(
    'id', ev.id, 'name', ev.name, 'created_by', ev.created_by, 'created_at', ev.created_at,
    'participants', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'email', user_email) order by sort, created_at)
                              from hesap.participants where event_id = ev.id), '[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'kind', kind, 'payer', payer_pid, 'amount', amount, 'description', description,
        'spent_on', spent_on, 'split_mode', split_mode, 'shares', shares,
        'created_by', created_by, 'created_at', created_at, 'updated_by', updated_by, 'updated_at', updated_at)
        order by spent_on desc, created_at desc) from hesap.expenses where event_id = ev.id), '[]'::jsonb)
  ) from hesap.events ev where ev.id = p_event;
$$;

create or replace function public.hesap_get(p_email text, p_pass text)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text;
begin
  me := hesap.check_login(p_email, p_pass);
  return jsonb_build_object(
    'me', me,
    'users', (select jsonb_agg(jsonb_build_object('email', email, 'name', name, 'token', token) order by sort) from hesap.users),
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
    'users', (select jsonb_agg(jsonb_build_object('email', email, 'name', name, 'token', token) order by sort) from hesap.users));
end $$;

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
      split_mode = coalesce(p_split_mode,'equal'), shares = p_shares, updated_at = now(), updated_by = me
    where id = p_id and event_id = p_event returning id into e;
    if e is null then raise exception 'kayıt bulunamadı'; end if;
  end if;
  return e;
end $$;

grant execute on function public.hesap_set_token(text, text, text) to anon, authenticated;
