-- Cabanas Loom · Fase 9: fechamentos enviados para o DRE e DREs mensais (rascunho e fixo).
-- Rodar no Supabase: SQL Editor > New query > colar tudo > Run.

create table if not exists closings (
  id uuid primary key default gen_random_uuid(),
  period_start date not null,
  period_end date not null check (period_end >= period_start),
  data jsonb not null,
  dre_month date,
  created_at timestamptz not null default now()
);
create index if not exists closings_period_idx on closings (period_start);

create table if not exists dre_reports (
  month date primary key check (extract(day from month) = 1),
  status text not null default 'rascunho' check (status in ('rascunho', 'fixo')),
  data jsonb not null,
  updated_at timestamptz not null default now(),
  fixed_at timestamptz
);

alter table closings enable row level security;
alter table dre_reports enable row level security;
drop policy if exists "admin gerencia fechamentos" on closings;
create policy "admin gerencia fechamentos" on closings for all to authenticated using (is_admin()) with check (is_admin());
drop policy if exists "admin gerencia dre" on dre_reports;
create policy "admin gerencia dre" on dre_reports for all to authenticated using (is_admin()) with check (is_admin());
grant select, insert, update, delete on closings to authenticated;
grant select, insert, update, delete on dre_reports to authenticated;
grant all on closings to service_role;
grant all on dre_reports to service_role;
