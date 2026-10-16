// E2E: VINII POS section E over HTTP against the standalone POS server (routes /api/partner/pos-orders/*), as two real signed-in
// staff members of two different businesses. LOCAL ONLY. Tags its orders 'ZZ-TEST' and purges them, its users and its businesses at the end.
// Usage (from new-mobile-flutter/server, server running):  node scripts/orders-e2e.mjs   (POS_API overrides the address; keys read from ./.env, never printed)
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const API = (process.env.POS_API ?? 'http://localhost:8090').replace(/\/+$/, '');
const envFile = process.env.OL_ENV ?? '.env';
const env = Object.fromEntries(readFileSync(envFile, 'utf8').split('\n').filter(l => /^[A-Z_]+=/.test(l)).map(l => [l.split('=')[0], l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '')]));
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(env.SUPABASE_URL) || !/^http:\/\/(127\.0\.0\.1|localhost):/.test(API)) throw new Error('local only');
const U = env.SUPABASE_URL, ANON = env.SUPABASE_ANON_KEY || env.SUPABASE_PUBLISHABLE_KEY, SRV = env.SUPABASE_SERVICE_ROLE_KEY;
const sql = q => execSync(`docker exec supabase_db_onelocal-dev psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt -c "${q.replace(/"/g, '\\"')}"`, { encoding: 'utf8' }).trim();
let pass = 0, fail = 0;
const ok = (n, c, d) => { if (c) { pass++; console.log('ok  ', n); } else { fail++; console.log('FAIL', n, d === undefined ? '' : JSON.stringify(d).slice(0, 400)); } };

