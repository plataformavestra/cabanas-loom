// @ts-nocheck
// Gera o calendário iCal de cada cabana para o Airbnb/Booking importarem.
// URL: .../functions/v1/ical-export?cabin=loom1&platform=airbnb&token=CHAVE
// Nunca devolve à plataforma as datas que vieram dela mesma (evita eco/duplicidade).
// Esta função precisa estar com "Verify JWT" DESLIGADO (as plataformas não fazem login).
import { createClient } from 'npm:@supabase/supabase-js@2';

Deno.serve(async (req) => {
  const u = new URL(req.url);
  const cabin = u.searchParams.get('cabin') || '';
  const platform = u.searchParams.get('platform') || '';
  const token = u.searchParams.get('token') || '';
  const nf = () => new Response('Not found', { status: 404 });
  if (!cabin || !platform || !token) return nf();

  const admin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
  const { data: feed } = await admin.from('ical_feeds').select('token')
    .eq('cabin_id', cabin).eq('platform', platform).maybeSingle();
  if (!feed || feed.token !== token) return nf();

  const corte = new Date(Date.now() - 7 * 86400000).toISOString().slice(0, 10);
  const { data: blocks, error } = await admin.from('calendar_blocks')
    .select('id,start_date,end_date').eq('cabin_id', cabin).neq('source', platform).gte('end_date', corte)
    .order('start_date');
  if (error) return new Response('Erro', { status: 500 });

  const d8 = (s) => s.replace(/-/g, '');
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+/, '');
  const out = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Cabanas Loom//Calendario//PT', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
    'X-WR-CALNAME:Cabanas Loom'];
  for (const b of blocks) {
    out.push('BEGIN:VEVENT', `UID:${b.id}@cabanasloom.com.br`, `DTSTAMP:${stamp}`,
      `DTSTART;VALUE=DATE:${d8(b.start_date)}`, `DTEND;VALUE=DATE:${d8(b.end_date)}`, 'SUMMARY:Reservado', 'END:VEVENT');
  }
  out.push('END:VCALENDAR');
  return new Response(out.join('\r\n') + '\r\n', {
    headers: { 'Content-Type': 'text/calendar; charset=utf-8', 'Cache-Control': 'no-store' },
  });
});
