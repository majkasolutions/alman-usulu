-- Payday v14: yetkiler, geri alınabilir silme, değişiklik geçmişi, ödemede alıcı onayı.
--
-- Yetki: kaydı yalnızca ekleyen ya da etkinlik sahibi düzenler/siler/geri alır. Etkinliği silmek,
-- para birimini değiştirmek ve başkasını çıkarmak yalnızca sahipte; herkes kendisi ayrılabilir.
-- Silme: kayıt silinmez, deleted_at ile gizlenir; "Silinenler" listesinden geri alınır.
-- Geçmiş: hesap.activity (etkinlik başına son 50 satır uygulamada gösterilir).
-- Ödeme onayı: ödemeyi alan kişi (hesabı varsa) "Aldım" der; tutar/kişi değişirse onay düşer.
-- Bakiye hesabı değişmez: onay bekleyen ödeme de bakiyeye sayılır, yalnızca rozetle gösterilir.

-- ---------------------------------------------------------------- tablolar
alter table hesap.expenses
  add column if not exists deleted_at   timestamptz,
  add column if not exists deleted_by   text references hesap.users(email) on update cascade,
  add column if not exists confirmed_at timestamptz,
  add column if not exists confirmed_by text references hesap.users(email) on update cascade;

create table if not exists hesap.activity (
  id         bigint generated always as identity primary key,
  event_id   uuid not null references hesap.events(id) on delete cascade,
  actor      text references hesap.users(email) on update cascade,
  actor_name text,
  action     text not null check (action in ('add', 'edit', 'delete', 'restore', 'confirm', 'unconfirm',
                                              'member_add', 'member_remove', 'currency', 'rename')),
  expense_id uuid,
  detail     text,
  amount     numeric,
  created_at timestamptz not null default now()
);
create index if not exists activity_event_idx on hesap.activity(event_id, created_at desc);
alter table hesap.activity enable row level security;
revoke all on all tables in schema hesap from anon, authenticated;

-- ---------------------------------------------------------------- yardımcılar
create or replace function hesap.log(p_event uuid, p_me text, p_action text, p_expense uuid, p_detail text, p_amount numeric)
returns void language sql security definer set search_path = hesap, public as $$
  insert into hesap.activity(event_id, actor, actor_name, action, expense_id, detail, amount)
  values (p_event, p_me, (select name from hesap.users where email = p_me), p_action, p_expense, left(p_detail, 120), p_amount);
$$;

create or replace function hesap.is_owner(p_event uuid, p_me text)
returns boolean language sql stable set search_path = hesap, public as $$
  select exists (select 1 from hesap.events where id = p_event and created_by = p_me);
$$;

create or replace function hesap.can_edit_expense(p_expense uuid, p_me text)
returns boolean language sql stable set search_path = hesap, public as $$
  select exists (select 1 from hesap.expenses x join hesap.events ev on ev.id = x.event_id
                  where x.id = p_expense and (x.created_by = p_me or ev.created_by = p_me));
$$;

-- ---------------------------------------------------------------- etkinlik verisi
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
        'created_by', created_by, 'created_at', created_at, 'updated_by', updated_by, 'updated_at', updated_at,
        'confirmed_at', confirmed_at, 'confirmed_by', confirmed_by)
        order by spent_on desc, created_at desc) from hesap.expenses where event_id = ev.id and deleted_at is null), '[]'::jsonb),
    'deleted', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'kind', kind, 'amount', amount, 'description', description, 'spent_on', spent_on,
        'orig_currency', orig_currency, 'orig_amount', orig_amount,
        'created_by', created_by, 'deleted_by', deleted_by, 'deleted_at', deleted_at)
        order by deleted_at desc) from hesap.expenses where event_id = ev.id and deleted_at is not null), '[]'::jsonb),
    'activity', coalesce((select jsonb_agg(jsonb_build_object(
        'action', a.action, 'actor', a.actor, 'actor_name', a.actor_name, 'detail', a.detail,
        'amount', a.amount, 'at', a.created_at) order by a.created_at desc)
        from (select * from hesap.activity where event_id = ev.id order by created_at desc limit 50) a), '[]'::jsonb)
  ) from hesap.events ev where ev.id = p_event;
$$;

