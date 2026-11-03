// E2E: Delete account and the business day (Day close), the SQL copied from hosted (migration 0651), over HTTP against the standalone POS
// server, as real signed-in people. Delete account: the preview (memberships, the businesses only this person owns), the request with the
// typed DELETE (a retry gets the same request), signing in again cancels it, and the nightly purge after 30 days removes the login and
// the person's details but keeps the business's records. Day close: the day starts on first use, the opening cash, the count, the
// manager's close, and the internal helpers cannot be called directly. LOCAL ONLY.
// Usage (from one-local-flutter/server, server running):  node scripts/account-delete-day-close-e2e.mjs   (POS_API, OL_DB, OL_ENV as before)
import { readFileSync } from 'node:fs';
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

const run = Date.now().toString(36);
const org = randomUUID();
async function person(role, tag) {
  const email = `zz-acct-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const signIn = async () => (await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json()));
  return { token: (await signIn()).access_token, id: c.id, email, signIn };
}
async function rpc(who, fn, body = {}, key) {
  const r = await fetch(`${API}/rpc/${fn}`, { method: 'POST', headers: { ...(who ? { Authorization: `Bearer ${who.token}` } : {}), 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) }, body: JSON.stringify(body) });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const k = () => `e2e-${randomUUID()}`;

try {
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${org}','Golden ZZ ACCT ${run}','zz-acct-${run}','franchise','Grocery')`);
  const OWN = await person('org_owner', 'own'), MGR = await person('manager', 'mgr'), BIL = await person('biller', 'bil');
  ok('an owner, a manager and a biller signed in', [OWN, MGR, BIL].every(x => x.token));

  // ---- Delete account
  let r = await rpc(MGR, 'acct_delete_preview');
  ok('Delete account opens (it said "Something went wrong"): 1 business, owns none alone, nothing pending', r.s === 200 && r.j.memberships === 1 && r.j.sole_owner_of.length === 0 && r.j.pending === null, r);
  r = await rpc(OWN, 'acct_delete_preview');
  ok('…the owner is warned they are the only owner of the business', r.s === 200 && r.j.sole_owner_of.includes(`Golden ZZ ACCT ${run}`), r);
  r = await rpc(MGR, 'acct_delete_request', { confirm: 'delete' });
  ok('…without the typed DELETE: refused', r.s === 400, r);
  r = await rpc(MGR, 'acct_delete_request', { confirm: 'DELETE', reason: 'Leaving the job' });
  const ref = r.j?.reference;
  ok('…with DELETE: asked, due in 30 days', r.s === 200 && /^AD-\d{6}-[A-Z0-9]{6}$/.test(ref ?? '') && r.j.replayed === false
    && Math.round((new Date(r.j.due_at) - Date.now()) / 86400000) === 30, r);
  r = await rpc(MGR, 'acct_delete_request', { confirm: 'DELETE' });
  ok('…asked again: the same request', r.s === 200 && r.j.reference === ref && r.j.replayed === true, r);
  r = await rpc(MGR, 'acct_delete_preview');
  ok('…the preview shows it pending', r.j?.pending?.reference === ref, r.j);
  r = await rpc(MGR, 'acct_delete_cancel');
  ok('signing in again cancels it (the app calls this after every sign-in)', r.s === 200 && r.j.cancelled === true && r.j.reference === ref, r);
  ok('…withdrawn, and in the audit', sql(`select status from ol_privacy_requests where reference='${ref}'`) === 'withdrawn'
    && sql(`select count(*) from audit_logs where actor_user_id='${MGR.id}' and action in ('account.delete_requested','account.delete_cancelled')`) === '2');
  r = await rpc(MGR, 'acct_delete_cancel');
  ok('…nothing pending: nothing to cancel', r.s === 200 && r.j.cancelled === false, r);

  // the purge after the grace: the biller asks, 30 days pass, the nightly job runs
  r = await rpc(BIL, 'acct_delete_request', { confirm: 'DELETE' });
  const ref2 = r.j?.reference;
  sql(`update ol_privacy_requests set due_at = now() - interval '1 minute' where reference='${ref2}'`);
  ok('the purge cannot be called from the app', (await rpc(BIL, 'acct_deletion_purge')).s === 404);
  const purged = JSON.parse(sql(`select public.acct_deletion_purge()`));
  ok('after 30 days the nightly purge deletes the account', purged.deleted >= 1 && purged.failed === 0, purged);
  ok('…the login is gone: no email, banned, no way in', sql(`select coalesce(email,'-')||'|'||(banned_until > now())::text||'|'||(deleted_at is not null)::text||'|'||(select count(*) from auth.identities where user_id='${BIL.id}') from auth.users where id='${BIL.id}'`) === '-|true|true|0');
  ok('…they are out of the business, their name and email scrubbed', sql(`select status||'|'||coalesce(full_name,'-')||'|'||(email like 'deleted-%@deleted.invalid')::text from org_users where user_id='${BIL.id}'`) === 'suspended|-|true');
  ok('…the request is completed', sql(`select status from ol_privacy_requests where reference='${ref2}'`) === 'completed');
  const again = await BIL.signIn();
  ok('…they cannot sign in again', !again.access_token, again && { error: again.error ?? again.msg });

  // ---- the business day (a biller who still has an account)
  const CASH = await person('biller', 'cash');
  r = await rpc(OWN, 'pos_day_today', { start: true, trigger: 'manual' });
  const day = r.j?.day;
  ok('Day close: the business day starts (the first one needs the opening cash)', r.s === 200 && day?.status === 'attention' && day.attention_reason === 'no_previous_closing' && r.j.can_manage === true, r);
  r = await rpc(CASH, 'pos_day_opening_set', { day_id: day?.id, amount: 500, reason: 'Float', expected_version: day?.version }, k());
  ok('…a biller sets the opening cash: waiting for a manager', r.s === 200 && r.j.pending === true && r.j.opening_cash === null, r);
  const adj = r.j?.adjustments?.find(a => a.approval_status === 'pending');
  r = await rpc(MGR, 'pos_day_adjustment_decide', { adjustment_id: adj?.id, decision: 'approve' });
  ok('…the manager approves it: ₹500, the day started', r.s === 200 && Number(r.j.opening_cash) === 500 && r.j.status === 'started', r);
  r = await rpc(OWN, 'pos_day_close', { day_id: day?.id, expected_version: r.j?.version }, k());
  ok('…closing before the cash is counted: refused, and says so', r.s >= 400 && /count the cash/i.test(JSON.stringify(r.j)), r);
  r = await rpc(CASH, 'pos_day_cash_count', { day_id: day?.id, counted_cash: 500 }, k());
  ok('…the cash counted: ₹500, matches', r.s === 200 && Number(r.j.counted_cash) === 500 && Number(r.j.variance) === 0, r);
  r = await rpc(CASH, 'pos_day_close', { day_id: day?.id, expected_version: r.j?.version }, k());
  ok('…a biller cannot close the day', r.s === 403, r);
  r = await rpc(MGR, 'pos_day_close', { day_id: day?.id, note: 'Good day' }, k());
  ok('…the manager closes it', r.s === 200 && r.j.status === 'closed' && r.j.close_note === 'Good day', r);
  r = await rpc(OWN, 'pos_day_list', {});
  ok('…it is in the list of days', r.s === 200 && Array.isArray(r.j) ? r.j.some(d => d.id === day?.id) : (r.j?.days ?? r.j ?? []).some?.(d => d.id === day?.id), r);

  // the internal helpers are not reachable: not through the server, not through the database's own door
  ok('the helpers are not on the server', (await rpc(OWN, 'pos_day__json', { p_day: day?.id })).s === 404);
  const direct = await fetch(`${U}/rest/v1/rpc/pos_day__json`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_day: day?.id }) });
  ok('…and someone not signed in cannot read a day through the database directly (0651)', direct.status === 401 || direct.status === 403 || direct.status === 404, { status: direct.status, body: (await direct.text()).slice(0, 200) });
} catch (e) {
  fail++; console.log('FAIL crashed', e.message);
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
