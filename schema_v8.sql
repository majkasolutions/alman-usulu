-- Payday v8: etkinliği yalnızca katılımcıları (giriş hesabıyla eklenenler) ve oluşturan kişi görür.
-- Liste, detay ve tüm değişiklik fonksiyonları bu kurala uyar; yetkisiz erişimde "etkinlik bulunamadı"
-- denir (etkinliğin varlığı da belli olmaz). Misafirlerin girişi olmadığından etkilenmezler.

create or replace function hesap.can_see(p_event uuid, p_me text)
returns boolean language sql stable set search_path = hesap, public as $$
  select exists (select 1 from hesap.events where id = p_event and created_by = p_me)
      or exists (select 1 from hesap.participants where event_id = p_event and user_email = p_me);
$$;

create or replace function hesap.require_event(p_event uuid, p_me text)
returns void language plpgsql stable set search_path = hesap, public as $$
begin
  if not hesap.can_see(p_event, p_me) then raise exception 'etkinlik bulunamadı'; end if;
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
        'id', ev.id, 'name', ev.name, 'currency', ev.currency, 'created_at', ev.created_at,
        'participant_count', (select count(*) from hesap.participants where event_id = ev.id),
        'expense_count', (select count(*) from hesap.expenses where event_id = ev.id),
        'total', (select coalesce(sum(amount),0) from hesap.expenses where event_id = ev.id and kind = 'expense'),
        'last_at', (select max(created_at) from hesap.expenses where event_id = ev.id))
        order by coalesce((select max(created_at) from hesap.expenses where event_id = ev.id), ev.created_at) desc)
        from hesap.events ev where hesap.can_see(ev.id, me)), '[]'::jsonb)
  );
end $$;

create or replace function public.hesap_event(p_email text, p_pass text, p_event uuid)
returns jsonb language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; j jsonb;
begin
  me := hesap.check_login(p_email, p_pass);
  perform hesap.require_event(p_event, me);
  j := hesap.event_json(p_event);
  if j is null then raise exception 'etkinlik bulunamadı'; end if;
  return j || jsonb_build_object('me', me,
    'users', (select jsonb_agg(jsonb_build_object('email', email, 'name', name, 'token', token, 'full_name', full_name, 'iban', iban) order by sort) from hesap.users));
end $$;

create or replace function public.hesap_rename_event(p_email text, p_pass text, p_event uuid, p_name text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
begin
  perform hesap.require_event(p_event, hesap.check_login(p_email, p_pass));
  update hesap.events set name = trim(p_name) where id = p_event;
end $$;

create or replace function public.hesap_delete_event(p_email text, p_pass text, p_event uuid)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
begin
  perform hesap.require_event(p_event, hesap.check_login(p_email, p_pass));
  delete from hesap.events where id = p_event;
end $$;

create or replace function public.hesap_set_currency(p_email text, p_pass text, p_event uuid, p_currency text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
begin
  perform hesap.require_event(p_event, hesap.check_login(p_email, p_pass));
  if exists (select 1 from hesap.expenses where event_id = p_event and orig_currency is not null)
     and p_currency <> (select currency from hesap.events where id = p_event) then
    raise exception 'Etkinlikte farklı para birimiyle girilmiş kayıtlar var; ana birim değiştirilemez';
  end if;
  update hesap.events set currency = p_currency where id = p_event;
end $$;

create or replace function public.hesap_add_participant(p_email text, p_pass text, p_event uuid, p_name text, p_user_email text)
returns uuid language plpgsql security definer set search_path = hesap, extensions, public as $$
declare pid uuid; n int;
begin
  perform hesap.require_event(p_event, hesap.check_login(p_email, p_pass));
  select count(*) into n from hesap.participants where event_id = p_event;
  if n >= 10 then raise exception 'en fazla 10 katılımcı'; end if;
  insert into hesap.participants(event_id, name, user_email, sort)
    values (p_event, trim(p_name), nullif(p_user_email,''), n + 1) returning id into pid;
  return pid;
end $$;

create or replace function public.hesap_remove_participant(p_email text, p_pass text, p_event uuid, p_participant uuid)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
begin
  perform hesap.require_event(p_event, hesap.check_login(p_email, p_pass));
  if exists (select 1 from hesap.expenses where event_id = p_event
             and (payer_pid = p_participant or shares @> jsonb_build_array(jsonb_build_object('p', p_participant)))) then
    raise exception 'bu kişinin kaydı var, önce onları düzenleyin';
  end if;
  if (select count(*) from hesap.participants where event_id = p_event) <= 1 then
    raise exception 'son katılımcı silinemez';
  end if;
  delete from hesap.participants where id = p_participant and event_id = p_event;
end $$;

-- 14 parametreli sürüm bunu çağırdığı için o da korunur.
create or replace function public.hesap_save_expense(
  p_email text, p_pass text, p_id uuid, p_event uuid, p_kind text, p_payer uuid,
  p_amount numeric, p_description text, p_spent_on date, p_split_mode text, p_shares jsonb)
returns uuid language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; e uuid; n int; total_cents bigint; sum_cents bigint;
begin
  me := hesap.check_login(p_email, p_pass);
  perform hesap.require_event(p_event, me);
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

create or replace function public.hesap_delete_expense(p_email text, p_pass text, p_expense uuid)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; evid uuid;
begin
  me := hesap.check_login(p_email, p_pass);
  select event_id into evid from hesap.expenses where id = p_expense;
  if evid is null or not hesap.can_see(evid, me) then raise exception 'kayıt bulunamadı'; end if;
  delete from hesap.expenses where id = p_expense;
end $$;
