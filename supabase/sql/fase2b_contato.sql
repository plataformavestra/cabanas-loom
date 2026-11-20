-- Cabanas Loom · Fase 2b: e-mail e WhatsApp obrigatórios no pedido de reserva.
-- Rodar no Supabase: SQL Editor > New query > colar tudo > Run.

alter table booking_requests add column if not exists guest_email text;
alter table booking_requests add column if not exists guest_phone text;

drop function if exists request_booking(text, date, date, int, text, text, text);

create or replace function request_booking(
  p_cabin text, p_start date, p_end date, p_guests int,
  p_name text, p_email text, p_phone text, p_message text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  c record; n int; v_min int; v_id uuid; v_phone text;
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
  if length(p_name) < 2 or length(p_name) > 80 then raise exception 'Confira seu nome.'; end if;
  if length(p_email) > 120 or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' then
    raise exception 'Confira seu e-mail.';
  end if;
  if length(v_phone) not in (10, 11) or left(v_phone, 1) = '0' then
    raise exception 'Confira seu WhatsApp (com DDD).';
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
       where (guest_email = p_email or guest_phone = v_phone) and created_at > now() - interval '1 hour') >= 3 then
    raise exception 'Aguarde um pouco antes de enviar outro pedido.';
  end if;

  insert into booking_requests (cabin_id, start_date, end_date, guests, guest_name, guest_contact, guest_email, guest_phone, message)
  values (p_cabin, p_start, p_end, p_guests, p_name, p_email, p_email, v_phone, p_message)
  returning id into v_id;
  return v_id;
end $$;

revoke all on function request_booking(text, date, date, int, text, text, text, text) from public;
grant execute on function request_booking(text, date, date, int, text, text, text, text) to anon, authenticated;
