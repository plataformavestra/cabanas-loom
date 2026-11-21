// @ts-nocheck
// Você aprova um pedido no painel: segura as datas e cria a cobrança no Asaas.
// O hóspede recebe o link de pagamento (Pix, cartão ou boleto). Quem paga confirma a reserva pelo webhook.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });
const br = (d) => String(d).split('-').reverse().join('/');

async function asaas(path, method, body) {
  const base = (Deno.env.get('ASAAS_BASE_URL') || 'https://api-sandbox.asaas.com/v3').replace(/\/$/, '');
  const r = await fetch(base + path, {
    method,
    headers: { 'Content-Type': 'application/json', access_token: Deno.env.get('ASAAS_API_KEY') || '', 'User-Agent': 'CabanasLoom' },
    body: body ? JSON.stringify(body) : undefined,
  });
  let j = null;
  try { j = await r.json(); } catch (_) { /* sem corpo */ }
  if (!r.ok) {
    const msg = j && j.errors && j.errors[0] && j.errors[0].description;
    throw new Error(msg || 'Asaas respondeu HTTP ' + r.status);
  }
  return j;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'método inválido' }, 405);

  const url = Deno.env.get('SUPABASE_URL');
  const userClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY'), {
    global: { headers: { Authorization: req.headers.get('Authorization') || '' } },
  });
  const { data: u } = await userClient.auth.getUser();
  if (!u || !u.user) return json({ error: 'Não autorizado.' }, 401);
  const { data: isAdm } = await userClient.rpc('is_admin');
  if (isAdm !== true) return json({ error: 'Não autorizado.' }, 403);

  let body = {};
  try { body = await req.json(); } catch (_) { /* corpo vazio */ }
  const id = body && body.id;
  if (!id) return json({ error: 'Pedido não informado.' }, 400);

  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
  const { data: r, error: e1 } = await admin.from('booking_requests').select('*').eq('id', id).single();
  if (e1 || !r) return json({ error: 'Pedido não encontrado.' }, 404);
  if (r.status !== 'pendente') return json({ error: 'Este pedido já foi respondido.' }, 409);

  const valor = Math.round(Number(body.valor != null ? body.valor : r.total_price) * 100) / 100;
  if (!(valor > 0)) return json({ error: 'Informe o valor da reserva.' }, 400);
  const horas = Math.max(1, Math.min(72, Math.round(Number(body.horas) || 24)));

  // 1) segura as datas (valida conflito dentro do banco)
  const { error: e2 } = await admin.rpc('hold_booking', { p_id: id, p_valor: valor, p_hours: horas });
  if (e2) return json({ error: e2.message || 'Não foi possível aprovar.' }, 409);

  // 2) cria a cobrança no Asaas; se falhar, devolve tudo como estava
  try {
    const { data: held } = await admin.from('booking_requests').select('expires_at').eq('id', id).single();
    const { data: cab } = await admin.from('cabins').select('name').eq('id', r.cabin_id).single();
    const dueDate = new Date(held.expires_at).toLocaleDateString('en-CA', { timeZone: 'America/Sao_Paulo' });

    const cli = {
      name: r.guest_name, cpfCnpj: r.guest_cpf, email: r.guest_email, mobilePhone: r.guest_phone, externalReference: r.id,
    };
    const achados = await asaas('/customers?cpfCnpj=' + encodeURIComponent(r.guest_cpf) + '&limit=1', 'GET');
    let customerId;
    if (achados && achados.data && achados.data.length) {
      customerId = achados.data[0].id;
      try { await asaas('/customers/' + customerId, 'PUT', cli); } catch (_) { /* segue com o cadastro existente */ }
    } else {
      customerId = (await asaas('/customers', 'POST', cli)).id;
    }

    const pay = await asaas('/payments', 'POST', {
      customer: customerId,
      billingType: 'UNDEFINED',
      value: valor,
      dueDate,
      description: 'Reserva ' + (cab && cab.name ? cab.name : 'Cabanas Loom') + ' · ' + br(r.start_date) + ' a ' + br(r.end_date),
      externalReference: r.id,
    });

    const { error: e3 } = await admin.from('booking_requests')
      .update({ payment_id: pay.id, payment_url: pay.invoiceUrl }).eq('id', id);
    if (e3) throw new Error('cobrança criada, mas não foi possível salvar: ' + e3.message);
    return json({ ok: true, payment_url: pay.invoiceUrl, valor, expires_at: held.expires_at });
  } catch (err) {
    await admin.rpc('release_booking', { p_id: id, p_status: 'pendente' });
    return json({ error: 'Asaas: ' + String(err.message || err) }, 502);
  }
});
