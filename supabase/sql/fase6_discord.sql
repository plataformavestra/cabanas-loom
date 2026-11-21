-- Cabanas Loom · Fase 6: avisos no Discord (controle do que já foi avisado) e agendador a cada minuto.
-- Rodar no Supabase: SQL Editor > New query > colar tudo > Run.

alter table booking_requests add column if not exists discord_novo_at timestamptz;
alter table booking_requests add column if not exists discord_pago_at timestamptz;
alter table booking_requests add column if not exists discord_cancel_at timestamptz;
alter table booking_requests add column if not exists discord_conflito_at timestamptz;

-- O que já aconteceu antes de ligar os avisos não gera aviso retroativo
update booking_requests set discord_novo_at = coalesce(discord_novo_at, now()) where status = 'pendente';
update booking_requests set discord_pago_at = coalesce(discord_pago_at, now()) where status = 'confirmada';
update booking_requests set discord_cancel_at = coalesce(discord_cancel_at, now()) where status = 'cancelada';
update booking_requests set discord_conflito_at = coalesce(discord_conflito_at, now()) where status = 'pago_conflito';

-- Agendador: agora a cada minuto (era a cada 5), para o aviso chegar rápido
select cron.unschedule('enviar-emails-reservas');

select cron.schedule(
  'enviar-emails-reservas',
  '* * * * *',
  $c$
  select net.http_post(
    url := 'https://voveeogibxytqladwiqr.supabase.co/functions/v1/hyper-endpoint',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-token', (select value from public.app_settings where key = 'cron_token')
    ),
    body := '{}'::jsonb
  );
  $c$
);
