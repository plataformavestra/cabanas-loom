-- Cabanas Loom · Fase 8: temporadas com preço de dia de semana e de sexta/sábado/feriado,
-- períodos sobrepostos (o mais curto vence) e lista de feriados.
-- Rodar no Supabase: SQL Editor > New query > colar tudo > Run.

-- 1) Período ganha a diária de sexta, sábado e feriado (opcional) e a data de criação (desempate)
alter table price_rules add column if not exists weekend_price numeric(10,2);
alter table price_rules add column if not exists created_at timestamptz not null default now();

-- 2) Feriados (você pode acrescentar/remover pelo painel)
create table if not exists holidays (
  day date primary key,
  name text not null check (length(name) between 1 and 80)
);
alter table holidays enable row level security;
drop policy if exists "admin gerencia feriados" on holidays;
create policy "admin gerencia feriados" on holidays for all to authenticated using (is_admin()) with check (is_admin());
grant select, insert, update, delete on holidays to authenticated;
grant all on holidays to service_role;

insert into holidays (day, name) values
  ('2026-12-25','Natal'),
  ('2027-01-01','Confraternização Universal'),('2027-02-08','Carnaval'),('2027-02-09','Carnaval'),
  ('2027-03-26','Sexta-feira Santa'),('2027-04-21','Tiradentes'),('2027-05-01','Dia do Trabalho'),
  ('2027-05-27','Corpus Christi'),('2027-09-07','Independência'),('2027-10-12','Nossa Senhora Aparecida'),
  ('2027-11-02','Finados'),('2027-11-15','Proclamação da República'),('2027-11-20','Consciência Negra'),
  ('2027-12-25','Natal'),
  ('2028-01-01','Confraternização Universal'),('2028-02-28','Carnaval'),('2028-02-29','Carnaval'),
  ('2028-04-14','Sexta-feira Santa'),('2028-04-21','Tiradentes'),('2028-05-01','Dia do Trabalho'),
  ('2028-06-15','Corpus Christi'),('2028-09-07','Independência'),('2028-10-12','Nossa Senhora Aparecida'),
  ('2028-11-02','Finados'),('2028-11-15','Proclamação da República'),('2028-11-20','Consciência Negra'),
  ('2028-12-25','Natal')
on conflict (day) do nothing;

-- Em qual noite vale o preço de feriado: 'dia' (noite do feriado), 'vespera' (noite anterior) ou 'ambos'
insert into app_settings (key, value) values ('feriado_regra', 'ambos') on conflict (key) do nothing;

-- Noites que recebem o preço de feriado (o site lê esta lista)
create or replace view public_holiday_nights as
  select distinct n.night
  from (
    select h.day as night from holidays h
     where coalesce((select value from app_settings where key = 'feriado_regra'), 'ambos') in ('dia', 'ambos')
    union all
    select h.day - 1 from holidays h
     where coalesce((select value from app_settings where key = 'feriado_regra'), 'ambos') in ('vespera', 'ambos')
  ) n;
grant select on public_holiday_nights to anon, authenticated, service_role;

-- 3) O site passa a receber a diária de fim de semana do período e a data de criação
drop view if exists public_price_rules;
create view public_price_rules as
  select cabin_id, start_date, end_date, price, weekend_price, min_nights, created_at from price_rules;
grant select on public_price_rules to anon, authenticated, service_role;

-- 4) Cálculo do preço de cada noite:
--    período mais curto que cobre a noite vence (empate: o cadastrado por último);
--    sexta, sábado e noites de feriado usam a diária de fim de semana do período (ou da cabana).
create or replace function quote_price(p_cabin text, p_start date, p_end date) returns numeric
language plpgsql stable set search_path = public as $$
declare d date; total numeric := 0; pr numeric; c record; r record; alta boolean;
begin
  select * into c from cabins where id = p_cabin;
  if not found then return null; end if;
  d := p_start;
  while d < p_end loop
    pr := null;
    alta := extract(dow from d) in (5, 6) or exists (select 1 from public_holiday_nights h where h.night = d);
    select x.price, x.weekend_price into r from price_rules x
     where x.cabin_id = p_cabin and d between x.start_date and x.end_date
     order by (x.end_date - x.start_date) asc, x.created_at desc limit 1;
    if found then
      pr := case when alta and r.weekend_price is not null then r.weekend_price else r.price end;
    else
      pr := case when alta and c.weekend_price is not null then c.weekend_price else c.base_price end;
    end if;
    if pr is null then return null; end if;
    total := total + pr; d := d + 1;
  end loop;
  return total;
end $$;
