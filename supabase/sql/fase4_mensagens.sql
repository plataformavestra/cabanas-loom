-- Cabanas Loom · Fase 4: textos dos e-mails automáticos (um por cabana) e WhatsApp do anfitrião.
-- Rodar no Supabase: SQL Editor > New query > colar tudo > Run.

create table if not exists message_templates (
  cabin_id text not null,
  kind text not null check (kind in ('confirmacao', 'checkin')),
  subject text not null default '',
  body text not null default '',
  days_before int not null default 2 check (days_before between 1 and 14),
  updated_at timestamptz not null default now(),
  primary key (cabin_id, kind)
);
alter table message_templates enable row level security;
drop policy if exists "admin gerencia textos" on message_templates;
create policy "admin gerencia textos" on message_templates for all to authenticated
  using (is_admin()) with check (is_admin());
grant select, insert, update on message_templates to authenticated;
grant all on message_templates to service_role;

create table if not exists app_settings (
  key text primary key,
  value text not null default '',
  updated_at timestamptz not null default now()
);
alter table app_settings enable row level security;
drop policy if exists "admin gerencia config" on app_settings;
create policy "admin gerencia config" on app_settings for all to authenticated
  using (is_admin()) with check (is_admin());
grant select, insert, update on app_settings to authenticated;
grant all on app_settings to service_role;

-- Textos iniciais (modelo para você substituir no painel)
insert into message_templates (cabin_id, kind, subject, body, days_before)
select c.id, 'confirmacao',
  'Reserva confirmada: {cabana}, {entrada} a {saida}',
  E'Olá, {nome}!\n\nSeu pagamento foi confirmado e a sua reserva está garantida. Estamos muito felizes em receber você.\n\nResumo da reserva\nCabana: {cabana}\nEntrada: {entrada}, a partir das {checkin_hora}\nSaída: {saida}, até as {checkout_hora}\nHóspedes: {hospedes}\nValor pago: {valor}\n\nAlguns dias antes da sua chegada, enviaremos por e-mail as orientações de check-in e de acesso.\n\nQualquer dúvida, é só chamar no WhatsApp: {whatsapp}\n\nAté breve!\nCabanas Loom · Urubici',
  2
from cabins c
on conflict (cabin_id, kind) do nothing;

insert into message_templates (cabin_id, kind, subject, body, days_before)
select c.id, 'checkin',
  'Orientações de check-in: {cabana}',
  E'Olá, {nome}!\n\nSua chegada na {cabana} é no dia {entrada}, a partir das {checkin_hora}. Seguem as orientações:\n\n[SUBSTITUA ESTE TRECHO pelas suas orientações: como chegar, acesso à cabana, regras da casa, Wi-Fi, etc.]\n\nEm caso de qualquer problema, fale com a gente no WhatsApp: {whatsapp}\n\nBoa viagem!\nCabanas Loom · Urubici',
  2
from cabins c
on conflict (cabin_id, kind) do nothing;

insert into app_settings (key, value) values ('whatsapp_host', '')
on conflict (key) do nothing;