-- ana sayfa özetleri silinmiş kayıtları saymaz
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
        'expense_count', (select count(*) from hesap.expenses where event_id = ev.id and deleted_at is null),
        'total', (select coalesce(sum(amount),0) from hesap.expenses where event_id = ev.id and kind = 'expense' and deleted_at is null),
        'last_at', (select max(created_at) from hesap.expenses where event_id = ev.id and deleted_at is null))
        order by coalesce((select max(created_at) from hesap.expenses where event_id = ev.id and deleted_at is null), ev.created_at) desc)
        from hesap.events ev where hesap.can_see(ev.id, me)), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------- kayıtlar
create or replace function public.hesap_save_expense(p_email text, p_pass text, p_id uuid, p_event uuid, p_kind text, p_payer uuid,
  p_amount numeric, p_description text, p_spent_on date, p_split_mode text, p_shares jsonb,
  p_orig_currency text, p_orig_amount numeric, p_fx_rate numeric)
returns uuid language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; e uuid; evcur text; foreign_ boolean; old hesap.expenses%rowtype;
begin
  me := hesap.check_login(p_email, p_pass);
  if p_id is not null then
    select * into old from hesap.expenses where id = p_id and event_id = p_event and deleted_at is null;
    if old.id is null then raise exception 'kayıt bulunamadı'; end if;
    if not hesap.can_edit_expense(p_id, me) then
      raise exception 'Bu kaydı yalnızca ekleyen kişi ya da etkinlik sahibi düzenleyebilir';
    end if;
  end if;
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
  -- ödemenin tutarı ya da kişileri değiştiyse alıcı onayı düşer
  if old.id is not null and old.confirmed_at is not null and
     (old.kind <> coalesce(p_kind, 'expense') or old.amount <> round(p_amount, 2) or old.payer_pid <> p_payer
      or old.shares->0->>'p' is distinct from p_shares->0->>'p') then
    update hesap.expenses set confirmed_at = null, confirmed_by = null where id = e;
  end if;
  perform hesap.log(p_event, me, case when p_id is null then 'add' else 'edit' end, e, trim(p_description), round(p_amount, 2));
  return e;
end $$;

create or replace function public.hesap_delete_expense(p_email text, p_pass text, p_expense uuid)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; x hesap.expenses%rowtype;
begin
  me := hesap.check_login(p_email, p_pass);
  select * into x from hesap.expenses where id = p_expense and deleted_at is null;
  if x.id is null or not hesap.can_see(x.event_id, me) then raise exception 'kayıt bulunamadı'; end if;
  if not hesap.can_edit_expense(p_expense, me) then
    raise exception 'Bu kaydı yalnızca ekleyen kişi ya da etkinlik sahibi silebilir';
  end if;
  update hesap.expenses set deleted_at = now(), deleted_by = me where id = p_expense;
  perform hesap.log(x.event_id, me, 'delete', x.id, x.description, x.amount);
end $$;

create or replace function public.hesap_restore_expense(p_email text, p_pass text, p_expense uuid)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; x hesap.expenses%rowtype;
begin
  me := hesap.check_login(p_email, p_pass);
  select * into x from hesap.expenses where id = p_expense and deleted_at is not null;
  if x.id is null or not hesap.can_see(x.event_id, me) then raise exception 'kayıt bulunamadı'; end if;
  if not hesap.can_edit_expense(p_expense, me) then
    raise exception 'Bu kaydı yalnızca ekleyen kişi ya da etkinlik sahibi geri alabilir';
  end if;
  if exists (select 1 from (select x.payer_pid as p union select (s->>'p')::uuid from jsonb_array_elements(x.shares) s) q
              where not exists (select 1 from hesap.participants pt where pt.id = q.p and pt.event_id = x.event_id)) then
    raise exception 'Bu kayıttaki kişilerden biri etkinlikte değil';
  end if;
  update hesap.expenses set deleted_at = null, deleted_by = null where id = p_expense;
  perform hesap.log(x.event_id, me, 'restore', x.id, x.description, x.amount);
end $$;

-- ödemeyi alan kişi "aldım" der (ya da geri çeker)
create or replace function public.hesap_confirm_payment(p_email text, p_pass text, p_expense uuid, p_ok boolean)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; x hesap.expenses%rowtype;
begin
  me := hesap.check_login(p_email, p_pass);
  select * into x from hesap.expenses where id = p_expense and deleted_at is null and kind = 'payment';
  if x.id is null or not hesap.can_see(x.event_id, me) then raise exception 'kayıt bulunamadı'; end if;
  if not exists (select 1 from hesap.participants where id = (x.shares->0->>'p')::uuid and user_email = me) then
    raise exception 'Bu ödemeyi yalnızca alan kişi onaylayabilir';
  end if;
  update hesap.expenses set confirmed_at = case when p_ok then now() end, confirmed_by = case when p_ok then me end
   where id = p_expense;
  perform hesap.log(x.event_id, me, case when p_ok then 'confirm' else 'unconfirm' end, x.id, x.description, x.amount);
