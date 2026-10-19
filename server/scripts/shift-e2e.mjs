// E2E + cross-tenant test of the store cash shift, payment pending and refund check (0500-0502) through POST /rpc/<name>. LOCAL ONLY.
// Business A (manager, second manager, biller, viewer) opens a shift, sells, moves cash, waits on a UPI payment, confirms it, fails a card
// payment and retries, checks a refund, closes with a difference above the limit and gets it approved. Business B (a real signed-in owner)
// then tries every one of these functions against A's ids: it must get 404 / nothing, and A's rows must be unchanged.
// Tags its orders 'ZZ-TEST' and purges them; the test businesses and their shifts are kept (shifts are never deleted).
// Usage (from new-mobile-flutter/server, server running):  POS_API=http://localhost:8093 OL_ENV=<local .env> node scripts/shift-e2e.mjs
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const API = (process.env.POS_API ?? 'http://localhost:8090').replace(/\/+$/, '');
const env = Object.fromEntries(readFileSync(process.env.OL_ENV ?? '.env', 'utf8').split('\n').filter(l => /^[A-Z_]+=/.test(l)).map(l => [l.split('=')[0], l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '')]));
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(env.SUPABASE_URL) || !/^http:\/\/(127\.0\.0\.1|localhost):/.test(API)) throw new Error('local only');
const U = env.SUPABASE_URL, ANON = env.SUPABASE_ANON_KEY || env.SUPABASE_PUBLISHABLE_KEY, SRV = env.SUPABASE_SERVICE_ROLE_KEY;
const sql = q => execSync(`docker exec supabase_db_onelocal-dev psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt -c "${q.replace(/"/g, '\\"')}"`, { encoding: 'utf8' }).trim();
let pass = 0, fail = 0;
const ok = (n, c, d) => { if (c) { pass++; console.log('ok  ', n); } else { fail++; console.log('FAIL', n, d === undefined ? '' : JSON.stringify(d).slice(0, 400)); } };
const run = Date.now().toString(36);
const orgA = randomUUID(), orgB = randomUUID(), itemA = randomUUID(), itemB = randomUUID();
const users = [];
async function person(tag, org, role) {
  const email = `zz-shift-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  users.push(c.id);
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return login.access_token;
}
async function rpc(token, fn, args = {}, key) {
  const r = await fetch(`${API}/rpc/${fn}`, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) }, body: JSON.stringify(args) });
  const t = await r.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const k = () => `shift-e2e-${randomUUID()}`;
const lines = id => [{ menu_item_id: id, qty: 2 }];   // 2 x 100 + 5% GST = 210

try {
  sql(`insert into organizations(id,name,slug,type) values ('${orgA}','ZZ SHIFT A ${run}','zz-shift-a-${run}','franchise'),('${orgB}','ZZ SHIFT B ${run}','zz-shift-b-${run}','franchise')`);
  const locA = sql(`select id from locations where organization_id='${orgA}' order by created_at limit 1`);
  sql(`insert into org_bill_settings(organization_id, service_charge_pct, round_off_enabled, gst_registered, prices_include_tax) values ('${orgA}',0,false,true,false),('${orgB}',0,false,true,false)`);
  sql(`insert into menu_items(id,organization_id,name,price) values ('${itemA}','${orgA}','ZZ Item A',100),('${itemB}','${orgB}','ZZ Item B',100)`);
  const A = await person('mgr-a', orgA, 'manager'), A2 = await person('mgr2-a', orgA, 'manager'), BL = await person('biller-a', orgA, 'biller'), V = await person('viewer-a', orgA, 'viewer'), B = await person('owner-b', orgB, 'org_owner');
  ok('signed in', !!A && !!A2 && !!BL && !!V && !!B);

  // ---- A: shift before the first bill
  const pol = await rpc(A, 'pos_till_policy_set', { require_open_shift: true, variance_limit: 100 });
  ok('A manager turns on shift-before-bill, limit 100', pol.s === 200 && pol.j.require_open_shift === true, pol);
  ok('biller cannot change the till rules (403)', (await rpc(BL, 'pos_till_policy_set', { require_open_shift: false })).s === 403);
  const cur0 = await rpc(BL, 'pos_shift_current', {});
  ok('no shift: must_open', cur0.s === 200 && cur0.j.must_open === true && cur0.j.shift === null, cur0);
  const noShift = await rpc(BL, 'pos_checkout', { method: 'cash', tendered: 500, lines: lines(itemA), notes: 'ZZ-TEST shift' }, k());
  ok('a bill without an open shift: 409 no_shift', noShift.s === 409 && noShift.j.code === 'no_shift', noShift);
  ok('viewer cannot open a shift (403)', (await rpc(V, 'pos_shift_open', { opening_float: 100 }, k())).s === 403);
  ok('bad float refused before the database (400)', (await rpc(BL, 'pos_shift_open', { opening_float: -5 }, k())).s === 400);
  const openKey = k();
  const sh = await rpc(BL, 'pos_shift_open', { opening_float: 1000 }, openKey);
  ok('biller opens the shift with 1000', sh.s === 200 && sh.j.status === 'open' && Number(sh.j.totals.expected_cash) === 1000, sh);
  const shAgain = await rpc(BL, 'pos_shift_open', { opening_float: 1000 }, openKey);
  ok('same Idempotency-Key replays the same shift', shAgain.s === 200 && shAgain.j.id === sh.j.id && shAgain.j.replayed === true, shAgain);
  ok('a second shift: 409 shift_open', (await rpc(BL, 'pos_shift_open', { opening_float: 1 }, k())).j?.code === 'shift_open');

  // ---- A: sales and cash moves
  const cash = await rpc(BL, 'pos_checkout', { method: 'cash', tendered: 500, lines: lines(itemA), notes: 'ZZ-TEST shift' }, k());
  ok('cash bill 210', cash.s === 200, cash);
  const mv = await rpc(BL, 'pos_shift_cash_move', { shift_id: sh.j.id, kind: 'out', amount: 60, reason: 'ZZ courier' }, k());
  ok('cash out 60: expected 1150', mv.s === 200 && Number(mv.j.totals.expected_cash) === 1150, mv);
  ok('cash out above the drawer: 422', (await rpc(BL, 'pos_shift_cash_move', { shift_id: sh.j.id, kind: 'out', amount: 99999, reason: 'ZZ too much' }, k())).s === 422);

  // ---- A: payment pending
  const held = await rpc(BL, 'pos_checkout', { hold: true, lines: lines(itemA), notes: 'ZZ-TEST shift' }, k());
  ok('held bill', held.s === 200, held);
  const piKey = k();
  const pi = await rpc(BL, 'pos_payment_start', { order_id: held.j.order_id, method: 'upi' }, piKey);
  ok('UPI waiting: pending, bill not paid', pi.s === 200 && pi.j.status === 'pending' && pi.j.order_status !== 'paid' && Number(pi.j.paid) === 0, pi);
  ok('same key returns the same pending payment', (await rpc(BL, 'pos_payment_start', { order_id: held.j.order_id, method: 'upi' }, piKey)).j?.id === pi.j.id);
  ok('another payment while waiting: 409 payment_pending', (await rpc(BL, 'pos_payment_start', { order_id: held.j.order_id, method: 'card' }, k())).j?.code === 'payment_pending');
  ok('confirm without a reference: 400', (await rpc(BL, 'pos_payment_confirm', { intent_id: pi.j.id, reference: 'x' })).s === 400);
  const pc = await rpc(BL, 'pos_payment_confirm', { intent_id: pi.j.id, reference: 'ZZUPI001' });
  const pc2 = await rpc(BL, 'pos_payment_confirm', { intent_id: pi.j.id, reference: 'ZZUPI001' });
  ok('confirmed: paid once; a retry replays', pc.s === 200 && pc.j.status === 'succeeded' && pc.j.order_status === 'paid' && pc2.j?.replayed === true
    && sql(`select count(*) from payments where order_id='${held.j.order_id}'`) === '1', [pc, pc2]);
  const held2 = await rpc(BL, 'pos_checkout', { hold: true, lines: lines(itemA), notes: 'ZZ-TEST shift' }, k());
  const pi2 = await rpc(BL, 'pos_payment_start', { order_id: held2.j.order_id, method: 'card' }, k());
  const pf = await rpc(BL, 'pos_payment_fail', { intent_id: pi2.j.id, status: 'declined', code: '05', message: 'ZZ do not honour' });
  ok('declined card: failed, logged, bill unpaid', pf.s === 200 && pf.j.status === 'failed' && pf.j.attempt?.status === 'declined' && pf.j.order_status !== 'paid', pf);
  const pi3 = await rpc(BL, 'pos_payment_start', { order_id: held2.j.order_id, method: 'upi' }, k());
  const pc3 = await rpc(BL, 'pos_payment_confirm', { intent_id: pi3.j.id, reference: 'ZZUPI002' });
  ok('retry after a failure succeeds', pc3.s === 200 && pc3.j.status === 'succeeded', pc3);

  // ---- A: refund not allowed
  const rc = await rpc(BL, 'pos_refund_check', { order_id: cash.j.order_id, purpose: 'refund', amount: 50 });
  ok('biller refund: not allowed, needs_manager', rc.s === 200 && rc.j.allowed === false && rc.j.reasons.some(r => r.code === 'needs_manager'), rc);
  const rc2 = await rpc(A, 'pos_refund_check', { order_id: cash.j.order_id, purpose: 'refund', amount: 500 });
  ok('manager above what was paid: over_paid', rc2.s === 200 && rc2.j.allowed === false && rc2.j.reasons.some(r => r.code === 'over_paid') && Number(rc2.j.refundable_left) === 210, rc2);
  ok('manager within: allowed', (await rpc(A, 'pos_refund_check', { order_id: cash.j.order_id, purpose: 'refund', amount: 50 })).j?.allowed === true);

  // ---- B against A (before the close, while A's shift is open)
  const x = (fn, args, key) => rpc(B, fn, args, key);
  const bCur = await x('pos_shift_current', {});
  ok('B: its own store, no shift, nothing of A', bCur.s === 200 && bCur.j.shift === null && !JSON.stringify(bCur.j).includes(sh.j.id), bCur);
  ok('B: cannot read A store drawer or history', (await x('pos_shift_current', { location_id: locA })).s === 404 && (await x('pos_shift_list', { location_id: locA })).s === 404);
  ok('B: own history holds nothing of A', (await x('pos_shift_list', {})).j?.length === 0);
  ok('B: cannot open on A store, move A cash, close or approve A shift',
    (await x('pos_shift_open', { location_id: locA, opening_float: 1 }, k())).s === 404
    && (await x('pos_shift_cash_move', { shift_id: sh.j.id, kind: 'out', amount: 1, reason: 'ZZ hack' }, k())).s === 404
    && (await x('pos_shift_close', { shift_id: sh.j.id, counted_cash: 0, variance_reason: 'ZZ hack' }, k())).s === 404
    && (await x('pos_shift_approve', { shift_id: sh.j.id, note: 'ZZ hack' })).s === 404);
  ok('B: cannot change A till rules', (await x('pos_till_policy_set', { location_id: locA, require_open_shift: false })).s === 404);
  ok('B: cannot start, read, confirm or fail A payments',
    (await x('pos_payment_start', { order_id: held2.j.order_id, method: 'upi' }, k())).s === 404
    && (await x('pos_payment_status', { intent_id: pi.j.id })).s === 404 && (await x('pos_payment_status', { order_id: held.j.order_id })).s === 404
    && (await x('pos_payment_confirm', { intent_id: pi2.j.id, reference: 'ZZHACK01' })).s === 404 && (await x('pos_payment_fail', { intent_id: pi3.j.id })).s === 404);
  ok('B: cannot check refunds on A bill', (await x('pos_refund_check', { order_id: cash.j.order_id })).s === 404);
  ok('A rows untouched by B', sql(`select status||':'||version from till_shifts where id='${sh.j.id}'`) === 'open:1'
    && sql(`select count(*) from till_cash_moves where shift_id='${sh.j.id}'`) === '1' && sql(`select require_open_shift from till_policies where location_id='${locA}'`) === 't'
    && sql(`select status from sell_payment_intents where id='${pi2.j.id}'`) === 'failed');

  // ---- A: close with a difference above the limit; a second manager approves
  const cur1 = await rpc(BL, 'pos_shift_current', {});
  const expected = Number(cur1.j.shift.totals.expected_cash);
  ok('expected cash is float + cash sales - cash out (UPI not in cash)', expected === 1150 && Number(cur1.j.shift.totals.sales_by_method.upi) === 420, cur1.j.shift?.totals);
  ok('a difference without a reason: 422', (await rpc(BL, 'pos_shift_close', { shift_id: sh.j.id, counted_cash: expected - 150 }, k())).s === 422);
  const cl = await rpc(A, 'pos_shift_close', { shift_id: sh.j.id, counted_cash: expected - 150, variance_reason: 'ZZ short' }, k());
  ok('150 short is above 100: pending approval', cl.s === 200 && cl.j.status === 'pending_approval' && Number(cl.j.variance) === -150, cl);
  ok('the counting manager cannot approve (403)', (await rpc(A, 'pos_shift_approve', { shift_id: sh.j.id, note: 'ZZ self' })).s === 403);
  ok('biller cannot approve (403)', (await rpc(BL, 'pos_shift_approve', { shift_id: sh.j.id, note: 'ZZ biller' })).s === 403);
  const ap = await rpc(A2, 'pos_shift_approve', { shift_id: sh.j.id, note: 'ZZ counted twice' });
  ok('second manager approves: closed', ap.s === 200 && ap.j.status === 'closed', ap);
  const ls = await rpc(BL, 'pos_shift_list', {});
  ok('history shows the closed shift', ls.s === 200 && ls.j[0]?.id === sh.j.id, ls);
} catch (e) {
  fail++; console.log('FAIL (crash)', e?.stack?.slice(0, 600));
} finally {
  for (const id of users) { try { sql(`delete from org_users where user_id='${id}'`); sql(`delete from auth.users where id='${id}'`); } catch { /* kept rows are test users */ } }
  try { sql(`update orders set notes='ZZ-TEST shift' where organization_id in ('${orgA}','${orgB}') and coalesce(notes,'') not like 'ZZ-TEST%'`); } catch {}
  try { console.log(execSync('../../database/purge_test_orders.sh', { encoding: 'utf8' }).trim().split('\n').pop()); } catch (e) { console.log('purge:', e.message.slice(0, 120)); }
  console.log('test businesses kept (shifts are never deleted): ZZ SHIFT A/B ' + run);
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
