-- Payday v6: etkinlik başına para birimi (TL, USD, EUR, DKK, SEK, NOK).
-- Mevcut etkinlikler TRY olarak kalır; kayıt tutarları etkinliğin para biriminde tutulur.

alter table hesap.events
  add column if not exists currency text not null default 'TRY';
alter table hesap.events drop constraint if exists events_currency_check;
alter table hesap.events add constraint events_currency_check
  check (currency in ('TRY', 'USD', 'EUR', 'DKK', 'SEK', 'NOK'));

create or replace function hesap.event_json(p_event uuid)
returns jsonb language sql stable set search_path = hesap, public as $$
  select jsonb_build_object(
    'id', ev.id, 'name', ev.name, 'currency', ev.currency, 'created_by', ev.created_by, 'created_at', ev.created_at,
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
    'users', (select jsonb_agg(jsonb_build_object('email', email, 'name', name, 'token', token, 'full_name', full_name, 'iban', iban) order by sort) from hesap.users),
    'events', coalesce((select jsonb_agg(jsonb_build_object(
        'id', ev.id, 'name', ev.name, 'currency', ev.currency, 'created_at', ev.created_at,
        'participant_count', (select count(*) from hesap.participants where event_id = ev.id),
        'expense_count', (select count(*) from hesap.expenses where event_id = ev.id),
        'total', (select coalesce(sum(amount),0) from hesap.expenses where event_id = ev.id and kind = 'expense'),
        'last_at', (select max(created_at) from hesap.expenses where event_id = ev.id))
        order by coalesce((select max(created_at) from hesap.expenses where event_id = ev.id), ev.created_at) desc)
        from hesap.events ev), '[]'::jsonb)
  );
end $$;

-- Eski 4 parametreli hesap_create_event yerinde kalır (eski arayüz çalışmaya devam eder);
-- p_currency alan sürüm onu çağırıp birimi ayarlar. Geçersiz birim kısıtlamaya takılır, etkinlik de oluşmaz.
create or replace function public.hesap_create_event(p_email text, p_pass text, p_name text, p_participants jsonb, p_currency text)
returns uuid language plpgsql security definer set search_path = hesap, extensions, public as $$
declare ev uuid;
begin
  ev := public.hesap_create_event(p_email, p_pass, p_name, p_participants);
  update hesap.events set currency = coalesce(nullif(p_currency, ''), 'TRY') where id = ev;
  return ev;
end $$;

-- Para birimini değiştirmek tutarları çevirmez; sadece birimi düzeltir.
create or replace function public.hesap_set_currency(p_email text, p_pass text, p_event uuid, p_currency text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
begin
  perform hesap.check_login(p_email, p_pass);
  update hesap.events set currency = p_currency where id = p_event;
end $$;

grant execute on function
  public.hesap_create_event(text, text, text, jsonb, text),
  public.hesap_set_currency(text, text, uuid, text)
to anon, authenticated;
