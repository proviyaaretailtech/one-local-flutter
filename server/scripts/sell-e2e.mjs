// E2E: VINII POS section F (sell, split pay, receipts, returns, refunds, coupons) over HTTP against the standalone POS server (the generic gateway POST /rpc/<function> (section F) and section E's /api/partner/pos-orders/*), as two real signed-in
// staff members of two different businesses. LOCAL ONLY. Tags its orders 'ZZ-TEST' and purges them, its users and its businesses at the end.
// Usage (from new-mobile-flutter/server, server running):  node scripts/sell-e2e.mjs   (POS_API overrides the address; keys read from ./.env, never printed)
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
  const email = `zz-pos-f-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  users.push(c.id);
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return login.access_token;
}
async function api(token, method, path, body, key) {
  const headers = { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}), ...(key ? { 'Idempotency-Key': key } : {}) };
  const r = await fetch(`${API}/api/partner${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const k = () => `e2e-${randomUUID()}`;
const O = '/pos-orders';
// the till's functions, through the gateway: body = the function's `p` object, the Idempotency-Key header is copied into it
async function rpc(token, fn, body = {}, key) {
  const r = await fetch(`${API}/rpc/${fn}`, { method: 'POST', headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) }, body: JSON.stringify(body) });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
try {
  sql(`insert into organizations(id,name,slug,type) values ('${orgA}','Golden ZZ POS F A ${run}','zz-pos-f-a-${run}','franchise'),('${orgB}','Golden ZZ POS F B ${run}','zz-pos-f-b-${run}','franchise')`);
  sql(`insert into org_bill_settings(organization_id,service_charge_pct,round_off_enabled,gst_registered,prices_include_tax) values ('${orgA}',0,false,true,false)`);
  const catDairy = randomUUID(), catBev = randomUUID();
  sql(`insert into menu_categories(id,organization_id,name) values ('${catDairy}','${orgA}','Dairy'),('${catBev}','${orgA}','Beverages')`);
  sql(`insert into menu_items(organization_id,category_id,name,sku,price,is_available) values
    ('${orgA}','${catBev}','Coca-Cola 500ml','CC500',40,true),('${orgA}','${catDairy}','Amul Butter 500g','AB500',280,true),
    ('${orgA}','${catDairy}','Amul Milk 1L','AM1L',60,true),('${orgA}','${catBev}','Cadbury Dairy Milk','CDM50',10,false),('${orgB}',null,'B only item','BX1',100,true)`);
  const A = await staff(orgA, 'manager', 'mgr-a'), BL = await staff(orgA, 'biller', 'biller-a'), V = await staff(orgA, 'viewer', 'viewer-a'), B = await staff(orgB, 'org_owner', 'owner-b');
  ok('four staff signed in', !!A && !!BL && !!V && !!B);

  // ---- the old per-feature routes are gone; the gateway allowlist is the only door
  ok('old /api/partner/sell/* routes are gone (404)', (await fetch(`${API}/api/partner/sell/catalog`, { headers: { Authorization: `Bearer ${A}` } })).status === 404);
  ok('rpc: no token 401', (await rpc(null, 'pos_sell_catalog')).s === 401);
  ok('rpc: a function that is not in the manifest is 404', (await rpc(A, 'pos_place_order', {})).s === 404);

  // ---- catalog / search
  const cat = await rpc(BL, 'pos_sell_catalog');
  ok('catalog: org A sees 4 items with sku, category, availability, and not B', cat.s === 200 && cat.j.items.length === 4 && cat.j.items.every(i => i.sku) && !cat.j.items.some(i => i.name === 'B only item'), cat);
  ok('catalog: categories listed', cat.j.categories.join() === 'Beverages,Dairy', cat.j.categories);
  ok('catalog: out-of-stock item shown, flagged unavailable', cat.j.items.find(i => i.sku === 'CDM50')?.available === false);
  const q1 = await rpc(BL, 'pos_sell_catalog', { q: 'butter' });
  ok('search by name', q1.j.items.length === 1 && q1.j.items[0].sku === 'AB500', q1.j);
  ok('search by SKU', (await rpc(BL, 'pos_sell_catalog', { q: 'CC500' })).j.items.map(i => i.name).join() === 'Coca-Cola 500ml');
  const q3 = await rpc(BL, 'pos_sell_catalog', { category: 'Dairy', available: true, sort: 'price_desc' });
  ok('filter category + available, sort price high to low', q3.j.items.map(i => i.sku).join() === 'AB500,AM1L', q3.j.items.map(i => i.sku));
  ok('catalog: bad sort 400', (await rpc(BL, 'pos_sell_catalog', { sort: 'random' })).s === 400);
  ok('catalog: a LIKE wildcard in the search is plain text', (await rpc(BL, 'pos_sell_catalog', { q: '%' })).j.items.length === 0);
  ok('catalog: org B sees only its own item', (await rpc(B, 'pos_sell_catalog')).j.items.length === 1);
  const by = Object.fromEntries(cat.j.items.map(i => [i.sku, i]));
  const six = [{ menu_item_id: by.AB500.id, qty: 2 }, { menu_item_id: by.CC500.id, qty: 1 }];   // 560 + 40 = 600

  // ---- coupons
  ok('kitchen and viewer cannot read receipts, returns or coupons (403)', (await rpc(V, 'pos_receipt_list')).s === 403 && (await rpc(V, 'pos_return_list')).s === 403 && (await rpc(V, 'pos_coupon_list')).s === 403);
  ok('biller cannot create a coupon (403)', (await rpc(BL, 'pos_coupon_save', { code: 'WELCOME10', kind: 'percent', value: 10 })).s === 403);
  const cp = await rpc(A, 'pos_coupon_save', { code: 'welcome10', label: 'Welcome', kind: 'percent', value: 10, min_order: 500, max_discount: 50 });
  ok('manager creates the coupon', cp.s === 200 && cp.j.code === 'WELCOME10', cp);
  ok('coupon: percent over 100 is 400', (await rpc(A, 'pos_coupon_save', { code: 'BAD', kind: 'percent', value: 150 })).s === 400);
  ok('coupons list for org A has 1, org B has 0', (await rpc(BL, 'pos_coupon_list')).j.coupons.length === 1 && (await rpc(B, 'pos_coupon_list')).j.coupons.length === 0);
  const cq = await api(BL, 'POST', `${O}/quote`, { lines: six, coupon_code: 'welcome10' });
  ok('quote with coupon: 10% of 600 capped at 50, GST 5% on 550 = 27.50, total 577.50', cq.s === 200 && Number(cq.j.discount) === 50 && Number(cq.j.gst_amount) === 27.5 && Number(cq.j.total) === 577.5, cq);
  const small = await api(BL, 'POST', `${O}/quote`, { lines: [{ menu_item_id: by.CC500.id, qty: 2 }], coupon_code: 'WELCOME10' });
  ok('coupon below the minimum bill: 422 coupon_minimum', small.s === 422 && small.j.code === 'coupon_minimum', small);
  ok('unknown coupon: 422 coupon_unknown', (await api(BL, 'POST', `${O}/quote`, { lines: six, coupon_code: 'NOPE' })).j.code === 'coupon_unknown');
  ok('org B cannot use org A coupon', (await api(B, 'POST', `${O}/quote`, { lines: [{ menu_item_id: sql(`select id from menu_items where organization_id='${orgB}'`), qty: 1 }], coupon_code: 'WELCOME10' })).j.code === 'coupon_unknown');
  const sold = await api(BL, 'POST', `${O}/checkout`, { lines: six, method: 'cash', tendered: 600, coupon_code: 'WELCOME10', notes: 'ZZ-TEST f' }, k());
  ok('checkout with coupon: discount 50, total 577.50', sold.s === 200 && sold.j.bill.discount === 50 && sold.j.bill.total === 577.5, sold.j?.bill);

  // limits and free bills
  await rpc(A, 'pos_coupon_save', { code: 'ONCE1', kind: 'flat', value: 10, max_uses: 1 });
  await rpc(A, 'pos_coupon_save', { code: 'FREE100', kind: 'percent', value: 100 });
  const lim1 = await api(BL, 'POST', `${O}/hold`, { lines: six, coupon_code: 'ONCE1', notes: 'ZZ-TEST f' }, k());
  ok('coupon with 1 use: the first bill takes it', lim1.s === 200 && lim1.j.bill.discount === 10, lim1);
  ok('coupon used up: 422 coupon_limit', (await api(BL, 'POST', `${O}/quote`, { lines: six, coupon_code: 'ONCE1' })).j.code === 'coupon_limit');
  ok('a free bill is refused: 422 coupon_zero', (await api(BL, 'POST', `${O}/quote`, { lines: six, coupon_code: 'FREE100' })).j.code === 'coupon_zero');
  await api(A, 'POST', `${O}/${lim1.j.id}/cancel`, { reason: 'test', version: lim1.j.version });
  ok('cancelling that bill gives the use back', (await api(BL, 'POST', `${O}/quote`, { lines: six, coupon_code: 'ONCE1' })).s === 200);

  // ---- split payment
  const held = await api(BL, 'POST', `${O}/hold`, { lines: [{ menu_item_id: by.AB500.id, qty: 1 }, { menu_item_id: by.AM1L.id, qty: 1 }], customer_name: 'Riya Patel', notes: 'ZZ-TEST f' }, k());
  ok('hold: 340 + 17 GST = 357 due', held.s === 200 && held.j.stage === 'checkout' && held.j.payment.due === 357, held.j.payment);
  const sp = (token, id, parts, key = k(), version) => rpc(token, 'pos_split_pay', { order_id: id, payments: parts, expected_updated_at: version }, key);
  ok('split: parts not adding up: 400', (await sp(BL, held.j.id, [{ method: 'cash', amount: 100 }, { method: 'upi', amount: 100 }])).s === 400);
  ok('split: one part only: 400 (shape)', (await sp(BL, held.j.id, [{ method: 'cash', amount: 357 }])).s === 400);
  ok('split: wallet is not a counter method: 400', (await sp(BL, held.j.id, [{ method: 'wallet', amount: 200 }, { method: 'upi', amount: 157 }])).s === 400);
  ok('split: no key 400', (await rpc(BL, 'pos_split_pay', { order_id: held.j.id, payments: [{ method: 'cash', amount: 200 }, { method: 'upi', amount: 157 }] })).s === 400);
  ok('org B cannot split-pay org A bill (404)', (await sp(B, held.j.id, [{ method: 'cash', amount: 200 }, { method: 'upi', amount: 157 }])).s === 404);
  ok('viewer cannot take payment (403)', (await sp(V, held.j.id, [{ method: 'cash', amount: 200 }, { method: 'upi', amount: 157 }])).s === 403);
  const splitKey = k();
  const parts = [{ method: 'cash', amount: 200, tendered: 500 }, { method: 'upi', amount: 157, reference: 'UTR-ZZ' }];
  const sp1 = await sp(BL, held.j.id, parts, splitKey, held.j.version);
  ok('split cash 200 + UPI 157 accepted', sp1.s === 200 && sp1.j.replayed === false && sp1.j.parts === 2, sp1);
  const paid = (await api(BL, 'GET', `${O}/${held.j.id}`)).j;
  ok('the bill is paid, shown as Split', paid.stage === 'pending' && paid.payment_chip === 'Paid · Split', paid.payment_chip);
  ok('split: two payments in the database, change recorded', sql(`select count(*) from payments where order_id='${held.j.id}'`) === '2' && sql(`select tendered from pos_cash_tenders where order_id='${held.j.id}'`) === '500.00');
  const sp2 = await sp(BL, held.j.id, parts, splitKey);
  ok('split: the same key with other parts is 422 idempotency_mismatch', (await sp(BL, held.j.id, [{ method: 'cash', amount: 1 }, { method: 'upi', amount: 1 }], splitKey)).j?.code === 'idempotency_mismatch');
  ok('split: same key again is a replay', sp2.s === 200 && sp2.j.replayed === true && sql(`select count(*) from payments where order_id='${held.j.id}'`) === '2', sp2.j);
  ok('split: a paid bill cannot be paid again (409)', (await sp(BL, held.j.id, [{ method: 'cash', amount: 200 }, { method: 'upi', amount: 157 }])).s === 409);

  // ---- failed payment, online checkout
  const held2 = await api(BL, 'POST', `${O}/hold`, { lines: [{ menu_item_id: by.CC500.id, qty: 3 }], notes: 'ZZ-TEST f' }, k());
  const at = await rpc(BL, 'pos_payment_attempt_record', { order_id: held2.j.id, method: 'card', status: 'declined', code: 'S1', message: 'Insufficient funds' });
  ok('declined card is logged: nothing charged, due 126, order number back', at.s === 200 && at.j.charged === false && at.j.amount_due === 126 && at.j.display_no === held2.j.display_no && at.j.code === 'S1', at);
  ok('the failed attempt moved no money', sql(`select count(*) from payments where order_id='${held2.j.id}'`) === '0' && sql(`select count(*) from sell_payment_attempts where order_id='${held2.j.id}'`) === '1');
  ok('attempt: bad method 400', (await rpc(BL, 'pos_payment_attempt_record', { order_id: held2.j.id, method: 'bitcoin' })).s === 400);
  ok('attempt: org B 404', (await rpc(B, 'pos_payment_attempt_record', { order_id: held2.j.id, method: 'card' })).s === 404);
  ok('attempt: viewer 403', (await rpc(V, 'pos_payment_attempt_record', { order_id: held2.j.id, method: 'card' })).s === 403);
  const oc = await rpc(BL, 'pos_online_checkout', { order_id: held2.j.id });
  ok('online checkout: 503 provider_not_configured, honest sentence', oc.s === 503 && oc.j.code === 'provider_not_configured', oc);
  ok('online checkout: org B 404 (not 503)', (await rpc(B, 'pos_online_checkout', { order_id: held2.j.id })).s === 404);

  // ---- receipts and transaction history
  const rc = await rpc(BL, 'pos_receipt_list');
  ok('receipts: 4 bills for org A (one cancelled), newest first', rc.s === 200 && rc.j.length === 4 && rc.j[0].id === held2.j.id, rc.j?.map(r => r.display_no));
  const rSplit = rc.j.find(r => r.id === held.j.id);
  ok('receipt row: split bill, customer, 2 lines, methods, status', rSplit.status === 'paid' && rSplit.customer_name === 'Riya Patel' && rSplit.items.length === 2 && rSplit.methods.length === 2 && Number(rSplit.total) === 357 && rSplit.items.every(i => i.order_item_id), rSplit);
  const rCoupon = rc.j.find(r => r.coupon_code === 'WELCOME10');
  ok('receipt row: coupon bill shows the discount', rCoupon && Number(rCoupon.discount) === 50, rCoupon);
  ok('receipts: status unpaid = the held bill', (await rpc(BL, 'pos_receipt_list', { status: 'unpaid' })).j.map(r => r.id).join() === held2.j.id);
  ok('receipts: status cancelled = the cancelled coupon bill', (await rpc(BL, 'pos_receipt_list', { status: 'cancelled' })).j.map(r => r.id).join() === lim1.j.id);
  ok('receipts: search by customer', (await rpc(BL, 'pos_receipt_list', { q: 'riya' })).j.length === 1);
  ok('receipts: date range in the past is empty', (await rpc(BL, 'pos_receipt_list', { from: '2020-01-01', to: '2020-01-31' })).j.length === 0);
  const today = new Date().toISOString().slice(0, 10), tomorrow = new Date(Date.now() + 864e5).toISOString().slice(0, 10);
  ok('receipts: today in range finds all 4', (await rpc(BL, 'pos_receipt_list', { from: today, to: tomorrow })).j.length === 4);
  ok('receipts: bad status / date 400', (await rpc(BL, 'pos_receipt_list', { status: 'x' })).s === 400 && (await rpc(BL, 'pos_receipt_list', { from: 'yesterday' })).s === 400);
  ok('receipts: org B sees none of org A', (await rpc(B, 'pos_receipt_list')).j.length === 0);

  // ---- returns and refunds
  const soldItems = (await api(BL, 'GET', `${O}/${sold.j.id}`)).j.items;
  const butter = soldItems.find(i => i.name === 'Amul Butter 500g');
  const mkRet = (token, order, item, qty, key = k(), reason = 'Damaged seal') => rpc(token, 'pos_return_create', { order_id: order, reason, note: 'Seal broken', lines: [{ order_item_id: item, qty }] }, key);
  const rq = await mkRet(BL, sold.j.id, butter.order_item_id, 1);
  ok('return requested: RET number, amount = its share of the bill (577.50 x 280/600 = 269.50)', rq.s === 200 && rq.j.status === 'requested' && Number(rq.j.amount) === 269.5 && /^RET-\d{4}$/.test(rq.j.return_no), rq);
  const retKey = k();
  const rq2 = await mkRet(BL, sold.j.id, butter.order_item_id, 1, retKey, 'Same');
  const rq3 = await mkRet(BL, sold.j.id, butter.order_item_id, 1, retKey, 'Same');
  ok('return: same key is a replay (one row)', rq3.j.replayed === true && rq3.j.return_id === rq2.j.return_id, [rq2.j, rq3.j]);
  ok('return: more than sold is 422 over_return', (await mkRet(BL, sold.j.id, butter.order_item_id, 1)).j.code === 'over_return');
  const heldItem = (await api(BL, 'GET', `${O}/${held2.j.id}`)).j.items[0].order_item_id;
  ok('return on an unpaid bill is 409', (await mkRet(BL, held2.j.id, heldItem, 1)).s === 409);
  ok('return: no key 400', (await rpc(BL, 'pos_return_create', { order_id: sold.j.id, reason: 'x y z', lines: [{ order_item_id: butter.order_item_id, qty: 1 }] })).s === 400);
  ok('return: org B cannot return org A bill (404)', (await mkRet(B, sold.j.id, butter.order_item_id, 1)).s === 404);
  ok('return list: org B sees none', (await rpc(B, 'pos_return_list')).j.length === 0);
  const dec = (token, id, decision, note) => rpc(token, 'pos_return_decide', { return_id: id, decision, note });
  ok('biller cannot approve (403)', (await dec(BL, rq.j.return_id, 'approve')).s === 403);
  ok('org B cannot approve (404)', (await dec(B, rq.j.return_id, 'approve')).s === 404);
  const rfd = (token, id, method = 'cash', key = k()) => rpc(token, 'pos_return_issue_refund', { return_id: id, method }, key);
  ok('refund before approval is 409', (await rfd(A, rq.j.return_id)).s === 409);
  ok('manager approves', (await dec(A, rq.j.return_id, 'approve')).j.status === 'approved');
  ok('biller cannot give the refund (403)', (await rfd(BL, rq.j.return_id)).s === 403);
  ok('org B cannot give the refund (404)', (await rfd(B, rq.j.return_id)).s === 404);
  const rf = await rfd(A, rq.j.return_id);
  ok('manager refunds 269.50 in cash', rf.s === 200 && rf.j.status === 'refunded' && Number(rf.j.amount) === 269.5, rf);
  const rf2 = await rfd(A, rq.j.return_id);
  ok('refunding again: replay, still one refund and one ledger entry', rf2.s === 200 && rf2.j.replayed === true && sql(`select count(*) from pos_refunds where order_id='${sold.j.id}'`) === '1' && sql(`select sum(amount_minor) from payment_ledger where order_id='${sold.j.id}' and entry_type='refund'`) === '26950');
  const rl = await rpc(A, 'pos_return_list');
  const mine = rl.j.find(r => r.id === rq.j.return_id);
  ok('return list: refunded, with its lines and refund method', rl.j.length === 2 && mine.status === 'refunded' && mine.refund_method === 'cash' && mine.lines[0].name === 'Amul Butter 500g', rl.j);
  ok('return list filter + search', (await rpc(A, 'pos_return_list', { status: 'refunded' })).j.length === 1 && (await rpc(A, 'pos_return_list', { q: 'butter' })).j.length === 2);
  ok('reject needs a reason (400)', (await dec(A, rq2.j.return_id, 'reject')).s === 400);
  ok('manager rejects with a reason', (await dec(A, rq2.j.return_id, 'reject', 'Not eligible')).j.status === 'rejected');
  ok('receipts: the refunded part shows on the bill', Number((await rpc(BL, 'pos_receipt_list', { q: sold.j.display_no })).j[0].refunded) === 269.5);
  // counter refund of a bill (already in the manifest since 0371): manager only, capped to the money taken
  const dr = (token, amount, key = k()) => rpc(token, 'pos_refund', { order_id: sold.j.id, amount, method: 'cash', kind: 'goodwill', reason: 'Goodwill gesture' }, key);
  ok('counter refund: biller 403', (await dr(BL, 10)).s === 403);
  ok('counter refund: more than is left (308.00) is 422 over_refund', (await dr(A, 400)).j.code === 'over_refund');
  const dr1 = await dr(A, 50);
  ok('counter refund: 50 goodwill', dr1.s === 200 && Number(dr1.j.amount) === 50, dr1);
  ok('counter refund: org B 404', (await dr(B, 5)).s === 404);
} catch (e) {
  fail++; console.log('FAIL (crash)', e?.message);
} finally {
  for (const id of users) { sql(`delete from org_users where user_id='${id}'`); sql(`delete from auth.users where id='${id}'`); }
  sql(`update orders set notes='ZZ-TEST e2e' where organization_id in ('${orgA}','${orgB}') and coalesce(notes,'') not like 'ZZ-TEST%'`);
  sql(`update orders set notes='ZZ-TEST f' where organization_id in ('${orgA}','${orgB}') and coalesce(notes,'') not like 'ZZ-TEST%'`);
  sql(`delete from org_bill_settings where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from org_counters where organization_id in ('${orgA}','${orgB}')`);
  try { sql(`delete from inventory_bins where organization_id in ('${orgA}','${orgB}')`); } catch { /* table may not exist on an older schema */ }  // created with each business; blocks the purge
  // returns point at order lines and refunds, which the shared purge does not know about: remove them first (append-only guards lifted for this dev cleanup only)
  for (const t of ['sell_return_lines', 'sell_returns', 'sell_payment_attempts', 'sell_coupon_redemptions']) sql(`alter table ${t} disable trigger user`);
  sql(`delete from sell_coupon_redemptions where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from sell_return_lines where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from sell_returns where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from sell_payment_attempts where organization_id in ('${orgA}','${orgB}')`);
  for (const t of ['sell_return_lines', 'sell_returns', 'sell_payment_attempts', 'sell_coupon_redemptions']) sql(`alter table ${t} enable trigger user`);
  sql(`delete from sell_coupons where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from menu_categories where organization_id in ('${orgA}','${orgB}')`);
  try { console.log(execSync('../../database/purge_test_orders.sh', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim().split('\n').pop()); }
  catch (e) { console.log('purge skipped (another suite\'s test rows block it; the next purge run removes these too): ' + String(e.stderr ?? e.message).split('\n')[0]); }
  console.log('leftover test businesses: ' + sql(`select count(*) from organizations where id in ('${orgA}','${orgB}')`));
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
