-- Cabanas Loom · Fase 7: controle de estoque (botijões de gás e taças extras).
-- Rodar no Supabase: SQL Editor > New query > colar tudo > Run.

-- Botijões: cada registro muda a situação de um botijão (1 ou 2) de uma cabana.
--   em_uso = entrou em uso naquela data | vazio = acabou naquela data | cheio = recarregado (com custo)
--   ajuste = true quando é só correção/situação inicial (não conta como "acabou" de verdade nas estatísticas)
create table if not exists gas_events (
  id uuid primary key default gen_random_uuid(),
  cabin_id text not null references cabins(id) on delete cascade,
  bottle smallint not null check (bottle in (1, 2)),
  kind text not null check (kind in ('em_uso', 'vazio', 'cheio')),
  event_date date not null,
  cost numeric(10,2) check (cost is null or (cost >= 0 and cost < 100000)),
  ajuste boolean not null default false,
  grupo uuid,
  note text check (note is null or length(note) <= 300),
  created_at timestamptz not null default now()
);
create index if not exists gas_events_cabin_idx on gas_events (cabin_id, event_date, created_at);

-- Taças extras: cada registro soma ou subtrai do estoque da cabana.
create table if not exists glass_events (
  id uuid primary key default gen_random_uuid(),
  cabin_id text not null references cabins(id) on delete cascade,
  kind text not null check (kind in ('quebra', 'compra', 'ajuste')),
  delta int not null check (delta between -50 and 50),
  event_date date not null,
  cost numeric(10,2) check (cost is null or (cost >= 0 and cost < 100000)),
  note text check (note is null or length(note) <= 300),
  created_at timestamptz not null default now()
);
create index if not exists glass_events_cabin_idx on glass_events (cabin_id, event_date, created_at);

alter table gas_events enable row level security;
alter table glass_events enable row level security;
drop policy if exists "admin gerencia gas" on gas_events;
create policy "admin gerencia gas" on gas_events for all to authenticated using (is_admin()) with check (is_admin());
drop policy if exists "admin gerencia tacas" on glass_events;
create policy "admin gerencia tacas" on glass_events for all to authenticated using (is_admin()) with check (is_admin());
grant select, insert, update, delete on gas_events to authenticated;
grant select, insert, update, delete on glass_events to authenticated;
grant all on gas_events to service_role;
grant all on glass_events to service_role;

-- Estoque inicial de taças: 2 extras por cabana (só se ainda não houver nenhum registro)
insert into glass_events (cabin_id, kind, delta, event_date, note)
select c.id, 'ajuste', 2, (now() at time zone 'America/Sao_Paulo')::date, 'Estoque inicial'
from cabins c
where not exists (select 1 from glass_events g where g.cabin_id = c.id);
