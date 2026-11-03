// E2E: cancel a dish, cancel KOT items, refund and void a restaurant bill (database 0640) over HTTP against the standalone POS server's
// generic gateway (POST /rpc/<function>), as real signed-in staff of two businesses: owner, manager, cashier (biller), captain, viewer, and
// the owner of another business. LOCAL ONLY. Tags its orders 'ZZ-TEST' and leaves its two ZZ businesses on the local database.
// Usage (from one-local-flutter/server, server running):  node scripts/rst-cancel-refund-e2e.mjs
//   POS_API overrides the address; OL_DB the database container; keys are read from ./.env and never printed.
import { readFileSync, writeFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const API = (process.env.POS_API ?? 'http://localhost:8090').replace(/\/+$/, '');
const DB = process.env.OL_DB ?? 'supabase_db_onelocal-local-db';
const env = Object.fromEntries(readFileSync(process.env.OL_ENV ?? '.env', 'utf8').split('\n').filter(l => /^[A-Z_]+=/.test(l)).map(l => [l.split('=')[0], l.slice(l.indexOf('=') + 1).trim().replace(/^"|"$/g, '')]));
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(env.SUPABASE_URL) || !/^http:\/\/(127\.0\.0\.1|localhost):/.test(API)) throw new Error('local only');
const U = env.SUPABASE_URL, ANON = env.SUPABASE_ANON_KEY || env.SUPABASE_PUBLISHABLE_KEY, SRV = env.SUPABASE_SERVICE_ROLE_KEY;
const sql = q0 => { const q = q0.split('\n').join(' '); return execSync(`docker exec ${DB} psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt -c "${q.replace(/"/g, '\\"')}"`, { encoding: 'utf8' }).trim(); };
let pass = 0, fail = 0;
const ok = (n, c, d) => { if (c) { pass++; console.log('ok  ', n); } else { fail++; console.log('FAIL', n, d === undefined ? '' : JSON.stringify(d).slice(0, 600)); } };
const num = v => Number(v ?? NaN);

