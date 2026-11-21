-- Cabanas Loom · Fase 3: pagamento pelo Asaas.
-- Fluxo: pendente -> (você aprova) aguardando_pagamento (datas ficam seguradas) -> confirmada (pagou)
--                                                                        \-> expirada (não pagou no prazo; datas voltam)
-- Rodar no Supabase: SQL Editor > New query > colar tudo > Run.

-- 1) Campos novos no pedido
alter table booking_requests add column if not exists guest_cpf text;
alter table booking_requests add column if not exists total_price numeric(10,2);
alter table booking_requests add column if not exists payment_id text;
alter table booking_requests add column if not exists payment_url text;
alter table booking_requests add column if not exists expires_at timestamptz;
alter table booking_requests add column if not exists paid_at timestamptz;
alter table booking_requests add column if not exists block_id text;
create index if not exists booking_requests_payment_id_idx on booking_requests (payment_id);

-- 2) Novas situações permitidas
do $$ declare c text; begin
  for c in select conname from pg_constraint
            where conrelid = 'booking_requests'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%status%' loop
    execute format('alter table booking_requests drop constraint %I', c);
  end loop;
end $$;
alter table booking_requests add constraint booking_requests_status_check
  check (status in ('pendente','aprovada','recusada','aguardando_pagamento','confirmada','expirada','cancelada','pago_conflito'));

-- 3) Garante que o calendário aceita reservas vindas do site (remove trava antiga de "source", se existir)
do $$ declare c record; begin
  for c in select conname, pg_get_constraintdef(oid) as d from pg_constraint
            where conrelid = 'calendar_blocks'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%source%' loop
    if c.d not ilike '%''site''%' then
      execute format('alter table calendar_blocks drop constraint %I', c.conname);
    end if;
  end loop;
end $$;

-- 4) CPF válido (dígitos verificadores)
create or replace function cpf_valido(p text) returns boolean
language plpgsql immutable as $$
declare d text; s int; i int; r int;
begin
  d := regexp_replace(coalesce(p, ''), '\D', '', 'g');
  if length(d) <> 11 or d ~ '^(\d)\1{10}$' then return false; end if;
  s := 0; for i in 1..9 loop s := s + substr(d, i, 1)::int * (11 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  if r <> substr(d, 10, 1)::int then return false; end if;
  s := 0; for i in 1..10 loop s := s + substr(d, i, 1)::int * (12 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  return r = substr(d, 11, 1)::int;
end $$;

-- 5) Preço total da estadia (mesma regra do site: regra de período > fim de semana (sex/sáb) > diária base)
create or replace function quote_price(p_cabin text, p_start date, p_end date) returns numeric
language plpgsql stable set search_path = public as $$
declare d date; total numeric := 0; pr numeric; c record;
begin
  select * into c from cabins where id = p_cabin;
  if not found then return null; end if;
  d := p_start;
  while d < p_end loop
    pr := null;
    select r.price into pr from price_rules r
     where r.cabin_id = p_cabin and d between r.start_date and r.end_date
     order by r.start_date desc limit 1;
    if pr is null then
      if extract(dow from d) in (5, 6) and c.weekend_price is not null then pr := c.weekend_price;
      else pr := c.base_price; end if;
    end if;
    if pr is null then return null; end if;
    total := total + pr; d := d + 1;
  end loop;
  return total;
end $$;

-- 6) Pedido do hóspede agora inclui CPF (a função antiga continua até o site novo entrar no ar)
create or replace function request_booking(
  p_cabin text, p_start date, p_end date, p_guests int,
  p_name text, p_email text, p_phone text, p_cpf text, p_message text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  c record; n int; v_min int; v_id uuid; v_phone text; v_cpf text;
begin
  select * into c from cabins where id = p_cabin;
  if not found then raise exception 'Cabana inválida.'; end if;
  if p_start is null or p_end is null or p_start < (now() at time zone 'America/Sao_Paulo')::date then
    raise exception 'Datas inválidas.';
  end if;
  n := p_end - p_start;
  if n < 1 or n > 60 then raise exception 'Período inválido.'; end if;

  select r.min_nights into v_min from price_rules r
   where r.cabin_id = p_cabin and r.min_nights is not null and p_start between r.start_date and r.end_date
   order by r.start_date desc limit 1;
  v_min := coalesce(v_min, c.min_nights, 1);
  if n < v_min then raise exception 'Estadia mínima de % noites neste período.', v_min; end if;

  if p_guests is null or p_guests < 1 or (c.capacity is not null and p_guests > c.capacity) then
    raise exception 'Número de hóspedes inválido.';
  end if;

  p_name := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  p_email := lower(trim(coalesce(p_email, '')));
  v_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_cpf := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  if length(p_name) < 2 or length(p_name) > 80 then raise exception 'Confira seu nome.'; end if;
  if length(p_email) > 120 or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' then
    raise exception 'Confira seu e-mail.';
  end if;
  if length(v_phone) not in (10, 11) or left(v_phone, 1) = '0' then
    raise exception 'Confira seu WhatsApp (com DDD).';
  end if;
  if not cpf_valido(v_cpf) then raise exception 'Confira seu CPF.'; end if;
  p_message := nullif(left(trim(coalesce(p_message, '')), 600), '');

  if exists (select 1 from calendar_blocks b
              where b.cabin_id = p_cabin and b.start_date < p_end and b.end_date > p_start) then
    raise exception 'Essas datas não estão mais disponíveis.';
  end if;
  if (select count(*) from booking_requests where status = 'pendente') >= 40 then
    raise exception 'Estamos com muitos pedidos em análise. Tente novamente mais tarde.';
  end if;
  if (select count(*) from booking_requests
       where (guest_email = p_email or guest_phone = v_phone) and created_at > now() - interval '1 hour') >= 3 then
    raise exception 'Aguarde um pouco antes de enviar outro pedido.';
  end if;

  insert into booking_requests (cabin_id, start_date, end_date, guests, guest_name, guest_contact,
                                guest_email, guest_phone, guest_cpf, total_price, message)
  values (p_cabin, p_start, p_end, p_guests, p_name, p_email, p_email, v_phone, v_cpf,
          quote_price(p_cabin, p_start, p_end), p_message)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function request_booking(text, date, date, int, text, text, text, text, text) from public;
grant execute on function request_booking(text, date, date, int, text, text, text, text, text) to anon, authenticated;

-- 7) Você aprova: segura as datas e marca "aguardando pagamento" (só a função de aprovação chama isto)
create or replace function hold_booking(p_id uuid, p_valor numeric, p_hours int) returns void
language plpgsql security definer set search_path = public as $$
declare r booking_requests; v_block text;
begin
  select * into r from booking_requests where id = p_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if r.status <> 'pendente' then raise exception 'Este pedido já foi respondido.'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Informe o valor da reserva.'; end if;
  if r.guest_cpf is null then raise exception 'Este pedido não tem CPF. Recuse e peça um novo pedido.'; end if;
  if exists (select 1 from calendar_blocks b
              where b.cabin_id = r.cabin_id and b.start_date < r.end_date and b.end_date > r.start_date) then
    raise exception 'Conflito: essas datas já estão ocupadas no calendário.';
  end if;
  insert into calendar_blocks (cabin_id, start_date, end_date, source, note)
  values (r.cabin_id, r.start_date, r.end_date, 'site', 'Reserva do site: ' || r.guest_name)
  returning id::text into v_block;
  update booking_requests
     set status = 'aguardando_pagamento', decided_at = now(), total_price = p_valor,
         expires_at = now() + make_interval(hours => greatest(1, least(coalesce(p_hours, 24), 72))),
         block_id = v_block
   where id = p_id;
