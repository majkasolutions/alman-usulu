-- Payday v12: e-posta değişince (ON UPDATE CASCADE) arkadaşlıklardaki a < b sırası bozulmasın.
-- (Bu sürümde canlıda yapılan gerçek adres düzeltmeleri kişisel veri olduğu için repoda değil: data-fixes.local.sql)
create or replace function hesap.friendships_norm()
returns trigger language plpgsql as $$
declare t text;
begin
  if new.a > new.b then t := new.a; new.a := new.b; new.b := t; end if;
  return new;
end $$;
create or replace trigger friendships_norm before insert or update on hesap.friendships
  for each row execute function hesap.friendships_norm();
