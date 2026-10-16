// E2E: VINII POS section G over HTTP against the standalone POS server (routes /api/partner/catalogue/* and /api/partner/grn/*), as real signed-in
// staff of two different businesses. Receipts are created and submitted with section H's database functions (what H's own server calls); needs section H installed.
// LOCAL ONLY. Creates two ZZ businesses and removes them, their users and their rows at the end.
// Usage (from new-mobile-flutter/server, server running):  node scripts/catalogue-e2e.mjs   (POS_API overrides the address; keys read from ./.env, never printed)
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
  const email = `zz-pos-g-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
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
// section H's database functions, called as the signed-in user (what H's own server does)
async function inv(token, fn, p) {
  const r = await fetch(`${U}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ p }) });
  const t = await r.text(); let j = null; try { j = JSON.parse(t); } catch { j = { raw: t }; }
  return { s: r.status, j };
}
const k = () => `e2e-${randomUUID()}`;

try {
  if (sql(`select to_regprocedure('public.inv_document_act(jsonb)') is not null`) !== 't') throw new Error('section H (0400-0403) is not installed on this database');
  sql(`insert into organizations(id,name,slug,type) values ('${orgA}','Golden ZZ POS G A ${run}','zz-pos-g-a-${run}','franchise'),('${orgB}','Golden ZZ POS G B ${run}','zz-pos-g-b-${run}','franchise')`);
  const niraj = await staff(orgA, 'inventory_manager', 'niraj'), rohan = await staff(orgA, 'org_owner', 'rohan'), asha = await staff(orgA, 'org_admin', 'asha'), omar = await staff(orgB, 'org_owner', 'omar');

  // ---------------------------------------------------------------- catalogue
  ok('catalogue needs a sign-in', (await api(null, 'GET', '/catalogue')).s === 401);
  const key1 = k();
  const q1 = await api(niraj, 'POST', '/catalogue', { mode: 'quick', name: 'Coca-Cola 500ml', sku: 'CC500', price_minor: 4000 }, key1);
  ok('quick add: item created, 40 rupees in paise, tax not verified', q1.s === 200 && q1.j.status === 'active' && q1.j.price_minor === 4000 && q1.j.tax_verified === false && !!q1.j.inventory_item_id, q1);
  const q1b = await api(niraj, 'POST', '/catalogue', { mode: 'quick', name: 'Coca-Cola 500ml', sku: 'CC500', price_minor: 4000 }, key1);
  ok('quick add replay with the same Idempotency-Key: same item', q1b.s === 200 && q1b.j.id === q1.j.id && q1b.j.replayed === true, q1b);
  ok('duplicate SKU 409', (await api(niraj, 'POST', '/catalogue', { mode: 'quick', name: 'Other', sku: 'cc500', price_minor: 100 })).s === 409);
  ok('unknown field 400 (no mass assignment)', (await api(niraj, 'POST', '/catalogue', { mode: 'quick', name: 'X', sku: 'X1', price_minor: 100, organization_id: orgB })).s === 400);
  ok('price as a decimal 400 (minor units only)', (await api(niraj, 'POST', '/catalogue', { mode: 'quick', name: 'X', sku: 'X2', price: 1.5 })).s === 400);
  const noTax = await api(niraj, 'POST', '/catalogue', { mode: 'full', name: 'Oat Crunch Cookies 200g', sku: 'OC-200-PK', category: 'Snacks', barcode: 'VINII-OAT-200', price_minor: 4000, mrp_minor: 4500, selling_unit: 'pack', net_qty: 200, net_qty_unit: 'g' });
  ok('full save without HSN/GST 422 tax_required', noTax.s === 422 && noTax.j.code === 'tax_required', noTax);
  const dr = await api(niraj, 'POST', '/catalogue', { mode: 'full', draft: true, name: 'Oat Crunch Cookies 200g', sku: 'OC-200-PK', category: 'Snacks', barcode: 'VINII-OAT-200', price_minor: 4000, mrp_minor: 4500, cost_minor: 2400, selling_unit: 'pack', net_qty: 200, net_qty_unit: 'g' });
  ok('draft saved, not for sale', dr.s === 200 && dr.j.status === 'draft' && dr.j.available === false, dr);
  ok('price above MRP 400', (await api(niraj, 'POST', '/catalogue', { mode: 'full', draft: true, name: 'B', sku: 'B1', price_minor: 5000, mrp_minor: 4500 })).s === 400);
  const done = await api(niraj, 'PUT', `/catalogue/${dr.j.id}`, { version: dr.j.version, mode: 'full', draft: false, hsn: '1905', gst_pct: 18 });
  ok('draft completed with tax: active, verified, version 2', done.s === 200 && done.j.status === 'active' && done.j.tax_verified === true && done.j.version === 2, done);
  ok('old version 409 version_conflict', (await api(niraj, 'PUT', `/catalogue/${dr.j.id}`, { version: 1, name: 'Stale' })).j?.code === 'version_conflict');
  ok('update without a version 400', (await api(niraj, 'PUT', `/catalogue/${dr.j.id}`, { name: 'No version' })).s === 400);
  const list = await api(niraj, 'GET', '/catalogue');
  ok('list: 2 items, counts active 2, one category', list.s === 200 && list.j.counts.total === 2 && list.j.counts.active === 2 && list.j.counts.categories === 1 && list.j.items.length === 2, list.j?.counts);
  ok('list: category filter', (await api(niraj, 'GET', '/catalogue?category=Snacks')).j.total_matching === 1);
  ok('list: bad filter 400', (await api(niraj, 'GET', '/catalogue?status=zomato')).s === 400);
  ok('list: bad page 400', (await api(niraj, 'GET', '/catalogue?page=0')).s === 400);
  ok('search by barcode', (await api(niraj, 'GET', '/catalogue/search?q=VINII-OAT-200')).j.items[0]?.sku === 'OC-200-PK');
  ok('search by name', (await api(niraj, 'GET', '/catalogue/search?q=coca')).j.items.length === 1);
  ok('lookup by SKU', (await api(niraj, 'GET', '/catalogue/lookup?code=cc500')).j.name === 'Coca-Cola 500ml');
  ok('lookup of an unknown code 404', (await api(niraj, 'GET', '/catalogue/lookup?code=NOPE-1')).s === 404);
  ok('get one by id; a bad id 404', (await api(niraj, 'GET', `/catalogue/${q1.j.id}`)).j.sku === 'CC500' && (await api(niraj, 'GET', '/catalogue/not-an-id')).s === 404);
  // tenancy
  ok('org B: empty catalogue', (await api(omar, 'GET', '/catalogue')).j.counts.total === 0);
  ok('org B: cannot read, change or look up org A items', (await api(omar, 'GET', `/catalogue/${q1.j.id}`)).s === 404 && (await api(omar, 'PUT', `/catalogue/${q1.j.id}`, { version: 1, name: 'Hacked' })).s === 404 && (await api(omar, 'GET', '/catalogue/lookup?code=CC500')).s === 404);
  ok('org B may use the same SKU in its own business', (await api(omar, 'POST', '/catalogue', { mode: 'quick', name: 'B Cola', sku: 'CC500', price_minor: 100 })).s === 200);

  // ---------------------------------------------------------------- GRN on a section H receipt
  const cola = q1.j.inventory_item_id;
  const r1 = await inv(niraj, 'inv_document_save', { doc_type: 'receipt', idempotency_key: k(), supplier_name: 'Coca-Cola Bottling', po_ref: 'PO-105',
    lines: [{ inventory_item_id: cola, qty: 24, rejected_qty: 2, reject_reason: 'Seal broken', lot_code: 'CC-C', expiry_date: '2027-11-15' }] });
  ok('H: receipt draft created', r1.s === 200 && r1.j.doc_type === 'receipt', r1);
  const rid = r1.j.id;
  ok('GRN open refused while the receipt is a draft 409', (await api(niraj, 'POST', '/grn/open', { receipt_document_id: rid })).s === 409);
  const sub = await inv(niraj, 'inv_document_act', { id: rid, action: 'submit', version: r1.j.version });
  ok('H: receipt sent to GRN review', sub.s === 200 && sub.j.status === 'review', sub);
  const op = await api(niraj, 'POST', '/grn/open', { receipt_document_id: rid });
  ok('GRN opened: GRN-001, matching', op.s === 200 && op.j.grn_no === 'GRN-001' && op.j.status === 'matching', op);
  const gate = await inv(niraj, 'inv_document_act', { id: rid, action: 'post', version: sub.j.version });
  ok('H post is blocked before approval (GRN_NOT_APPROVED)', gate.s >= 400 && /GRN_NOT_APPROVED/.test(JSON.stringify(gate.j)), gate);
  const inb = await api(niraj, 'PUT', `/grn/${rid}/invoice`, { supplier_name: 'Coca-Cola Bottling', invoice_no: 'INV-5512', invoice_date: '2026-10-10', po_ref: 'PO-105', lines: [{ inventory_item_id: cola, product_name: 'Coca-Cola 500ml', qty: 24, unit: 'units', unit_price_minor: 3000 }] });
  ok('invoice saved: 720 rupees billed, claim 60, one exception', inb.s === 200 && inb.j.totals.invoice_amount_minor === 72000 && inb.j.totals.claim_minor === 6000 && inb.j.totals.exceptions === 1, inb.j?.totals);
  ok('bad invoice date 400', (await api(niraj, 'PUT', `/grn/${rid}/invoice`, { supplier_name: 'X', invoice_no: '1', invoice_date: '10/10/2026', lines: [{ product_name: 'x', qty: 1, unit_price_minor: 1 }] })).s === 400);
  const mt = await api(niraj, 'GET', `/grn/${rid}/matching`);
  ok('matching screen: invoice line, one received row in state rejected', mt.s === 200 && mt.j.invoice_lines.length === 1 && mt.j.rows[0].state === 'rejected' && mt.j.exceptions === 1, mt.j);
  const early = await api(niraj, 'POST', `/grn/${rid}/request-approval`, { version: inb.j.version });
  ok('request approval before resolving 422 unresolved', early.s === 422 && early.j.code === 'unresolved', early);
  ok('claim without a reference 400', (await api(niraj, 'POST', `/grn/${rid}/resolve`, { version: inb.j.version, resolution: 'accept_claim_credit', evidence: 'Seal inspection' })).s === 400);
  ok('resolve with a stale version 409', (await api(niraj, 'POST', `/grn/${rid}/resolve`, { version: 99, resolution: 'accept_as_received', note: 'waive' })).s === 409);
  const rs = await api(niraj, 'POST', `/grn/${rid}/resolve`, { version: inb.j.version, resolution: 'accept_claim_credit', claim_ref: 'CLM-105', evidence: 'Seal inspection, 2 photos' });
  ok('resolved with claim CLM-105 for 60 rupees; can request approval', rs.s === 200 && rs.j.resolution.claim_minor === 6000 && rs.j.actions.can_request === true, rs.j?.resolution);
  const rq = await api(niraj, 'POST', `/grn/${rid}/request-approval`, { version: rs.j.version });
  ok('approval requested', rq.s === 200 && rq.j.status === 'approval_due', rq);
  ok('Niraj cannot approve (403)', (await api(niraj, 'POST', `/grn/${rid}/decide`, { version: rq.j.version, decision: 'approve' })).s === 403);
  const bk = await api(rohan, 'POST', `/grn/${rid}/decide`, { version: rq.j.version, decision: 'reject' });
  ok('send back needs a reason 400', bk.s === 400);
  const bk2 = await api(rohan, 'POST', `/grn/${rid}/decide`, { version: rq.j.version, decision: 'reject', note: 'Attach the credit note' });
  ok('sent back to matching', bk2.s === 200 && bk2.j.status === 'matching', bk2);
  const rq2 = await api(niraj, 'POST', `/grn/${rid}/request-approval`, { version: bk2.j.version });
  ok('asked again', rq2.s === 200 && rq2.j.status === 'approval_due', rq2);
  ok('stale approval 409', (await api(rohan, 'POST', `/grn/${rid}/decide`, { version: 1, decision: 'approve' })).s === 409);
  const ap = await api(rohan, 'POST', `/grn/${rid}/decide`, { version: rq2.j.version, decision: 'approve' });
  ok('approved by the owner; receipt posted through H', ap.s === 200 && ap.j.status === 'approved' && ap.j.posting_status === 'posted', ap);
  ok('stock rose by the 22 accepted units, visible in the catalogue', (await api(niraj, 'GET', `/catalogue/${q1.j.id}`)).j.stock_qty === 22);
  ok('approving twice 409', (await api(rohan, 'POST', `/grn/${rid}/decide`, { version: ap.j.version, decision: 'approve' })).s === 409);
  const lst = await api(niraj, 'GET', '/grn');
  ok('queue shows the approved GRN', lst.s === 200 && lst.j.items.some(i => i.receipt_document_id === rid && i.review_status === 'approved'), lst.j);
  // tenancy
  ok('org B cannot see the GRN (404) or its queue', (await api(omar, 'GET', `/grn/${rid}`)).s === 404 && (await api(omar, 'GET', `/grn/${rid}/matching`)).s === 404 && (await api(omar, 'GET', '/grn')).j.items.length === 0);
  ok('org B cannot open, resolve or decide on it', (await api(omar, 'POST', '/grn/open', { receipt_document_id: rid })).s === 404 && (await api(omar, 'POST', `/grn/${rid}/decide`, { version: 1, decision: 'approve' })).s === 404);
  ok('a bad receipt id 404', (await api(niraj, 'GET', '/grn/nope')).s === 404);
} catch (e) {
  fail++; console.log('FAIL (crash)', e?.message);
} finally {
  for (const id of users) { sql(`delete from org_users where user_id='${id}'`); sql(`delete from auth.users where id='${id}'`); }
  // dev cleanup of this script's two ZZ businesses only: append-only ledgers block a normal delete, so lift triggers for one transaction
  try {
    execSync(`docker exec -i supabase_db_onelocal-dev psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q`, { input: `begin; set local session_replication_role = replica;
      do $$ declare r record; begin
        for r in select c.table_name from information_schema.columns c join information_schema.tables t on t.table_schema=c.table_schema and t.table_name=c.table_name and t.table_type='BASE TABLE'
                 where c.table_schema='public' and c.column_name='organization_id' loop
          execute format('delete from public.%I where organization_id in (%L,%L)', r.table_name, '${orgA}', '${orgB}');
        end loop;
        delete from public.organizations where id in ('${orgA}','${orgB}');
      end $$; commit;`, encoding: 'utf8' });
  } catch (e) { console.log('cleanup failed:', String(e.message).slice(0, 200)); }
  console.log('leftover test businesses: ' + sql(`select count(*) from organizations where id in ('${orgA}','${orgB}')`));
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
