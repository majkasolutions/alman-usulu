-- Payday v7: aynı etkinlikte farklı para birimleriyle kayıt (Tricount / Settle Up usulü).
-- amount ve shares[].amount her zaman etkinliğin para biriminde kalır (bakiye/ödeşme hesabı değişmez).
-- Kayıt başka birimde girildiyse girilen tutar, birimi ve kuru (1 orig = fx_rate etkinlik birimi) saklanır.
-- Tutara göre bölüşmede kişinin girilen birimdeki payı shares[].o alanında tutulur.

alter table hesap.expenses
  add column if not exists orig_currency text,
  add column if not exists orig_amount numeric(12,2),
  add column if not exists fx_rate numeric(18,8);
alter table hesap.expenses drop constraint if exists expenses_orig_check;
alter table hesap.expenses add constraint expenses_orig_check check (
  (orig_currency is null and orig_amount is null and fx_rate is null) or
  (orig_currency in ('TRY', 'USD', 'EUR', 'DKK', 'SEK', 'NOK') and orig_amount > 0 and fx_rate > 0));

create or replace function hesap.event_json(p_event uuid)
returns jsonb language sql stable set search_path = hesap, public as $$
  select jsonb_build_object(
    'id', ev.id, 'name', ev.name, 'currency', ev.currency, 'created_by', ev.created_by, 'created_at', ev.created_at,
    'participants', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'email', user_email) order by sort, created_at)
                              from hesap.participants where event_id = ev.id), '[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'kind', kind, 'payer', payer_pid, 'amount', amount, 'description', description,
        'spent_on', spent_on, 'split_mode', split_mode, 'shares', shares,
        'orig_currency', orig_currency, 'orig_amount', orig_amount, 'fx_rate', fx_rate,
        'created_by', created_by, 'created_at', created_at, 'updated_by', updated_by, 'updated_at', updated_at)
        order by spent_on desc, created_at desc) from hesap.expenses where event_id = ev.id), '[]'::jsonb)
  ) from hesap.events ev where ev.id = p_event;
$$;

-- Eski 11 parametreli hesap_save_expense yerinde kalır; bu sürüm onu çağırıp birim bilgisini yazar.
-- p_orig_currency boş ya da etkinliğin birimiyse birim bilgisi temizlenir.
create or replace function public.hesap_save_expense(
  p_email text, p_pass text, p_id uuid, p_event uuid, p_kind text, p_payer uuid,
  p_amount numeric, p_description text, p_spent_on date, p_split_mode text, p_shares jsonb,
  p_orig_currency text, p_orig_amount numeric, p_fx_rate numeric)
returns uuid language plpgsql security definer set search_path = hesap, extensions, public as $$
declare e uuid; evcur text; foreign_ boolean;
begin
  select currency into evcur from hesap.events where id = p_event;
  foreign_ := coalesce(nullif(p_orig_currency, ''), evcur) <> evcur;
  if foreign_ and (coalesce(p_orig_amount, 0) <= 0 or coalesce(p_fx_rate, 0) <= 0) then
    raise exception 'kur ve tutar gerekli';
  end if;
  e := public.hesap_save_expense(p_email, p_pass, p_id, p_event, p_kind, p_payer,
         p_amount, p_description, p_spent_on, p_split_mode, p_shares);
  update hesap.expenses set
    orig_currency = case when foreign_ then p_orig_currency end,
    orig_amount   = case when foreign_ then round(p_orig_amount, 2) end,
    fx_rate       = case when foreign_ then p_fx_rate end
  where id = e;
  return e;
end $$;

-- Başka birimde kayıt varken etkinliğin birimi değiştirilemez (kurlar anlamını yitirir).
create or replace function public.hesap_set_currency(p_email text, p_pass text, p_event uuid, p_currency text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
begin
  perform hesap.check_login(p_email, p_pass);
  if exists (select 1 from hesap.expenses where event_id = p_event and orig_currency is not null)
     and p_currency <> (select currency from hesap.events where id = p_event) then
    raise exception 'Etkinlikte farklı para birimiyle girilmiş kayıtlar var; ana birim değiştirilemez';
  end if;
  update hesap.events set currency = p_currency where id = p_event;
end $$;

grant execute on function
  public.hesap_save_expense(text, text, uuid, uuid, text, uuid, numeric, text, date, text, jsonb, text, numeric, numeric)
to anon, authenticated;
