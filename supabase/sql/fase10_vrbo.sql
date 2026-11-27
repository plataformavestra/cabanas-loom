-- Fase 10: Vrbo na sincronização de calendários
-- 1) o calendário aceita datas vindas do Vrbo
alter table calendar_blocks drop constraint if exists calendar_blocks_source_check;
alter table calendar_blocks add constraint calendar_blocks_source_check
  check (source in ('manual', 'reserva', 'airbnb', 'booking', 'vrbo', 'site')) not valid;

-- 2) se as tabelas de sincronização limitam as plataformas, passa a aceitar 'vrbo'
do $$
declare r record;
begin
  for r in select conrelid::regclass::text as tbl, conname from pg_constraint
           where contype = 'c' and conrelid in ('ical_sources'::regclass, 'ical_feeds'::regclass)
             and pg_get_constraintdef(oid) ilike '%platform%'
  loop
    execute format('alter table %s drop constraint %I', r.tbl, r.conname);
    execute format('alter table %s add constraint %I check (platform in (''airbnb'', ''booking'', ''vrbo''))', r.tbl, r.conname);
  end loop;
end $$;

-- 3) linhas de entrada (link do Vrbo -> site), uma por cabana, ainda sem link
insert into ical_sources (cabin_id, platform)
select c.id, 'vrbo' from cabins c
where not exists (select 1 from ical_sources s where s.cabin_id = c.id and s.platform = 'vrbo');

-- 4) links de saída (site -> Vrbo), uma por cabana, com chave secreta
insert into ical_feeds (cabin_id, platform, token)
select c.id, 'vrbo', replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
from cabins c
where not exists (select 1 from ical_feeds f where f.cabin_id = c.id and f.platform = 'vrbo');

-- conferência
select 'entrada' as tipo, cabin_id, platform from ical_sources where platform = 'vrbo'
union all
select 'saida', cabin_id, platform from ical_feeds where platform = 'vrbo';