const run = Date.now().toString(36);
const orgA = randomUUID(), orgB = randomUUID();
const users = [];
async function staff(org, role, tag) {
  const email = `zz-pos-e-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  users.push(c.id);
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return login.access_token;
}
async function api(token, method, path, body, key) {
  const headers = { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}), ...(key ? { 'Idempotency-Key': key } : {}) };
  const r = await fetch(`${API}/api/partner/pos-orders${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const k = () => `e2e-${randomUUID()}`;

try {
  sql(`insert into organizations(id,name,slug,type) values ('${orgA}','Golden ZZ POS E A ${run}','zz-pos-e-a-${run}','franchise'),('${orgB}','Golden ZZ POS E B ${run}','zz-pos-e-b-${run}','franchise')`);
  sql(`insert into org_bill_settings(organization_id,service_charge_pct) values ('${orgA}',10)`);
  sql(`insert into menu_items(organization_id,name,price) values ('${orgA}','Amul Butter 500g',320),('${orgA}','Britannia Good Day 600g',280),('${orgA}','Parle Monaco 200g',60),('${orgA}','Horlicks 500g',320),('${orgA}','Kinley Mineral Water 1L',90),('${orgB}','B only item',100)`);
  const A = await staff(orgA, 'manager', 'mgr-a'), B = await staff(orgB, 'org_owner', 'owner-b'), V = await staff(orgA, 'viewer', 'viewer-a');
  ok('three staff signed in', !!A && !!B && !!V);

  ok('no token: 401', (await api(null, 'GET', '')).s === 401);
  const root = `${API}/rpc/me`, bearer = t => ({ method: 'POST', headers: { Authorization: `Bearer ${t}` } });
  const meA = await fetch(root, bearer(A)).then(async r => ({ s: r.status, j: await r.json() }));
  ok('/me: staff of A sees A and their role', meA.s === 200 && meA.j.restaurant.id === orgA && meA.j.person.role === 'manager' && meA.j.restaurant.set_up === false, meA);
  ok('/me: no token 401, garbage token 401', (await fetch(root, { method: 'POST' })).status === 401 && (await fetch(root, bearer('x'.repeat(40)))).status === 401);
  ok('unknown path 404, wrong method 405', (await fetch(`${API}/api/nope`)).status === 404 && (await fetch(root, { method: 'GET' })).status === 405);
  const cat = await api(A, 'GET', '/catalog');
  ok('catalog: org A sees its 5 items only', cat.s === 200 && cat.j.items.length === 5 && !cat.j.items.some(i => i.name === 'B only item'), cat);
  const qty = { 'Amul Butter 500g': 2, 'Britannia Good Day 600g': 1, 'Parle Monaco 200g': 3, 'Horlicks 500g': 1, 'Kinley Mineral Water 1L': 2 };
  const lines = cat.j.items.map(i => ({ menu_item_id: i.id, qty: qty[i.name] }));
  const q = await api(A, 'POST', '/quote', { lines });
  ok('quote: 1600 + 80 GST + 160 service = 1840', q.s === 200 && Number(q.j.total) === 1840 && Number(q.j.gst_amount) === 80 && Number(q.j.service_charge) === 160, q);
  const coupon = await api(A, 'POST', '/quote', { lines, coupon_code: 'WELCOME10' });
  ok('coupon: honest 422 refusal', coupon.s === 422 && coupon.j.code === 'coupon_unknown', coupon);
  ok('checkout without Idempotency-Key: 400', (await api(A, 'POST', '/checkout', { lines, method: 'cash', tendered: 2000 })).s === 400);
  const short = await api(A, 'POST', '/checkout', { lines, method: 'cash', tendered: 1800, notes: 'ZZ-TEST e2e' }, k());
  ok('short cash: 422 underpaid', short.s === 422 && short.j.code === 'underpaid', short);

  // concurrency: five taps with the same key at the same moment make exactly one order
  const key1 = k();
  const burst = await Promise.all([1, 2, 3, 4, 5].map(() => api(A, 'POST', '/checkout', { lines, method: 'cash', tendered: 2000, notes: 'ZZ-TEST e2e' }, key1)));
  const ids = new Set(burst.filter(r => r.s === 200).map(r => r.j.id));
  ok('same key x5 in parallel: one order', ids.size === 1 && burst.every(r => r.s === 200 || r.s === 409), burst.map(r => [r.s, r.j?.code]));
  ok('same key x5: one row in the database', sql(`select count(*) from orders where organization_id='${orgA}' and idempotency_key='${key1}'`) === '1');
  const order = burst.find(r => r.s === 200).j;
  ok('checkout: Order Confirmation, pending, paid cash', order.stage === 'pending' && order.title === 'Order Confirmation' && order.payment_chip === 'Paid · Cash' && order.fulfilment === 'Awaiting store acceptance', order);
  ok('checkout: tender 2000, change 160, record settled', order.payment.tendered === 2000 && order.payment.change === 160 && order.payment.record.value === '₹1,840 settled', order.payment);
  ok('checkout: 5 lines · 9 units, receipt text', order.summary === '5 lines · 9 units' && order.receipt_text.includes('Cash tendered ₹2,000'), order.summary);
  const replay = await api(A, 'POST', '/checkout', { lines, method: 'cash', tendered: 2000, notes: 'ZZ-TEST e2e' }, key1);
  ok('replay: same order, replayed', replay.s === 200 && replay.j.id === order.id && replay.j.replayed === true, replay.j?.replayed);

  // tenancy
  ok('org B cannot read org A order (404)', (await api(B, 'GET', `/${order.id}`)).s === 404);
  ok('org B cannot move org A order (404)', (await api(B, 'POST', `/${order.id}/act`, { action: 'accept', version: 1 }, k())).s === 404);
  const histB = await api(B, 'GET', '');
  ok('org B history has none of org A', histB.s === 200 && histB.j.orders.length === 0, histB.j);
  ok('org B cannot quote org A items', (await api(B, 'POST', '/quote', { lines })).s === 409);
  ok('viewer of org A cannot move orders (403)', (await api(V, 'POST', `/${order.id}/act`, { action: 'accept', version: 1 }, k())).s === 403);

  // concurrency: two phones accept the same version with different keys: one wins, one is told to refresh
  const race = await Promise.all([api(A, 'POST', `/${order.id}/act`, { action: 'accept', version: 1 }, k()), api(A, 'POST', `/${order.id}/act`, { action: 'accept', version: 1 }, k())]);
  ok('double accept: exactly one 200, the other 409', race.filter(r => r.s === 200).length === 1 && race.filter(r => r.s === 409).length === 1, race.map(r => [r.s, r.j?.code]));
  let v = (await api(A, 'GET', `/${order.id}`)).j;
  ok('accepted: Order Preparing, 0 of 9 checked', v.stage === 'preparing' && v.fulfilment === 'Picking items · 0 of 9 checked', v.fulfilment);
  const step = async (action, extra = {}) => { const r = await api(A, 'POST', `/${order.id}/act`, { action, version: v.version, ...extra }, k()); if (r.s === 200) v = r.j; return r; };
  const first = v.items[0];  // the order of lines is not fixed by the database, so the expected count comes from the line picked
  const half = await step('pick', { lines: [{ order_item_id: first.order_item_id, qty: first.qty }] });
  ok(`partial pick: still preparing, ${first.qty} of 9`, half.s === 200 && v.stage === 'preparing' && v.fulfilment.startsWith(`Picking items · ${first.qty} of 9`), half.j);
  await step('pick', { lines: v.items.map(i => ({ order_item_id: i.order_item_id, qty: i.qty })) });
  ok('all picked: Order Picked', v.stage === 'picked' && v.fulfilment === '9 of 9 units picked · not packed', v.fulfilment);
  ok('picked offers Start packing', v.actions[0].id === 'pack', v.actions);
  await step('pack');
  ok('packed: Order Ready, handover or dispatch', v.stage === 'ready' && v.actions.map(a => a.id).join() === 'handover,dispatch,receipt', v.actions);
  await step('dispatch');
  ok('dispatch without address: Order Exception', v.stage === 'exception' && v.danger === true && v.note.title === 'Delivery information is missing', v.note);
  const badPhone = await step('set_delivery_info', { delivery: { phone: '12', address: '12 Main road, Latur' } });
  ok('bad phone: 400', badPhone.s === 400, badPhone.j);
  await step('set_delivery_info', { delivery: { phone: '9876543210', address: '12 Main road, Latur', name: 'Guest' } });
  ok('info added: back to ready', v.stage === 'ready', v.stage);
  await step('dispatch');
  ok('dispatched: Order In Transit', v.stage === 'in_transit' && v.order_status === 'Dispatched', v.order_status);
  const stale = await api(A, 'POST', `/${order.id}/act`, { action: 'confirm_delivery', version: v.version - 1 }, k());
  ok('stale version: 409 version_conflict', stale.s === 409 && stale.j.code === 'version_conflict', stale.j);
  await step('confirm_delivery');
  ok('confirmed: completed, order delivered', v.stage === 'completed' && sql(`select status from orders where id='${order.id}'`) === 'delivered', v.stage);
  ok('completed: nothing else moves', (await api(A, 'POST', `/${order.id}/act`, { action: 'return_to_store', version: v.version }, k())).s === 409);

  // hold, pay later, hold and cancel
  const h1 = await api(A, 'POST', '/hold', { lines: [lines[1]], customer_name: 'Rahul Mehta', notes: 'ZZ-TEST e2e' }, k());
  ok('hold: Checkout stage, awaiting payment', h1.s === 200 && h1.j.stage === 'checkout' && h1.j.payment_chip === 'Awaiting payment', h1.j);
  const p1 = await api(A, 'POST', `/${h1.j.id}/pay`, { method: 'upi', reference: 'UPI-ZZ', version: h1.j.version }, k());
  ok('pay held by UPI: pending, paid UPI', p1.s === 200 && p1.j.stage === 'pending' && p1.j.payment_chip === 'Paid · UPI', p1.j);
  const h2 = await api(A, 'POST', '/hold', { lines: [lines[2]], notes: 'ZZ-TEST e2e' }, k());
  ok('cancel needs a reason', (await api(A, 'POST', `/${h2.j.id}/cancel`, { reason: '' })).s === 400);
  const c2 = await api(A, 'POST', `/${h2.j.id}/cancel`, { reason: 'Customer left', version: h2.j.version });
  ok('cancelled before capture', c2.s === 200 && c2.j.stage === 'cancelled' && c2.j.payment_chip === 'Not captured' && c2.j.note.title === 'Cancelled before cash capture', c2.j);

  // history
  const all = await api(A, 'GET', '');
  ok('history: 3 orders, newest first', all.s === 200 && all.j.orders.length === 3 && all.j.orders[0].id === h2.j.id, all.j.orders?.map(o => o.id));
  const done = await api(A, 'GET', '?filter=completed');
  ok('history completed: the delivered order, card labels', done.j.orders.length === 1 && done.j.orders[0].status_label === 'Completed' && done.j.orders[0].items === '5 lines · 9 units' && done.j.orders[0].payment_status === 'Paid' && done.j.orders[0].payment_mode === 'Cash' && done.j.orders[0].delivery_status === 'Delivered · 9 of 9 units', done.j.orders[0]);
  const pend = await api(A, 'GET', '?filter=pending');
  ok('history pending: the paid held order', pend.j.orders.length === 1 && pend.j.orders[0].id === h1.j.id && pend.j.orders[0].channel_label === 'Store Checkout', pend.j.orders);
  const canc = await api(A, 'GET', '?filter=cancelled');
  ok('history cancelled', canc.j.orders.length === 1 && canc.j.orders[0].payment_status === 'Not captured', canc.j.orders);
  const search = await api(A, 'GET', '?q=rahul');
  ok('history search by customer', search.j.orders.length === 1 && search.j.orders[0].customer === 'Rahul Mehta', search.j.orders);
  ok('history: bad filter 400', (await api(A, 'GET', '?filter=zomato')).s === 400);
} catch (e) {
  fail++; console.log('FAIL (crash)', e?.message);
} finally {
  for (const id of users) { sql(`delete from org_users where user_id='${id}'`); sql(`delete from auth.users where id='${id}'`); }
  sql(`update orders set notes='ZZ-TEST e2e' where organization_id in ('${orgA}','${orgB}') and coalesce(notes,'') not like 'ZZ-TEST%'`);
  sql(`delete from org_bill_settings where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from org_counters where organization_id in ('${orgA}','${orgB}')`);
  try { sql(`delete from inventory_bins where organization_id in ('${orgA}','${orgB}')`); } catch { /* table may not exist on an older schema */ }  // created with each business; blocks the purge
  console.log(execSync('../../database/purge_test_orders.sh', { encoding: 'utf8' }).trim().split('\n').pop());
  console.log('leftover test businesses: ' + sql(`select count(*) from organizations where id in ('${orgA}','${orgB}')`));
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