end $$;

-- ---------------------------------------------------------------- etkinlik (sahip yetkileri)
create or replace function public.hesap_delete_event(p_email text, p_pass text, p_event uuid)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text;
begin
  me := hesap.check_login(p_email, p_pass);
  perform hesap.require_event(p_event, me);
  if not hesap.is_owner(p_event, me) then raise exception 'Etkinliği yalnızca oluşturan kişi silebilir'; end if;
  delete from hesap.events where id = p_event;
end $$;

create or replace function public.hesap_set_currency(p_email text, p_pass text, p_event uuid, p_currency text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text;
begin
  me := hesap.check_login(p_email, p_pass);
  perform hesap.require_event(p_event, me);
  if not hesap.is_owner(p_event, me) then raise exception 'Para birimini yalnızca etkinliği oluşturan kişi değiştirebilir'; end if;
  if p_currency = (select currency from hesap.events where id = p_event) then return; end if;
  if exists (select 1 from hesap.expenses where event_id = p_event and orig_currency is not null) then
    raise exception 'Etkinlikte farklı para birimiyle girilmiş kayıtlar var; ana birim değiştirilemez';
  end if;
  update hesap.events set currency = p_currency where id = p_event;
  perform hesap.log(p_event, me, 'currency', null, p_currency, null);
end $$;

create or replace function public.hesap_rename_event(p_email text, p_pass text, p_event uuid, p_name text)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text;
begin
  me := hesap.check_login(p_email, p_pass);
  perform hesap.require_event(p_event, me);
  update hesap.events set name = trim(p_name) where id = p_event;
  perform hesap.log(p_event, me, 'rename', null, trim(p_name), null);
end $$;

-- sahip herkesi çıkarabilir; diğerleri yalnızca kendini (ayrılma) ya da kendi gönderdiği daveti
create or replace function public.hesap_remove_participant(p_email text, p_pass text, p_event uuid, p_participant uuid)
returns void language plpgsql security definer set search_path = hesap, extensions, public as $$
declare me text; pt hesap.participants%rowtype;
begin
  me := hesap.check_login(p_email, p_pass);
  perform hesap.require_event(p_event, me);
  select * into pt from hesap.participants where id = p_participant and event_id = p_event;
  if pt.id is null then raise exception 'kişi bulunamadı'; end if;
  if not hesap.is_owner(p_event, me) and pt.user_email is distinct from me
     and not (pt.status = 'invited' and pt.invited_by = me) then
    raise exception 'Başkasını yalnızca etkinliği oluşturan kişi çıkarabilir';
  end if;
  if exists (select 1 from hesap.expenses where event_id = p_event and deleted_at is null
             and (payer_pid = p_participant or shares @> jsonb_build_array(jsonb_build_object('p', p_participant)))) then
    raise exception 'bu kişinin kaydı var, önce onları düzenleyin';
  end if;
  if exists (select 1 from hesap.expenses where event_id = p_event
             and (payer_pid = p_participant or shares @> jsonb_build_array(jsonb_build_object('p', p_participant)))) then
    raise exception 'bu kişi silinmiş kayıtlarda geçiyor; çıkarılamaz';
  end if;
  if (select count(*) from hesap.participants where event_id = p_event) <= 1 then
    raise exception 'son katılımcı silinemez';
  end if;
  delete from hesap.participants where id = p_participant and event_id = p_event;
  perform hesap.log(p_event, me, 'member_remove', null, pt.name, null);
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
  perform hesap.log(p_event, me, 'member_add', null, trim(p_name), null);
  return pid;
end $$;

-- ---------------------------------------------------------------- yetkiler
grant execute on function
  public.hesap_restore_expense(text, text, uuid),
  public.hesap_confirm_payment(text, text, uuid, boolean)
to anon, authenticated;
revoke execute on function hesap.log(uuid, text, text, uuid, text, numeric) from public, anon, authenticated;
