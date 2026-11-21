// @ts-nocheck
// O Asaas avisa aqui quando uma cobrança é paga. Confirma a reserva no banco.
// Em Edge Functions: desligar "Verify JWT" (o Asaas não envia login; a segurança é o token abaixo).
import { createClient } from 'npm:@supabase/supabase-js@2';

const json = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { 'Content-Type': 'application/json' } });

function igual(a, b) {
  if (a.length !== b.length) return false;
  let x = 0;
  for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: true });

  const esperado = Deno.env.get('ASAAS_WEBHOOK_TOKEN') || '';
  const recebido = req.headers.get('asaas-access-token') || '';
  if (!esperado || !igual(recebido, esperado)) return json({ error: 'não autorizado' }, 401);

  let body = null;
  try { body = await req.json(); } catch (_) { /* corpo vazio */ }
  const ev = body && body.event;
  const pay = body && body.payment;
  if (!pay || !pay.id) return json({ ok: true, ignorado: 'sem cobrança' });
  if (ev !== 'PAYMENT_CONFIRMED' && ev !== 'PAYMENT_RECEIVED') return json({ ok: true, ignorado: ev });

  try {
    // não confia só no aviso: consulta a cobrança no Asaas
    const base = (Deno.env.get('ASAAS_BASE_URL') || 'https://api-sandbox.asaas.com/v3').replace(/\/$/, '');
    const r = await fetch(base + '/payments/' + encodeURIComponent(pay.id), {
      headers: { access_token: Deno.env.get('ASAAS_API_KEY') || '', 'User-Agent': 'CabanasLoom' },
    });
    if (!r.ok) throw new Error('Asaas HTTP ' + r.status);
    const real = await r.json();
    if (!['CONFIRMED', 'RECEIVED', 'RECEIVED_IN_CASH'].includes(real.status)) {
      return json({ ok: true, ignorado: 'status ' + real.status });
    }

    const admin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    const { data, error } = await admin.rpc('confirm_payment', { p_payment_id: real.id, p_value: real.value });
    if (error) throw new Error(error.message);
    console.log('[asaas-webhook] ' + real.id + ' -> ' + data);
    return json({ ok: true, resultado: data });
  } catch (err) {
    console.log('[asaas-webhook] ERRO ' + String(err.message || err));
    return json({ error: String(err.message || err) }, 500); // o Asaas tenta de novo
  }
});
