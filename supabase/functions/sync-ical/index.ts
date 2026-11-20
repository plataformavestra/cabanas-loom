// @ts-nocheck
// Lê os calendários iCal do Airbnb/Booking e grava as datas ocupadas em calendar_blocks.
// Roda a cada 2 minutos (pg_cron) e também pelo botão "Sincronizar agora" do painel.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// ---- parser iCal (JS puro, testado fora do Deno) ----
function parseIcs(txt) {
  const lines = txt.replace(/\r\n/g, '\n').replace(/\n[ \t]/g, '').split('\n');
  const events = [];
  let cur = null;
  for (const raw of lines) {
    const line = raw.trim();
    if (line === 'BEGIN:VEVENT') { cur = {}; continue; }
    if (line === 'END:VEVENT') {
      if (cur && cur.start && cur.status !== 'CANCELLED') {
        const end = cur.end && cur.end > cur.start ? cur.end : addDay(cur.start);
        events.push({ start: cur.start, end });
      }
      cur = null; continue;
    }
    if (!cur) continue;
    const i = line.indexOf(':');
    if (i < 0) continue;
    const name = line.slice(0, i).split(';')[0].toUpperCase();
    const val = line.slice(i + 1).trim();
    if (name === 'DTSTART') cur.start = ymd(val);
    else if (name === 'DTEND') cur.end = ymd(val);
    else if (name === 'STATUS') cur.status = val.toUpperCase();
  }
  return events;
}
function ymd(v) {
  const m = /^(\d{4})(\d{2})(\d{2})/.exec(v);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : null;
}
function addDay(s) {
  const d = new Date(s + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}
// ---- fim do parser ----

Deno.serve(async (req) => {
  const T0 = Date.now();
  const lg = (m) => console.log('[sync] +' + (Date.now() - T0) + 'ms ' + m);
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const json = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });

  lg('inicio ' + req.method);
  const url = Deno.env.get('SUPABASE_URL');
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
  let body = {};
  try { body = await req.json(); } catch (_) { /* corpo vazio */ }

  // "force" (botão do painel) exige usuário administrador logado
  const force = body && body.force === true;
  if (force) {
    const userClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY'), {
      global: { headers: { Authorization: req.headers.get('Authorization') || '' } },
    });
    const { data: u } = await userClient.auth.getUser();
    if (!u || !u.user) return json({ error: 'não autorizado' }, 401);
    const { data: ok } = await userClient.rpc('is_admin');
    if (ok !== true) return json({ error: 'não autorizado' }, 403);
  }

  lg('lendo ical_sources');
  const { data: sources, error } = await admin.from('ical_sources').select('*').not('url', 'is', null);
  if (error) return json({ error: error.message }, 500);

  lg('fontes: ' + (sources ? sources.length : 'nenhuma'));
  const hoje = new Date().toISOString().slice(0, 10);
  const corte = new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10);
  const resumo = [];

  for (const s of sources) {
    if (!s.url || !s.url.trim()) continue;
    // sem "force", não repete a mesma fonte em menos de 55 segundos
    if (!force && s.last_sync_at && Date.now() - new Date(s.last_sync_at).getTime() < 55000) continue;
    lg('fonte ' + s.cabin_id + '/' + s.platform + ': buscando link');
    try {
      const ctl = new AbortController();
      const t = setTimeout(() => ctl.abort(), 15000);
      const r = await fetch(s.url.trim(), { signal: ctl.signal, headers: { 'User-Agent': 'CabanasLoom-Sync/1.0' } });
      clearTimeout(t);
      lg('fonte ' + s.cabin_id + '/' + s.platform + ': resposta HTTP ' + r.status);
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const txt = await r.text();
      lg('fonte ' + s.cabin_id + '/' + s.platform + ': texto lido, ' + txt.length + ' caracteres');
      if (!txt.includes('BEGIN:VCALENDAR')) throw new Error('resposta não é um calendário iCal');

      const events = parseIcs(txt).filter((e) => e.end >= corte);
      lg('fonte ' + s.cabin_id + '/' + s.platform + ': ' + events.length + ' eventos');
      const novos = new Map(events.map((e) => [e.start + '|' + e.end, e]));

      const { data: atuais, error: e2 } = await admin.from('calendar_blocks')
        .select('id,start_date,end_date').eq('cabin_id', s.cabin_id).eq('source', s.platform).gte('end_date', corte);
      if (e2) throw new Error(e2.message);

      lg('banco: ' + atuais.length + ' bloqueios atuais');
      const existentes = new Set(atuais.map((b) => b.start_date + '|' + b.end_date));
      const remover = atuais.filter((b) => !novos.has(b.start_date + '|' + b.end_date)).map((b) => b.id);
      const inserir = [...novos.entries()].filter(([k]) => !existentes.has(k))
        .map(([, e]) => ({ cabin_id: s.cabin_id, start_date: e.start, end_date: e.end, source: s.platform, note: null }));

      if (remover.length) {
        const { error: e3 } = await admin.from('calendar_blocks').delete().in('id', remover);
        if (e3) throw new Error(e3.message);
      }
      if (inserir.length) {
        const { error: e4 } = await admin.from('calendar_blocks').insert(inserir);
        if (e4) throw new Error(e4.message);
      }
      lg('gravando status ok');
      await admin.from('ical_sources').update({
        last_sync_at: new Date().toISOString(), last_status: 'ok', last_error: null, last_count: events.length,
      }).eq('id', s.id);
      resumo.push({ cabin: s.cabin_id, platform: s.platform, ok: true, eventos: events.length, novos: inserir.length, removidos: remover.length });
    } catch (err) {
      lg('ERRO: ' + String(err.message || err));
      await admin.from('ical_sources').update({
        last_sync_at: new Date().toISOString(), last_status: 'erro', last_error: String(err.message || err).slice(0, 300),
      }).eq('id', s.id);
      resumo.push({ cabin: s.cabin_id, platform: s.platform, ok: false, erro: String(err.message || err) });
    }
  }
  lg('fim');
  return json({ ok: true, hoje, resumo });
});
