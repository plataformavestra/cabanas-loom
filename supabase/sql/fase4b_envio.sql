-- Cabanas Loom · Fase 4b: envio automático dos e-mails (confirmação e orientações de check-in).
-- Rodar no Supabase: SQL Editor > New query > colar tudo > Run.

-- 1) Controle do que já foi enviado (evita e-mail em duplicidade)
alter table booking_requests add column if not exists email_confirmacao_at timestamptz;
alter table booking_requests add column if not exists email_checkin_at timestamptz;
alter table booking_requests add column if not exists aviso_host_at timestamptz;

-- Reservas já confirmadas antes desta fase não recebem e-mail retroativo
update booking_requests
   set email_confirmacao_at = coalesce(email_confirmacao_at, now()),
       email_checkin_at     = coalesce(email_checkin_at, now()),
       aviso_host_at        = coalesce(aviso_host_at, now())
 where status = 'confirmada';

-- 2) Configurações: e-mail que recebe o aviso de nova reserva e senha interna do agendador
insert into app_settings (key, value) values ('notify_email', 'loomurubici@gmail.com')
  on conflict (key) do nothing;
insert into app_settings (key, value) values ('cron_token', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
  on conflict (key) do nothing;

-- 3) Agendador: chama a função "enviar-emails" a cada 5 minutos
create extension if not exists pg_net;

do $$ begin
  perform cron.unschedule('enviar-emails-reservas');
exception when others then null;
end $$;

select cron.schedule(
  'enviar-emails-reservas',
  '*/5 * * * *',
  $c$
  select net.http_post(
    url := 'https://voveeogibxytqladwiqr.supabase.co/functions/v1/enviar-emails',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-token', (select value from public.app_settings where key = 'cron_token')
    ),
    body := '{}'::jsonb
  );
  $c$
);
