// @ts-nocheck
// Envia os e-mails automáticos das reservas (via Resend). Roda a cada 5 minutos, chamada pelo agendador do banco.
//  1) Reserva confirmada (depois do pagamento): e-mail ao hóspede + aviso para você.
//  2) Orientações de check-in: alguns dias antes da chegada (você escolhe quantos, por cabana, no painel).
// Em Edge Functions: desligar "Verify JWT" (a segurança é a senha interna "x-cron-token").
// Segredo necessário: RESEND_API_KEY.
import { createClient } from 'npm:@supabase/supabase-js@2';

const json = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { 'Content-Type': 'application/json' } });
const FROM = 'Cabanas Loom <reservas@cabanasloom.com.br>';
const REPLY_TO = 'loomurubici@gmail.com';

const br = (d) => String(d).split('-').reverse().join('/');
const money = (v) => Number(v).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
const hhmm = (v, pad) => (v ? String(v).slice(0, 5) : pad);
const fone = (d) => {
  d = String(d || '').replace(/\D/g, '');
  if (d.length === 11) return '(' + d.slice(0, 2) + ') ' + d.slice(2, 7) + '-' + d.slice(7);
  if (d.length === 10) return '(' + d.slice(0, 2) + ') ' + d.slice(2, 6) + '-' + d.slice(6);
  return d;
};
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const preencher = (t, v) => String(t).replace(/\{(\w+)\}/g, (m, k) => (k in v ? v[k] : m));

// data e hora de hoje em Brasília
function agoraBR() {
  const p = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', hourCycle: 'h23' })
    .formatToParts(new Date()).reduce((a, x) => { a[x.type] = x.value; return a; }, {});
  return { hoje: p.year + '-' + p.month + '-' + p.day, hora: parseInt(p.hour, 10) };
}
function somaDias(iso, n) {
  const d = new Date(iso + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10);
}
function noites(a, b) { return Math.round((new Date(b + 'T12:00:00Z') - new Date(a + 'T12:00:00Z')) / 86400000); }

function variaveis(r, cab, whats) {
  const nome = String(r.guest_name || '').trim();
  return {
    nome: nome.split(/\s+/)[0] || 'hóspede',
    nome_completo: nome,
    cabana: cab ? cab.name : '',
    entrada: br(r.start_date),
    saida: br(r.end_date),
    noites: String(noites(r.start_date, r.end_date)),
    hospedes: String(r.guests),
    valor: r.total_price != null ? money(r.total_price) : '',
    checkin_hora: hhmm(cab && cab.checkin_time, '15:00'),
    checkout_hora: hhmm(cab && cab.checkout_time, '11:00'),
    whatsapp: whats ? fone(whats) : '',
  };
}

function html(corpo) {
  return '<div style="font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:1.55;color:#2b2b2b;max-width:560px;margin:0 auto;padding:8px">'
    + esc(corpo).replace(/\r?\n/g, '<br>') + '</div>';
}

async function enviar(para, assunto, texto, chave) {
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + (Deno.env.get('RESEND_API_KEY') || ''),
      'Content-Type': 'application/json',
      'User-Agent': 'CabanasLoom',
      'Idempotency-Key': chave,
    },
    body: JSON.stringify({ from: FROM, to: [para], reply_to: REPLY_TO, subject: assunto, text: texto, html: html(texto) }),
  });
  if (!r.ok) {
    let m = ''; try { m = JSON.stringify(await r.json()); } catch (_) { /* sem corpo */ }
    throw new Error('Resend HTTP ' + r.status + ' ' + m);
  }
}

