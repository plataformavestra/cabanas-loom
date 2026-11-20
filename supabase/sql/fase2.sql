-- Cabanas Loom · Fase 2: o site lê datas/preços do painel e envia pedidos de reserva.
-- Rodar no Supabase: SQL Editor > New query > colar tudo > Run.

-- 1) Leituras públicas (só o necessário; nada de notas ou dados pessoais)
drop view if exists public_blocks;
create view public_blocks as
  select cabin_id, start_date, end_date from calendar_blocks;

drop view if exists public_cabins;
create view public_cabins as
  select id, name, capacity, base_price, weekend_price, min_nights, checkin_time, checkout_time from cabins;

drop view if exists public_price_rules;
create view public_price_rules as
  select cabin_id, start_date, end_date, price, min_nights from price_rules;

grant select on public_blocks, public_cabins, public_price_rules to anon, authenticated, service_role;

-- 2) Pedidos de reserva
create table if not exists booking_requests (
  id uuid primary key default gen_random_uuid(),
  cabin_id text not null,
  start_date date not null,
  end_date date not null,          -- dia do check-out
  guests int not null,
  guest_name text not null,
  guest_contact text not null,
  message text,
  status text not null default 'pendente' check (status in ('pendente','aprovada','recusada')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
alter table booking_requests enable row level security;
drop policy if exists "admin le pedidos" on booking_requests;
create policy "admin le pedidos" on booking_requests for select to authenticated using (is_admin());
grant select on booking_requests to authenticated;
grant all on booking_requests to service_role;

-- 3) Hóspede envia pedido (valida tudo no servidor)
create or replace function request_booking(
  p_cabin text, p_start date, p_end date, p_guests int,
  p_name text, p_contact text, p_message text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  c record; n int; v_min int; v_id uuid;
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
  p_name := trim(coalesce(p_name, '')); p_contact := trim(coalesce(p_contact, ''));
  if length(p_name) < 2 or length(p_name) > 80 or length(p_contact) < 5 or length(p_contact) > 120 then
    raise exception 'Confira seu nome e contato.';
  end if;
  p_message := nullif(left(trim(coalesce(p_message, '')), 600), '');

  if exists (select 1 from calendar_blocks b
              where b.cabin_id = p_cabin and b.start_date < p_end and b.end_date > p_start) then
    raise exception 'Essas datas não estão mais disponíveis.';
  end if;
  if (select count(*) from booking_requests where status = 'pendente') >= 40 then
    raise exception 'Estamos com muitos pedidos em análise. Tente novamente mais tarde.';
  end if;
  if (select count(*) from booking_requests
       where guest_contact = p_contact and created_at > now() - interval '1 hour') >= 3 then
    raise exception 'Aguarde um pouco antes de enviar outro pedido.';
  end if;

  insert into booking_requests (cabin_id, start_date, end_date, guests, guest_name, guest_contact, message)
  values (p_cabin, p_start, p_end, p_guests, p_name, p_contact, p_message)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function request_booking(text, date, date, int, text, text, text) from public;
grant execute on function request_booking(text, date, date, int, text, text, text) to anon, authenticated;

-- 4) Você aprova: fecha as datas no painel (e portanto no Airbnb/Booking pelos links)
create or replace function approve_booking(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r booking_requests;
begin
  if not is_admin() then raise exception 'Não autorizado.'; end if;
  select * into r from booking_requests where id = p_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if r.status <> 'pendente' then raise exception 'Este pedido já foi respondido.'; end if;
  if exists (select 1 from calendar_blocks b
              where b.cabin_id = r.cabin_id and b.start_date < r.end_date and b.end_date > r.start_date) then
    raise exception 'Conflito: essas datas já estão ocupadas no calendário.';
  end if;
  insert into calendar_blocks (cabin_id, start_date, end_date, source, note)
  values (r.cabin_id, r.start_date, r.end_date, 'site', 'Reserva do site: ' || r.guest_name);
  update booking_requests set status = 'aprovada', decided_at = now() where id = p_id;
end $$;
revoke all on function approve_booking(uuid) from public;
grant execute on function approve_booking(uuid) to authenticated;

create or replace function decline_booking(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Não autorizado.'; end if;
  update booking_requests set status = 'recusada', decided_at = now()
   where id = p_id and status = 'pendente';
  if not found then raise exception 'Pedido não encontrado ou já respondido.'; end if;
end $$;
revoke all on function decline_booking(uuid) from public;
grant execute on function decline_booking(uuid) to authenticated;
