-- Cabanas Loom · Fase 7b: reservas lançadas à mão no calendário (tipo "reserva"), separadas dos bloqueios sem hóspede.
-- Rodar no Supabase: SQL Editor > New query > colar tudo > Run.

-- 1) Aceitar o novo tipo "reserva" (remove uma eventual trava antiga de tipos e cria a nova)
do $$ declare r record; begin
  for r in select conname from pg_constraint
           where conrelid = 'public.calendar_blocks'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) ilike '%source%' loop
    execute format('alter table public.calendar_blocks drop constraint %I', r.conname);
  end loop;
end $$;
alter table calendar_blocks add constraint calendar_blocks_source_check
  check (source in ('manual', 'reserva', 'airbnb', 'booking', 'site')) not valid;

-- 2) Permitir que o painel edite os lançamentos seus (datas, tipo reserva <-> bloqueio e observação)
grant update on calendar_blocks to authenticated;
drop policy if exists "admin altera bloqueios" on calendar_blocks;
create policy "admin altera bloqueios" on calendar_blocks for update to authenticated
  using (is_admin() and source in ('manual', 'reserva'))
  with check (is_admin() and source in ('manual', 'reserva'));