end $$;
revoke all on function hold_booking(uuid, numeric, int) from public, anon, authenticated;
grant execute on function hold_booking(uuid, numeric, int) to service_role;

-- 8) Libera as datas e muda a situação (usado por falha, expiração e cancelamento)
create or replace function release_booking(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare r booking_requests;
begin
  select * into r from booking_requests where id = p_id for update;
  if not found then return; end if;
  if r.block_id is not null then delete from calendar_blocks where id::text = r.block_id; end if;
  update booking_requests
     set status = p_status, block_id = null,
         expires_at = case when p_status = 'pendente' then null else expires_at end,
         payment_id = case when p_status = 'pendente' then null else payment_id end,
         payment_url = case when p_status = 'pendente' then null else payment_url end
   where id = p_id;
end $$;
revoke all on function release_booking(uuid, text) from public, anon, authenticated;
grant execute on function release_booking(uuid, text) to service_role;

-- 9) Você cancela (aguardando pagamento ou já confirmada)
create or replace function cancel_booking(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r booking_requests;
begin
  if not is_admin() then raise exception 'Não autorizado.'; end if;
  select * into r from booking_requests where id = p_id for update;
  if not found or r.status not in ('aguardando_pagamento', 'confirmada') then
    raise exception 'Pedido não encontrado ou não pode ser cancelado.';
  end if;
  perform release_booking(p_id, 'cancelada');
end $$;
revoke all on function cancel_booking(uuid) from public, anon;
grant execute on function cancel_booking(uuid) to authenticated;

-- 10) O Asaas avisou que pagou (só a função do webhook chama isto)
create or replace function confirm_payment(p_payment_id text, p_value numeric) returns text
language plpgsql security definer set search_path = public as $$
declare r booking_requests; v_block text;
begin
  select * into r from booking_requests where payment_id = p_payment_id for update;
  if not found then return 'desconhecido'; end if;
  if r.status = 'confirmada' then return 'ja_confirmada'; end if;
  if p_value is not null and r.total_price is not null and p_value < r.total_price then
    return 'valor_menor';
  end if;
  if r.status = 'aguardando_pagamento' then
    update booking_requests set status = 'confirmada', paid_at = now() where id = r.id;
    return 'confirmada';
  end if;
  -- pagou depois de expirar: se as datas ainda estão livres, reabre a reserva; senão, avisa você
  if r.status = 'expirada'
     and not exists (select 1 from calendar_blocks b
                      where b.cabin_id = r.cabin_id and b.start_date < r.end_date and b.end_date > r.start_date) then
    insert into calendar_blocks (cabin_id, start_date, end_date, source, note)
    values (r.cabin_id, r.start_date, r.end_date, 'site', 'Reserva do site: ' || r.guest_name)
    returning id::text into v_block;
    update booking_requests set status = 'confirmada', paid_at = now(), block_id = v_block where id = r.id;
    return 'confirmada_apos_expirar';
  end if;
  update booking_requests set status = 'pago_conflito', paid_at = now() where id = r.id;
  return 'conflito';
end $$;
revoke all on function confirm_payment(text, numeric) from public, anon, authenticated;
grant execute on function confirm_payment(text, numeric) to service_role;

-- 11) Expira pedidos não pagos no prazo (roda a cada 10 minutos)
create or replace function expire_unpaid() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select id from booking_requests where status = 'aguardando_pagamento' and expires_at < now() loop
    perform release_booking(r.id, 'expirada'); n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function expire_unpaid() from public, anon, authenticated;
grant execute on function expire_unpaid() to service_role;

select cron.schedule('expirar-reservas-nao-pagas', '*/10 * * * *', $c$select public.expire_unpaid()$c$);

-- 12) A aprovação antiga (sem pagamento) sai de cena
drop function if exists approve_booking(uuid);
