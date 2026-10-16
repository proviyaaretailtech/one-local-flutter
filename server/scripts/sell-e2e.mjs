// E2E: VINII POS section F (sell, split pay, receipts, returns, refunds, coupons) over HTTP against the standalone POS server (routes /api/partner/sell/* and /api/partner/pos-orders/*), as two real signed-in
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
const O = '/pos-orders', S = '/sell';
try {
  sql(`insert into organizations(id,name,slug,type) values ('${orgA}','Golden ZZ POS F A ${run}','zz-pos-f-a-${run}','franchise'),('${orgB}','Golden ZZ POS F B ${run}','zz-pos-f-b-${run}','franchise')`);
  sql(`insert into org_bill_settings(organization_id,service_charge_pct,round_off_enabled,gst_registered,prices_include_tax) values ('${orgA}',0,false,true,false)`);
  const catDairy = randomUUID(), catBev = randomUUID();
  sql(`insert into menu_categories(id,organization_id,name) values ('${catDairy}','${orgA}','Dairy'),('${catBev}','${orgA}','Beverages')`);
  sql(`insert into menu_items(organization_id,category_id,name,sku,price,is_available) values
    ('${orgA}','${catBev}','Coca-Cola 500ml','CC500',40,true),('${orgA}','${catDairy}','Amul Butter 500g','AB500',280,true),
    ('${orgA}','${catDairy}','Amul Milk 1L','AM1L',60,true),('${orgA}','${catBev}','Cadbury Dairy Milk','CDM50',10,false),('${orgB}',null,'B only item',100,true)`.replace("'B only item',100,true","'B only item','BX1',100,true"));
  const A = await staff(orgA, 'manager', 'mgr-a'), BL = await staff(orgA, 'biller', 'biller-a'), V = await staff(orgA, 'viewer', 'viewer-a'), B = await staff(orgB, 'org_owner', 'owner-b');
  ok('four staff signed in', !!A && !!BL && !!V && !!B);

  // ---- catalog / search
  ok('catalog: no token 401', (await api(null, 'GET', `${S}/catalog`)).s === 401);
  const cat = await api(BL, 'GET', `${S}/catalog`);
  ok('catalog: org A sees 4 items with sku, category, availability, and not B', cat.s === 200 && cat.j.items.length === 4 && cat.j.items.every(i => i.sku) && !cat.j.items.some(i => i.name === 'B only item'), cat);
  ok('catalog: categories listed', cat.j.categories.join() === 'Beverages,Dairy', cat.j.categories);
  ok('catalog: out-of-stock item shown, flagged unavailable', cat.j.items.find(i => i.sku === 'CDM50')?.available === false);
  const q1 = await api(BL, 'GET', `${S}/catalog?q=butter`);
  ok('search by name', q1.j.items.length === 1 && q1.j.items[0].sku === 'AB500', q1.j);
  const q2 = await api(BL, 'GET', `${S}/catalog?q=CC500`);
  ok('search by SKU', q2.j.items.length === 1 && q2.j.items[0].name === 'Coca-Cola 500ml', q2.j);
  const q3 = await api(BL, 'GET', `${S}/catalog?category=Dairy&available=1&sort=price_desc`);
  ok('filter category + available, sort price high to low', q3.j.items.map(i => i.sku).join() === 'AB500,AM1L', q3.j.items.map(i => i.sku));
  ok('catalog: bad sort 400', (await api(BL, 'GET', `${S}/catalog?sort=random`)).s === 400);
  ok('catalog: org B sees only its own item', (await api(B, 'GET', `${S}/catalog`)).j.items.length === 1);
  const by = Object.fromEntries(cat.j.items.map(i => [i.sku, i]));
  const six = [{ menu_item_id: by.AB500.id, qty: 2 }, { menu_item_id: by.CC500.id, qty: 1 }];   // 560 + 40 = 600

  // ---- coupons
  ok('biller cannot create a coupon (403)', (await api(BL, 'POST', `${S}/coupons`, { code: 'WELCOME10', kind: 'percent', value: 10 })).s === 403);
  const cp = await api(A, 'POST', `${S}/coupons`, { code: 'welcome10', label: 'Welcome', kind: 'percent', value: 10, min_order: 500, max_discount: 50 });
  ok('manager creates the coupon', cp.s === 200 && cp.j.code === 'WELCOME10', cp);
  ok('coupon: percent over 100 is 400', (await api(A, 'POST', `${S}/coupons`, { code: 'BAD', kind: 'percent', value: 150 })).s === 400);
  ok('coupons list for org A has 1, org B has 0', (await api(BL, 'GET', `${S}/coupons`)).j.coupons.length === 1 && (await api(B, 'GET', `${S}/coupons`)).j.coupons.length === 0);
  const cq = await api(BL, 'POST', `${O}/quote`, { lines: six, coupon_code: 'welcome10' });
  ok('quote with coupon: 10% of 600 capped at 50, GST 5% on 550 = 27.50, total 577.50', cq.s === 200 && Number(cq.j.discount) === 50 && Number(cq.j.gst_amount) === 27.5 && Number(cq.j.total) === 577.5, cq);
  const small = await api(BL, 'POST', `${O}/quote`, { lines: [{ menu_item_id: by.CC500.id, qty: 2 }], coupon_code: 'WELCOME10' });
  ok('coupon below the minimum bill: 422 coupon_minimum', small.s === 422 && small.j.code === 'coupon_minimum', small);
  ok('unknown coupon: 422 coupon_unknown', (await api(BL, 'POST', `${O}/quote`, { lines: six, coupon_code: 'NOPE' })).j.code === 'coupon_unknown');
  ok('org B cannot use org A coupon', (await api(B, 'POST', `${O}/quote`, { lines: [{ menu_item_id: sql(`select id from menu_items where organization_id='${orgB}'`), qty: 1 }], coupon_code: 'WELCOME10' })).j.code === 'coupon_unknown');
  const sold = await api(BL, 'POST', `${O}/checkout`, { lines: six, method: 'cash', tendered: 600, coupon_code: 'WELCOME10', notes: 'ZZ-TEST f' }, k());
  ok('checkout with coupon: paid 577.50, change 22.50', sold.s === 200 && sold.j.bill.discount === 50 && sold.j.bill.total === 577.5, sold.j?.bill);

  // ---- split payment
  const held = await api(BL, 'POST', `${O}/hold`, { lines: [{ menu_item_id: by.AB500.id, qty: 1 }, { menu_item_id: by.AM1L.id, qty: 1 }], customer_name: 'Riya Patel', notes: 'ZZ-TEST f' }, k());
  ok('hold: 340 + 17 GST = 357 due', held.s === 200 && held.j.stage === 'checkout' && held.j.payment.due === 357, held.j.payment);
  const sp = (id, parts, key = k(), version) => api(BL, 'POST', `${S}/orders/${id}/split-pay`, { payments: parts, version }, key);
  ok('split: parts not adding up: 400', (await sp(held.j.id, [{ method: 'cash', amount: 100 }, { method: 'upi', amount: 100 }])).s === 400);
  ok('split: one part only: 400', (await sp(held.j.id, [{ method: 'cash', amount: 357 }])).s === 400);
  ok('split: wallet is not a counter method: 400', (await sp(held.j.id, [{ method: 'wallet', amount: 200 }, { method: 'upi', amount: 157 }])).s === 400);
  ok('split: no key 400', (await api(BL, 'POST', `${S}/orders/${held.j.id}/split-pay`, { payments: [] })).s === 400);
  ok('org B cannot split-pay org A bill (404)', (await api(B, 'POST', `${S}/orders/${held.j.id}/split-pay`, { payments: [{ method: 'cash', amount: 200 }, { method: 'upi', amount: 157 }] }, k())).s === 404);
  ok('viewer cannot take payment (403)', (await api(V, 'POST', `${S}/orders/${held.j.id}/split-pay`, { payments: [{ method: 'cash', amount: 200 }, { method: 'upi', amount: 157 }] }, k())).s === 403);
  const splitKey = k();
  const sp1 = await sp(held.j.id, [{ method: 'cash', amount: 200, tendered: 500 }, { method: 'upi', amount: 157, reference: 'UTR-ZZ' }], splitKey, held.j.version);
  ok('split cash 200 + UPI 157: bill paid, split', sp1.s === 200 && sp1.j.stage === 'pending' && sp1.j.payment_chip === 'Paid · Split', sp1.j);
  ok('split: two payments in the database, change recorded', sql(`select count(*) from payments where order_id='${held.j.id}'`) === '2' && sql(`select tendered from pos_cash_tenders where order_id='${held.j.id}'`) === '500.00');
  const sp2 = await sp(held.j.id, [{ method: 'cash', amount: 200, tendered: 500 }, { method: 'upi', amount: 157, reference: 'UTR-ZZ' }], splitKey);
  ok('split: same key again is a replay', sp2.s === 200 && sp2.j.replayed === true && sql(`select count(*) from payments where order_id='${held.j.id}'`) === '2', sp2.j?.replayed);
  ok('split: a paid bill cannot be paid again (409)', (await sp(held.j.id, [{ method: 'cash', amount: 200 }, { method: 'upi', amount: 157 }])).s === 409);

  // ---- failed payment, online checkout
  const held2 = await api(BL, 'POST', `${O}/hold`, { lines: [{ menu_item_id: by.CC500.id, qty: 3 }], notes: 'ZZ-TEST f' }, k());
  const at = await api(BL, 'POST', `${S}/orders/${held2.j.id}/attempts`, { method: 'card', status: 'declined', code: 'S1', message: 'Insufficient funds' });
  ok('declined card is logged: nothing charged, cart saved', at.s === 200 && at.j.charged === false && at.j.headline === 'Card payment declined' && at.j.amount_due === 126, at);
  ok('the failed attempt moved no money', sql(`select count(*) from payments where order_id='${held2.j.id}'`) === '0' && sql(`select count(*) from sell_payment_attempts where order_id='${held2.j.id}'`) === '1');
  ok('attempt: bad method 400', (await api(BL, 'POST', `${S}/orders/${held2.j.id}/attempts`, { method: 'bitcoin' })).s === 400);
  ok('attempt: org B 404', (await api(B, 'POST', `${S}/orders/${held2.j.id}/attempts`, { method: 'card' })).s === 404);
  ok('attempt: viewer 403', (await api(V, 'POST', `${S}/orders/${held2.j.id}/attempts`, { method: 'card' })).s === 403);
  const oc = await api(BL, 'POST', `${S}/orders/${held2.j.id}/online-checkout`, {});
  ok('online checkout: 503 provider_not_configured, honest sentence', oc.s === 503 && oc.j.code === 'provider_not_configured', oc);
  ok('online checkout: org B 404 (not 503)', (await api(B, 'POST', `${S}/orders/${held2.j.id}/online-checkout`, {})).s === 404);

  // ---- receipts and transaction history
  const rc = await api(BL, 'GET', `${S}/receipts`);
  ok('receipts: 3 bills for org A, newest first', rc.s === 200 && rc.j.receipts.length === 3 && rc.j.receipts[0].id === held2.j.id, rc.j.receipts?.map(r => r.display_no));
  const rSplit = rc.j.receipts.find(r => r.id === held.j.id);
  ok('receipt: split bill labels, items, text', rSplit.status_label === 'Paid · Split' && rSplit.customer === 'Riya Patel' && rSplit.items.length === 2 && rSplit.counts === '2 lines · 2 units' && rSplit.receipt_text.includes('Total ₹357'), rSplit);
  const rCoupon = rc.j.receipts.find(r => r.coupon_code === 'WELCOME10');
  ok('receipt: coupon bill shows the discount line', rCoupon && rCoupon.discount === 50 && rCoupon.receipt_text.includes('Discount WELCOME10 -₹50'), rCoupon);
  ok('receipts: status unpaid = the held bill', (await api(BL, 'GET', `${S}/receipts?status=unpaid`)).j.receipts.map(r => r.id).join() === held2.j.id);
  ok('receipts: search by customer', (await api(BL, 'GET', `${S}/receipts?q=riya`)).j.receipts.length === 1);
  ok('receipts: date range in the past is empty', (await api(BL, 'GET', `${S}/receipts?from=2020-01-01&to=2020-01-31`)).j.receipts.length === 0);
  ok('receipts: today in range finds all 3', (await api(BL, 'GET', `${S}/receipts?from=${new Date().toISOString().slice(0, 10)}&to=${new Date(Date.now() + 864e5).toISOString().slice(0, 10)}`)).j.receipts.length === 3);
  ok('receipts: bad status / date 400', (await api(BL, 'GET', `${S}/receipts?status=x`)).s === 400 && (await api(BL, 'GET', `${S}/receipts?from=yesterday`)).s === 400);
  ok('receipts: org B sees none of org A', (await api(B, 'GET', `${S}/receipts`)).j.receipts.length === 0);

  // ---- returns and refunds
  const soldItems = (await api(BL, 'GET', `${O}/${sold.j.id}`)).j.items;
  const butter = soldItems.find(i => i.name === 'Amul Butter 500g');
  const rq = await api(BL, 'POST', `${S}/returns`, { order_id: sold.j.id, reason: 'Damaged seal', note: 'Seal broken', lines: [{ order_item_id: butter.order_item_id, qty: 1 }] }, k());
  ok('return requested: RET number, amount = its share of the bill (577.50 x 280/600 = 269.50)', rq.s === 200 && rq.j.status === 'requested' && rq.j.amount === 269.5 && /^RET-\d{4}$/.test(rq.j.return_no), rq);
  const retKey = k();
  const rq2 = await api(BL, 'POST', `${S}/returns`, { order_id: sold.j.id, reason: 'Same', lines: [{ order_item_id: butter.order_item_id, qty: 1 }] }, retKey);
  const rq3 = await api(BL, 'POST', `${S}/returns`, { order_id: sold.j.id, reason: 'Same', lines: [{ order_item_id: butter.order_item_id, qty: 1 }] }, retKey);
  ok('return: same key is a replay (one row)', rq3.j.replayed === true && rq3.j.return_id === rq2.j.return_id, [rq2.j, rq3.j]);
  ok('return: more than sold is 422 over_return', (await api(BL, 'POST', `${S}/returns`, { order_id: sold.j.id, reason: 'Too many', lines: [{ order_item_id: butter.order_item_id, qty: 1 }] }, k())).j.code === 'over_return');
  ok('return on an unpaid bill is 409', (await api(BL, 'POST', `${S}/returns`, { order_id: held2.j.id, reason: 'No', lines: [{ order_item_id: (await api(BL, 'GET', `${O}/${held2.j.id}`)).j.items[0].order_item_id, qty: 1 }] }, k())).s === 409);
  ok('return: no key 400', (await api(BL, 'POST', `${S}/returns`, { order_id: sold.j.id, reason: 'x y z', lines: [{ order_item_id: butter.order_item_id, qty: 1 }] })).s === 400);
  ok('return: org B cannot return org A bill (404)', (await api(B, 'POST', `${S}/returns`, { order_id: sold.j.id, reason: 'Nope', lines: [{ order_item_id: butter.order_item_id, qty: 1 }] }, k())).s === 404);
  ok('return list: org B sees none', (await api(B, 'GET', `${S}/returns`)).j.returns.length === 0);
  ok('biller cannot approve (403)', (await api(BL, 'POST', `${S}/returns/${rq.j.return_id}/decide`, { decision: 'approve' })).s === 403);
  ok('org B cannot approve (404)', (await api(B, 'POST', `${S}/returns/${rq.j.return_id}/decide`, { decision: 'approve' })).s === 404);
  ok('refund before approval is 409', (await api(A, 'POST', `${S}/returns/${rq.j.return_id}/refund`, { method: 'cash' }, k())).s === 409);
  ok('manager approves', (await api(A, 'POST', `${S}/returns/${rq.j.return_id}/decide`, { decision: 'approve' })).j.status === 'approved');
  ok('biller cannot give the refund (403)', (await api(BL, 'POST', `${S}/returns/${rq.j.return_id}/refund`, { method: 'cash' }, k())).s === 403);
  const rfKey = k();
  const rf = await api(A, 'POST', `${S}/returns/${rq.j.return_id}/refund`, { method: 'cash' }, rfKey);
  ok('manager refunds 269.50 in cash', rf.s === 200 && rf.j.status === 'refunded' && rf.j.amount === 269.5, rf);
  const rf2 = await api(A, 'POST', `${S}/returns/${rq.j.return_id}/refund`, { method: 'cash' }, k());
  ok('refunding again: replay, still one refund and one ledger entry', rf2.s === 200 && rf2.j.replayed === true && sql(`select count(*) from pos_refunds where order_id='${sold.j.id}'`) === '1' && sql(`select sum(amount_minor) from payment_ledger where order_id='${sold.j.id}' and entry_type='refund'`) === '26950');
  const rl = await api(A, 'GET', `${S}/returns`);
  ok('return list: refunded, with its lines and words', rl.j.returns.length === 2 && rl.j.returns.find(r => r.id === rq.j.return_id).status_label === 'Refunded' && rl.j.returns.find(r => r.id === rq.j.return_id).lines[0].name === 'Amul Butter 500g', rl.j.returns);
  ok('return list filter + search', (await api(A, 'GET', `${S}/returns?status=refunded`)).j.returns.length === 1 && (await api(A, 'GET', `${S}/returns?q=butter`)).j.returns.length === 2);
  const rrej = rq2.j.return_id;
  ok('reject needs a reason (400)', (await api(A, 'POST', `${S}/returns/${rrej}/decide`, { decision: 'reject' })).s === 400);
  ok('manager rejects with a reason', (await api(A, 'POST', `${S}/returns/${rrej}/decide`, { decision: 'reject', note: 'Not eligible' })).j.status === 'rejected');
  ok('receipts: the refunded part shows on the bill', (await api(BL, 'GET', `${S}/receipts?q=${encodeURIComponent(sold.j.display_no)}`)).j.receipts[0].refunded === 269.5);
  // counter refund of a bill: manager only, capped to the money taken
  const dr = (u, amount, key = k()) => api(u, 'POST', `${S}/orders/${sold.j.id}/refund`, { amount, method: 'cash', kind: 'goodwill', reason: 'Goodwill gesture' }, key);
  ok('counter refund: biller 403', (await dr(BL, 10)).s === 403);
  ok('counter refund: more than is left (308.00) is 422 over_refund', (await dr(A, 400)).j.code === 'over_refund');
  const dr1 = await dr(A, 50);
  ok('counter refund: 50 goodwill', dr1.s === 200 && dr1.j.refund.amount === 50, dr1);
  ok('counter refund: org B 404', (await dr(B, 5)).s === 404);
  ok('counter refund: no reason 400', (await api(A, 'POST', `${S}/orders/${sold.j.id}/refund`, { amount: 5, method: 'cash', reason: '' }, k())).s === 400);
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
  for (const t of ['sell_return_lines', 'sell_returns', 'sell_payment_attempts']) sql(`alter table ${t} disable trigger user`);
  sql(`delete from sell_return_lines where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from sell_returns where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from sell_payment_attempts where organization_id in ('${orgA}','${orgB}')`);
  for (const t of ['sell_return_lines', 'sell_returns', 'sell_payment_attempts']) sql(`alter table ${t} enable trigger user`);
  sql(`delete from sell_coupons where organization_id in ('${orgA}','${orgB}')`);
  sql(`delete from menu_categories where organization_id in ('${orgA}','${orgB}')`);
  console.log(execSync('../../database/purge_test_orders.sh', { encoding: 'utf8' }).trim().split('\n').pop());
  console.log('leftover test businesses: ' + sql(`select count(*) from organizations where id in ('${orgA}','${orgB}')`));
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