const run = Date.now().toString(36);
const orgA = randomUUID(), orgB = randomUUID();
async function staff(org, role, tag) {
  const email = `zz-rcr-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return { token: login.access_token, id: c.id };
}
async function rpc(who, fn, body = {}, key) {
  const r = await fetch(`${API}/rpc/${fn}`, { method: 'POST', headers: { ...(who ? { Authorization: `Bearer ${who.token}` } : {}), 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) }, body: JSON.stringify(body) });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const k = () => `e2e-${randomUUID()}`;
// FIXTURES=<file>: keep some real answers for the app's widget tests (test/fixtures/rst_cancel_refund_server.json)
const FX = {};
const keep = (n, j) => { FX[n] = j; return j; };
const msg = r => JSON.stringify(r.j ?? '').toLowerCase();

// an order on a table with lines [name, qty, price, status, kot?]; KOT 1 holds the sent lines; priced by the database's own repricing
function order(no, table, status, lines) {
  const o = randomUUID(), kot = randomUUID(), ids = [];
  sql(`insert into orders(id,order_no,display_no,organization_id,location_id,channel,status,table_id,subtotal,gst_pct,gst_amount,total,notes) values
       ('${o}',${no},'Z${no}','${orgA}','${locA}','dine_in','${status}','${table}',0,5,0,0,'ZZ-TEST rst cancel refund')`);
  if (lines.some(l => l[4])) sql(`insert into kot_tickets(id,organization_id,order_id,kot_no,station,status) values ('${kot}','${orgA}','${o}',${no},'main','new')`);
  for (const [name, qty, price, st, sent] of lines) {
    const id = randomUUID(); ids.push(id);
    sql(`insert into order_items(id,order_id,name,qty,unit_price,status,kot_ticket_id) values ('${id}','${o}','${name}',${qty},${price},'${st}',${sent ? `'${kot}'` : 'null'})`);
  }
  sql(`select tbl_order_reprice('${o}')`);
  return { o, kot, ids };
}
const view = async (who, o) => (await rpc(who, 'rst_order_adjust', { order_id: o })).j;
const total = o => num(sql(`select total from orders where id='${o}'`));

let locA;
try {
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${orgA}','Golden ZZ RCR A ${run}','zz-rcr-a-${run}','franchise','Restaurant'),('${orgB}','Golden ZZ RCR B ${run}','zz-rcr-b-${run}','franchise','Restaurant')`);
  locA = sql(`select id from locations where organization_id='${orgA}' limit 1`);
  const tables = [1, 2, 3, 4, 5, 6, 7].map(n => { const t = randomUUID(); sql(`insert into dining_tables(id,organization_id,location_id,label,seats) values ('${t}','${orgA}','${locA}','R${n}',4)`); return t; });
  const OWN = await staff(orgA, 'org_owner', 'own'), MGR = await staff(orgA, 'manager', 'mgr'), CASH = await staff(orgA, 'biller', 'cash'),
    CAP = await staff(orgA, 'captain', 'cap'), VIEW = await staff(orgA, 'viewer', 'view'), B = await staff(orgB, 'org_owner', 'own-b');
  ok('six staff signed in', [OWN, MGR, CASH, CAP, VIEW, B].every(x => x.token));

  // ================================================================ 1. item cancel
  // Paneer 2×320 (sent, waiting), Naan 4×50 (sent, waiting), Tikka 1×600 (cooking), Lassi 1×100 (not sent)
  const A = order(9101, tables[0], 'sent_to_kitchen', [['Paneer', 2, 320, 'pending', true], ['Naan', 4, 50, 'pending', true], ['Tikka', 1, 600, 'preparing', true], ['Lassi', 1, 100, 'pending', false]]);
  const [paneer, naan, tikka, lassi] = A.ids;
  const other = order(9107, tables[6], 'sent_to_kitchen', [['Dal', 2, 200, 'pending', true]]);
  const otherTotal = total(other.o);
  ok('order A priced: 1540 + 5% = 1617', total(A.o) === 1617, total(A.o));

  let r = await rpc(CAP, 'rst_items_cancel', { order_id: A.o, items: [{ item_id: lassi, qty: 1 }], reason: 'Added by mistake' }, k());
  ok('captain cancels a dish not sent to the kitchen', r.s === 200 && r.j.status === 'cancelled', r);
  ok('…the line stays, cancelled', sql(`select status||':'||qty||':'||cancelled_qty from order_items where id='${lassi}'`) === 'cancelled:1:1');
  ok('…the bill drops to 1440 + 5% = 1512', total(A.o) === 1512 && num(r.j.new_total) === 1512, r.j);

  const keyN = k();
  r = await rpc(CAP, 'rst_items_cancel', { order_id: A.o, items: [{ item_id: naan, qty: 2 }], reason: 'Guest wants only two' }, keyN);
  keep('cancelled', r.j);
  ok('captain cancels 2 of 4 naan already sent (not started)', r.s === 200 && r.j.status === 'cancelled', r);
  ok('…naan is 2 left, 2 cancelled, still waiting', sql(`select status||':'||qty||':'||cancelled_qty from order_items where id='${naan}'`) === 'pending:2:2');
  ok('…bill 1340 + 5% = 1407', total(A.o) === 1407, total(A.o));
  const r2 = await rpc(CAP, 'rst_items_cancel', { order_id: A.o, items: [{ item_id: naan, qty: 2 }], reason: 'Guest wants only two' }, keyN);
  ok('…the same key again replays and cancels nothing more', r2.s === 200 && r2.j.replayed === true && sql(`select qty from order_items where id='${naan}'`) === '2', r2);

  // the kitchen hears it
  const q = await rpc(MGR, 'kds_queue', {});
  const alert = (q.j?.cancelled ?? []).find(x => x.order_id === A.o && x.partial);
  ok('KDS: an item-cancel alert for the naan (stop making 2)', !!alert && alert.items[0].name === 'Naan' && alert.items[0].qty === 2 && alert.reason === 'Guest wants only two', q.j?.cancelled);
  ok('KDS: the not-sent lassi raises no alert', !(q.j?.cancelled ?? []).some(x => x.order_id === A.o && x.items[0]?.name === 'Lassi'));
  const kv = await rpc(CAP, 'rst_kot_orders', {});
  const kc = kv.j?.orders?.find(x => x.id === A.o);
  ok('KOT view: history shows 2× Naan cancelled with the reason', kc && kc.item_cancels.length === 1 && kc.item_cancels[0].qty === 2 && kc.item_cancels[0].reason === 'Guest wants only two', kc);
  ok('KOT ticket still open, cooking (the tikka)', sql(`select status from kot_tickets where id='${A.kot}'`) === 'preparing');

  // cooking dish: the captain asks, a manager approves
  r = await rpc(CAP, 'rst_items_cancel', { order_id: A.o, items: [{ item_id: tikka, qty: 1 }], reason: 'Guest left the table' }, k());
  ok('captain on a dish being cooked: a request, nothing cancelled yet', r.s === 200 && r.j.status === 'requested' && sql(`select status from order_items where id='${tikka}'`) === 'preparing', r);
  keep('requested', r.j);
  const reqId = r.j.request_id;
  r = await rpc(CAP, 'rst_items_cancel', { order_id: A.o, items: [{ item_id: tikka, qty: 1 }], reason: 'Guest left the table' }, k());
  ok('…asking again returns the same request', r.j?.request_id === reqId && r.j.replayed === true, r);
  r = await rpc(MGR, 'rst_requests_list', {});
  keep('requests', r.j);
  ok('manager sees the request', r.s === 200 && r.j.requests.some(x => x.request_id === reqId && x.may_decide), r);
  ok('captain may not approve own request', (await rpc(CAP, 'rst_request_decide', { request_id: reqId, decision: 'approve' })).s === 403);
  ok('cashier may not approve a request', (await rpc(CASH, 'rst_request_decide', { request_id: reqId, decision: 'approve' })).s === 403);
  r = await rpc(MGR, 'rst_request_decide', { request_id: reqId, decision: 'approve', note: 'ok' });
  ok('manager approves: the tikka is cancelled', r.s === 200 && r.j.status === 'cancelled' && sql(`select status from order_items where id='${tikka}'`) === 'cancelled', r);
  ok('…bill 740 + 5% = 777', total(A.o) === 777, total(A.o));
  ok('…the history names who asked and who approved',
    sql(`select (meta->>'by')||'|'||(meta->>'approved_by')||'|'||(meta->>'request_id') from order_events where order_id='${A.o}' and kind='item_cancelled' and meta->>'item_id'='${tikka}'`) === `${CAP.id}|${MGR.id}|${reqId}`);
  ok('…deciding twice is refused', (await rpc(MGR, 'rst_request_decide', { request_id: reqId, decision: 'approve' })).s >= 400);
  ok('…an audit row was written for each cancel', num(sql(`select count(*) from audit_logs where entity_id='${A.o}' and action='rst.item_cancel'`)) === 3);

  r = await rpc(MGR, 'rst_items_cancel', { order_id: A.o, items: [{ item_id: tikka, qty: 1 }], reason: 'Again' }, k());
  ok('an already cancelled dish cannot be cancelled again', r.s >= 400 && msg(r).includes('already cancelled'), r);
  r = await rpc(CAP, 'rst_items_cancel', { order_id: A.o, items: [{ item_id: paneer, qty: 3 }], reason: 'Too many' }, k());
  ok('more than is on the order is refused', r.s === 400, r);
  r = await rpc(CAP, 'rst_items_cancel', { order_id: A.o, items: [{ item_id: paneer, qty: 2 }, { item_id: naan, qty: 2 }], reason: 'Everything' }, k());
  ok('cancelling every dish left is refused (cancel the order)', r.s >= 400 && msg(r).includes('whole order'), r);
  ok('a viewer cannot cancel a dish', (await rpc(VIEW, 'rst_items_cancel', { order_id: A.o, items: [{ item_id: paneer, qty: 1 }], reason: 'No role' }, k())).s === 403);
  ok('another business gets 404', (await rpc(B, 'rst_items_cancel', { order_id: A.o, items: [{ item_id: paneer, qty: 1 }], reason: 'Not mine' }, k())).s === 404);
  ok('no reason is refused', (await rpc(CAP, 'rst_items_cancel', { order_id: A.o, items: [{ item_id: paneer, qty: 1 }], reason: '' }, k())).s === 400);

  // served dish, manager directly; the KOT follows; the order is ready when nothing is left to cook
  const S = order(9102, tables[1], 'sent_to_kitchen', [['Soup', 1, 150, 'delivered', true], ['Rice', 1, 200, 'pending', true], ['Roti', 2, 30, 'ready', true]]);
  r = await rpc(CAP, 'rst_items_cancel', { order_id: S.o, items: [{ item_id: S.ids[0], qty: 1 }], reason: 'Served cold' }, k());
  ok('captain on a served dish: a request', r.j?.status === 'requested', r);
  r = await rpc(MGR, 'rst_items_cancel', { order_id: S.o, items: [{ item_id: S.ids[1], qty: 1 }], reason: 'Out of rice' }, k());
  ok('manager cancels the last dish still to cook', r.s === 200 && r.j.status === 'cancelled', r);
  ok('…the order is now ready (nothing left to cook)', sql(`select status from orders where id='${S.o}'`) === 'ready');
  ok('…the KOT is ready too', sql(`select status from kot_tickets where id='${S.kot}'`) === 'ready');

  // a percent discount follows the new subtotal
  const D = order(9103, tables[2], 'sent_to_kitchen', [['Pizza', 2, 500, 'pending', true], ['Coke', 2, 100, 'pending', true]]);
  r = await rpc(MGR, 'rst_bill_discount', { order_id: D.o, kind: 'percent', value: 10, reason: 'Regular guest' });
  ok('10% discount on 1200: 120 off', r.s === 200 && num(sql(`select discount from orders where id='${D.o}'`)) === 120, r);
  r = await rpc(CAP, 'rst_items_cancel', { order_id: D.o, items: [{ item_id: D.ids[0], qty: 1 }], reason: 'One pizza only' }, k());
  const d = sql(`select subtotal||'|'||discount||'|'||gst_amount||'|'||total from orders where id='${D.o}'`).split('|').map(Number);
  ok('…after 1 pizza off: subtotal 700, discount 70, GST 31.50, total 662', r.s === 200 && d[0] === 700 && d[1] === 70 && d[2] === 31.5 && d[3] === 662, d);
  ok('order totals of other bills are unaffected', total(other.o) === otherTotal);

  // ================================================================ 2. paid bill: refunds
  const P = order(9104, tables[3], 'awaiting_payment', [['Thali', 4, 250, 'delivered', true]]);
  ok('bill P is 1000 + 5% = 1050', total(P.o) === 1050);
  r = await rpc(CASH, 'rst_bill_pay', { order_id: P.o, method: 'cash', tendered: 1050 }, k());
  ok('cashier takes 1050 in cash', r.s === 200 && sql(`select status from orders where id='${P.o}'`) === 'paid', r);
  r = await rpc(CAP, 'rst_items_cancel', { order_id: P.o, items: [{ item_id: P.ids[0], qty: 1 }], reason: 'After paying' }, k());
  ok('a dish on a paid bill cannot be cancelled (refund instead)', r.s >= 400 && msg(r).includes('refund'), r);

  r = await rpc(CASH, 'rst_bill_refund', { order_id: P.o, amount: 50, method: 'cash', reason: 'Cold soup' }, k());
  ok('cashier asks for a 50 refund (no money moves yet)', r.s === 200 && r.j.status === 'requested' && num(sql(`select count(*) from pos_refunds where order_id='${P.o}'`)) === 0, r);
  const rq = r.j.request_id;
  r = await rpc(MGR, 'rst_request_decide', { request_id: rq, decision: 'approve' });
  ok('manager approves: 50 refunded through the shared refund', r.s === 200 && r.j.status === 'refunded' && num(r.j.refundable) === 1000, r);
  ok('…one pos_refunds row and one payment_ledger refund row', sql(`select count(*) from pos_refunds where order_id='${P.o}'`) === '1' && sql(`select count(*) from payment_ledger where order_id='${P.o}' and entry_type='refund'`) === '1');

  let v = await view(MGR, P.o);
  keep('paid_mgr', v); keep('paid_cash', await view(CASH, P.o));
  ok('payment details: paid 1050, refunded 50, refundable 1000, partly refunded', num(v.money.paid) === 1050 && num(v.money.refunded) === 50 && num(v.money.refundable) === 1000 && v.money.payment_status === 'partly_refunded', v.money);
  ok('…refund history lists who refunded and who asked', v.refunds.length === 1 && v.refunds[0].by === 'ZZ mgr' && v.refunds[0].asked_by === 'ZZ cash', v.refunds);

  const kr = k();
  r = await rpc(MGR, 'rst_bill_refund', { order_id: P.o, amount: 50, method: 'upi', reason: 'Goodwill' }, kr);
  keep('refunded', r.j);
  ok('manager refunds 50 more directly', r.s === 200 && r.j.status === 'refunded' && num(r.j.refundable) === 950, r);
  r = await rpc(MGR, 'rst_bill_refund', { order_id: P.o, amount: 50, method: 'upi', reason: 'Goodwill' }, kr);
  ok('…a double tap with the same key does not refund twice', r.s === 200 && r.j.replayed === true && sql(`select count(*) from pos_refunds where order_id='${P.o}'`) === '2', r);
  r = await rpc(MGR, 'rst_bill_refund', { order_id: P.o, amount: 2000, method: 'cash', reason: 'Too much' }, k());
  ok('refund above what is left is refused', r.s >= 400 && msg(r).includes('950'), r);
  ok('a captain cannot refund', (await rpc(CAP, 'rst_bill_refund', { order_id: P.o, amount: 10, method: 'cash', reason: 'Not allowed' }, k())).s === 403);
  ok('a viewer cannot refund', (await rpc(VIEW, 'rst_bill_refund', { order_id: P.o, amount: 10, method: 'cash', reason: 'Not allowed' }, k())).s === 403);
  ok('another business cannot refund', (await rpc(B, 'rst_bill_refund', { order_id: P.o, amount: 10, method: 'cash', reason: 'Not mine' }, k())).s === 404);
  r = await rpc(MGR, 'rst_bill_refund', { order_id: P.o, amount: 950, method: 'cash', reason: 'Full refund of the rest' }, k());
  ok('the rest (950) refunded: fully refunded', r.s === 200 && num(r.j.refundable) === 0 && r.j.payment_status === 'refunded', r);
  r = await rpc(MGR, 'rst_bill_refund', { order_id: P.o, amount: 1, method: 'cash', reason: 'One more' }, k());
  ok('…nothing more can be refunded', r.s >= 400, r);
  v = await view(MGR, P.o);
  ok('…bill stays paid, refunded 1050, can.refund off', v.status === 'paid' && num(v.money.refunded) === 1050 && v.can.refund === false && !!v.unavailable.refund, v);

  // ================================================================ 3. void
  const V = order(9105, tables[4], 'awaiting_payment', [['Biryani', 2, 300, 'delivered', true]]);
  r = await rpc(CASH, 'rst_bill_pay', { order_id: V.o, method: 'upi', reference: 'UPI123' }, k());
  ok('bill V paid 630 by UPI', r.s === 200 && sql(`select status from orders where id='${V.o}'`) === 'paid', r);
  r = await rpc(MGR, 'rst_bill_void', { order_id: V.o, reason: 'Wrong table billed' }, k());
  ok('void of a paid bill without a way back is refused', r.s === 400 && msg(r).includes('choose how'), r);
  r = await rpc(MGR, 'rst_bill_void', { order_id: V.o, reason: 'Wrong table billed', method: 'upi' }, k());
  ok('manager asks to void (owner decides)', r.s === 200 && r.j.status === 'requested', r);
  const vq = r.j.request_id;
  ok('another manager cannot approve a void', (await rpc(MGR, 'rst_request_decide', { request_id: vq, decision: 'approve' })).s === 403);
  r = await rpc(OWN, 'rst_request_decide', { request_id: vq, decision: 'approve' });
  ok('owner approves: 630 refunded and the bill cancelled', r.s === 200 && r.j.status === 'voided' && num(r.j.refunded) === 630 && sql(`select status from orders where id='${V.o}'`) === 'cancelled', r);
  ok('…the refund is a cancellation refund in pos_refunds', sql(`select kind||':'||amount from pos_refunds where order_id='${V.o}'`) === 'cancel:630.00');
  ok('…a voided bill cannot be voided again', (await rpc(OWN, 'rst_bill_void', { order_id: V.o, reason: 'Again', method: 'upi' }, k())).s >= 400);
  ok('…and cannot be refunded', (await rpc(OWN, 'rst_bill_refund', { order_id: V.o, amount: 1, method: 'upi', reason: 'After void' }, k())).s >= 400);

  const W = order(9106, tables[5], 'sent_to_kitchen', [['Momos', 2, 120, 'pending', true]]);
  const kw = k();
  r = await rpc(OWN, 'rst_bill_void', { order_id: W.o, reason: 'Guest walked out before eating' }, kw);
  ok('owner voids an unpaid bill: cancelled, nothing refunded', r.s === 200 && r.j.status === 'voided' && !r.j.refund_id && sql(`select status from orders where id='${W.o}'`) === 'cancelled', r);
  ok('…its KOT is cancelled and the kitchen is told (KDS cancel alert)', sql(`select status from kot_tickets where id='${W.kot}'`) === 'cancelled'
    && ((await rpc(MGR, 'kds_queue', {})).j?.cancelled ?? []).some(x => x.order_id === W.o && !x.partial));
  r = await rpc(OWN, 'rst_bill_void', { order_id: W.o, reason: 'Guest walked out before eating' }, kw);
  ok('…the same key replays', r.s === 200 && r.j.replayed === true, r);
  ok('a captain cannot void', (await rpc(CAP, 'rst_bill_void', { order_id: P.o, reason: 'No role' }, k())).s === 403);

  // a request can be rejected
  r = await rpc(CASH, 'rst_bill_void', { order_id: A.o, reason: 'Test reject' }, k());
  ok('cashier asks to void bill A', r.j?.status === 'requested', r);
  r = await rpc(OWN, 'rst_request_decide', { request_id: r.j.request_id, decision: 'reject', note: 'No' });
  ok('owner rejects: bill A stays open', r.s === 200 && r.j.status === 'rejected' && sql(`select status from orders where id='${A.o}'`) !== 'cancelled', r);

  // ================================================================ 4. report and history
  const today = new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10);
  r = await rpc(OWN, 'rst_report_cancellations', { from: today, to: today });
  keep('report', r.j);
  ok('report: 6 dishes cancelled (1 lassi, 2 naan, 1 tikka, 1 rice, 1 pizza)', r.s === 200 && r.j.items.count === 6, r.j?.items);
  ok('report: 2 bills voided, refunds 1680 (50+50+950+630)', r.j?.voids?.count === 2 && r.j?.refunds?.amount_minor === 168000, { v: r.j?.voids?.count, a: r.j?.refunds?.amount_minor });
  ok('report: cashiers cannot see it', (await rpc(CASH, 'rst_report_cancellations', { from: today, to: today })).s === 403);
  v = await view(CAP, A.o);
  keep('open_cap', v); keep('open_mgr', await view(MGR, A.o));
  ok('order history: the cancelled dishes with reasons and who', v.cancelled_items.length === 3 && v.cancelled_items.some(x => x.name === 'Tikka' && x.approved_by === 'ZZ mgr'), v.cancelled_items);
  ok('order history: the cancelled lassi still on the order with status cancelled', v.items.some(x => x.name === 'Lassi' && x.status === 'cancelled' && x.cancelled_qty === 1));
  const tv = await rpc(CAP, 'tbl_order_view', { table_id: tables[0] });
  ok('table order view: naan line says 2 cancelled; can.cancel_items', tv.s === 200 && tv.j.items.some(x => x.name === 'Naan' && x.cancelled_qty === 2) && tv.j.can.cancel_items === true && tv.j.cancelled_items.length === 3, tv.j?.can);
  ok('nothing was ever deleted: every A line is still there', sql(`select count(*) from order_items where order_id='${A.o}'`) === '4');
  ok('the other order is untouched', total(other.o) === otherTotal && sql(`select count(*) from order_events where order_id='${other.o}' and kind in ('item_cancelled','bill_voided','refunded')`) === '0');
} catch (e) {
  fail++; console.log('FAIL crashed', e.message);
}
if (process.env.FIXTURES) writeFileSync(process.env.FIXTURES, JSON.stringify(FX, null, 1));
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