function igual(a, b) {
  if (!a || !b || a.length !== b.length) return false;
  let x = 0; for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: true });
  const admin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));

  const { data: cfgRows } = await admin.from('app_settings').select('key,value');
  const cfg = {}; (cfgRows || []).forEach((x) => { cfg[x.key] = x.value; });
  if (!igual(req.headers.get('x-cron-token') || '', cfg.cron_token || '')) return json({ error: 'não autorizado' }, 401);
  if (!Deno.env.get('RESEND_API_KEY')) return json({ error: 'RESEND_API_KEY ausente' }, 500);

  const resumo = { confirmacao: 0, aviso: 0, checkin: 0, pulados: [], erros: [] };
  const { data: cabs } = await admin.from('cabins').select('id,name,checkin_time,checkout_time');
  const cab = (id) => (cabs || []).find((c) => c.id === id);
  const { data: tpls } = await admin.from('message_templates').select('*');
  const tpl = (cabinId, kind) => (tpls || []).find((t) => t.cabin_id === cabinId && t.kind === kind);

  // ---------- 1) Confirmação + aviso para você ----------
  const { data: pend } = await admin.from('booking_requests').select('*')
    .eq('status', 'confirmada').not('paid_at', 'is', null)
    .or('email_confirmacao_at.is.null,aviso_host_at.is.null').limit(20);

  for (const r of pend || []) {
    const c = cab(r.cabin_id);
    const v = variaveis(r, c, cfg.whatsapp_host);

    if (!r.email_confirmacao_at) {
      const t = tpl(r.cabin_id, 'confirmacao');
      if (!r.guest_email) { resumo.pulados.push(r.id + ': sem e-mail do hóspede'); }
      else if (!t || !String(t.body || '').trim()) { resumo.pulados.push(r.id + ': sem texto de confirmação'); }
      else {
        // "reserva" o envio antes de enviar, para duas execuções ao mesmo tempo não duplicarem
        const { data: claim } = await admin.from('booking_requests')
          .update({ email_confirmacao_at: new Date().toISOString() }).eq('id', r.id).is('email_confirmacao_at', null).select('id');
        if (claim && claim.length) {
          try {
            await enviar(r.guest_email, preencher(t.subject, v), preencher(t.body, v), 'conf-' + r.id);
            resumo.confirmacao++;
          } catch (e) {
            await admin.from('booking_requests').update({ email_confirmacao_at: null }).eq('id', r.id);
            resumo.erros.push('confirmacao ' + r.id + ': ' + String(e.message || e));
          }
        }
      }
    }

    if (!r.aviso_host_at && cfg.notify_email) {
      const { data: claim } = await admin.from('booking_requests')
        .update({ aviso_host_at: new Date().toISOString() }).eq('id', r.id).is('aviso_host_at', null).select('id');
      if (claim && claim.length) {
        const txt = 'Nova reserva confirmada e paga.\n\n'
          + 'Cabana: ' + v.cabana + '\nHóspede: ' + v.nome_completo + '\nEntrada: ' + v.entrada + '\nSaída: ' + v.saida
          + ' (' + v.noites + ' noites)\nHóspedes: ' + v.hospedes + (v.valor ? '\nValor: ' + v.valor : '')
          + '\nTelefone: ' + (r.guest_phone ? fone(r.guest_phone) : '-') + '\nE-mail: ' + (r.guest_email || '-')
          + (r.message ? '\nMensagem do hóspede: ' + r.message : '');
        try {
          await enviar(cfg.notify_email, 'Nova reserva: ' + v.cabana + ', ' + v.entrada + ' a ' + v.saida, txt, 'host-' + r.id);
          resumo.aviso++;
        } catch (e) {
          await admin.from('booking_requests').update({ aviso_host_at: null }).eq('id', r.id);
          resumo.erros.push('aviso ' + r.id + ': ' + String(e.message || e));
        }
      }
    }
  }

  // ---------- 2) Orientações de check-in (só entre 8h e 20h, horário de Brasília) ----------
  const { hoje, hora } = agoraBR();
  if (hora >= 8 && hora < 20) {
    const { data: prox } = await admin.from('booking_requests').select('*')
      .eq('status', 'confirmada').is('email_checkin_at', null).gte('start_date', hoje).lte('start_date', somaDias(hoje, 14)).limit(30);
    for (const r of prox || []) {
      const t = tpl(r.cabin_id, 'checkin');
      const dias = t ? (t.days_before || 2) : 2;
      if (r.start_date > somaDias(hoje, dias)) continue; // ainda não chegou a hora
      // não manda junto com a confirmação (espera pelo menos 2 horas)
      if (!r.email_confirmacao_at || Date.now() - new Date(r.email_confirmacao_at).getTime() < 2 * 3600 * 1000) continue;
      if (!r.guest_email) { resumo.pulados.push(r.id + ': sem e-mail do hóspede'); continue; }
      if (!t || !String(t.body || '').trim()) { resumo.pulados.push(r.id + ': sem texto de check-in'); continue; }
      if (/\[SUBSTITUA/i.test(t.body) || /\[SUBSTITUA/i.test(t.subject)) { resumo.pulados.push(r.id + ': texto de check-in ainda é o modelo'); continue; }
      const v = variaveis(r, cab(r.cabin_id), cfg.whatsapp_host);
      const { data: claim } = await admin.from('booking_requests')
        .update({ email_checkin_at: new Date().toISOString() }).eq('id', r.id).is('email_checkin_at', null).select('id');
      if (!claim || !claim.length) continue;
      try {
        await enviar(r.guest_email, preencher(t.subject, v), preencher(t.body, v), 'chk-' + r.id);
        resumo.checkin++;
      } catch (e) {
        await admin.from('booking_requests').update({ email_checkin_at: null }).eq('id', r.id);
        resumo.erros.push('checkin ' + r.id + ': ' + String(e.message || e));
      }
    }
  }

  if (resumo.erros.length || resumo.pulados.length || resumo.confirmacao || resumo.aviso || resumo.checkin) console.log('[enviar-emails] ' + JSON.stringify(resumo));
  return json({ ok: true, ...resumo }, 200);
});
