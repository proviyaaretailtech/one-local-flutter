// E2E: multi-outlet (migrations 0520-0522) over HTTP against the POS server's one generic endpoint (POST /rpc/outlet_*), as real signed-in
// people of two businesses: A's owner lists, toggles and adds an outlet; A's branch manager sees only the branch; B's owner cannot see or toggle
// anything of A; Master Admin's decide (database function, as the server would call it) opens the new outlet.
// LOCAL ONLY. Creates two ZZ businesses and removes them, their users and their rows at the end.
// Usage (from new-mobile-flutter/server, server running):  node scripts/outlets-e2e.mjs   (POS_API overrides the address; OL_ENV the env file; keys never printed)
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
const orgA = randomUUID(), orgB = randomUUID(), branch = randomUUID();
const users = [];
async function login(tag) {
  const email = `zz-outlets-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  users.push(c.id);
  const t = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return { id: c.id, email, token: t.access_token };
}
async function staff(org, role, tag, loc = null) {
  const u = await login(tag);
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status,location_id) values ('${org}','${u.id}',(select id from roles where slug='${role}'),'${u.email}','ZZ ${tag}','active',${loc ? `'${loc}'` : 'null'})`);
  return u.token;
}
async function rpc(token, alias, args = {}, key) {
  const headers = { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) };
  const r = await fetch(`${API}/rpc/${alias}`, { method: 'POST', headers, body: JSON.stringify(args) });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}
const form = name => ({ name, address_line: '21 Barshi Road, near bus stand', locality: 'Barshi Road', city: 'Latur', pin_code: '413512', lat: 18.41, lng: 76.57,
  hours: { opens: '09:00', closes: '23:00', days: ['mon', 'tue', 'wed'] }, fssai: '12345678901234' });

try {
  if (sql(`select to_regprocedure('public.outlet_list(jsonb)') is not null`) !== 't') throw new Error('0520-0522 are not installed on this database');
  sql(`insert into organizations(id,name,slug,type,business_domain,control_status,gstin) values ('${orgA}','Golden ZZ Outlets A ${run}','zz-outlets-a-${run}','franchise','Restaurant','Approved','27ABCDE1234F1Z5'),('${orgB}','Golden ZZ Outlets B ${run}','zz-outlets-b-${run}','franchise','Restaurant','Approved',null)`);
  sql(`insert into locations(id,organization_id,name,code,status,area) values ('${branch}','${orgA}','ZZ A Ausa Road ${run}','BR2','active','Ausa Road')`);
  sql(`insert into ol_merchant_channels(organization_id,accepting) values ('${orgA}',true),('${orgB}',true)`);
  const owner = await staff(orgA, 'org_owner', 'owner-a'), mgr = await staff(orgA, 'location_manager', 'mgr-a', branch), other = await staff(orgB, 'org_owner', 'owner-b');
  const staffUser = await login('platform');
  sql(`insert into platform_admins(user_id,status) values ('${staffUser.id}','Active')`);

  ok('outlets need a sign-in', (await rpc(null, 'outlet_list')).s === 401);
  const l = await rpc(owner, 'outlet_list');
  ok('owner: both outlets, main first, online, chip 1 of 2', l.s === 200 && l.j.outlets.length === 2 && l.j.current.code === 'MAIN' && l.j.current.status === 'online' && l.j.summary.chip === '1 of 2 online', l.j);
  ok('a bad location id is refused by the gateway (400)', (await rpc(owner, 'outlet_list', { location_id: 'nope' })).s === 400);
  ok('nothing to change 400', (await rpc(owner, 'outlet_set_channel', { location_id: branch })).s === 400);
  const on = await rpc(owner, 'outlet_set_channel', { location_id: branch, accepting: true });
  ok('owner switches the branch on -> All online', on.s === 200 && on.j.outlet.status === 'online' && (await rpc(owner, 'outlet_list')).j.summary.chip === 'All online', on);
  const rush = await rpc(mgr, 'outlet_set_channel', { location_id: branch, rush_mode: true, rush_extra_minutes: 20 });
  ok('branch manager turns rush mode on for the branch', rush.s === 200 && rush.j.outlet.status_label === 'Online · Rush' && rush.j.outlet.rush_extra_minutes === 20, rush);
  const ml = await rpc(mgr, 'outlet_list');
  ok('branch manager sees only the branch', ml.s === 200 && ml.j.outlets.length === 1 && ml.j.outlets[0].id === branch && ml.j.can_add === false, ml.j);
  const main = l.j.current.id;
  ok('branch manager cannot touch main (404)', (await rpc(mgr, 'outlet_set_channel', { location_id: main, accepting: false })).s === 404);

  // cross-tenant
  const bl = await rpc(other, 'outlet_list', { q: 'ZZ A' });
  ok('B sees none of A\'s outlets', bl.s === 200 && bl.j.outlets.length === 0 && !JSON.stringify(bl.j).includes(orgA), bl.j);
  ok('B asking for A\'s branch gets its own outlet as current', (await rpc(other, 'outlet_list', { location_id: branch })).j.current.id !== branch);
  ok('B cannot switch A\'s branch off (404)', (await rpc(other, 'outlet_set_channel', { location_id: branch, accepting: false })).s === 404);
  ok('A\'s branch is still on', sql(`select accepting from outlet_channels where location_id='${branch}'`) === 't');

  // add an outlet, Master Admin approves it
  const key = `e2e-${randomUUID()}`;
  const add = await rpc(owner, 'outlet_add', form(`ZZ A Barshi ${run}`), key);
  ok('owner adds an outlet: pending, toggles off', add.s === 200 && add.j.outlet.verification === 'pending' && add.j.outlet.can_toggle === false && /^OLO-/.test(add.j.reference), add);
  const again = await rpc(owner, 'outlet_add', form(`ZZ A Barshi ${run}`), key);
  ok('same form with the same Idempotency-Key: same outlet, replayed', again.s === 200 && again.j.outlet.id === add.j.outlet.id && again.j.replayed === true, again);
  ok('a pending outlet cannot be switched on (409)', (await rpc(owner, 'outlet_set_channel', { location_id: add.j.outlet.id, accepting: true })).s === 409);
  ok('the branch manager cannot add outlets (403)', (await rpc(mgr, 'outlet_add', form('ZZ manager'), `e2e-${randomUUID()}`)).s === 403);
  ok('missing FSSAI for a restaurant 422 (still missing)', (await rpc(owner, 'outlet_add', { ...form('ZZ no fssai'), fssai: null }, `e2e-${randomUUID()}`)).s === 422);
  ok('B cannot see A\'s new outlet', !(await rpc(other, 'outlet_list')).j.outlets.some(o => o.id === add.j.outlet.id));
  const dec = JSON.parse(sql(`select public.master_partner_application_decide('${add.j.application_id}','approve',null,'${staffUser.id}')`));
  ok('Master Admin approves through the partner decide path', dec.kind === 'outlet' && dec.status === 'approved', dec);
  const on2 = await rpc(owner, 'outlet_set_channel', { location_id: add.j.outlet.id, accepting: true });
  ok('after approval the owner switches it on', on2.s === 200 && on2.j.outlet.status === 'online', on2);

  // drafts, the state rule and the inter-state outlet admin (0523)
  const g0 = await rpc(owner, 'outlet_draft_get');
  ok('draft start: no draft, home state Maharashtra, state list', g0.s === 200 && g0.j.draft === null && g0.j.home_state_name === 'Maharashtra' && g0.j.states.length === 36, g0.j);
  const dk = `e2e-${randomUUID()}`;
  const d1 = await rpc(owner, 'outlet_draft_save', { state_code: '29', step: 'details' }, dk);
  ok('Karnataka is inter-state; the draft keeps its step', d1.s === 200 && d1.j.draft.inter_state === true && d1.j.draft.step === 'details', d1);
  const did = d1.j.draft.id;
  ok('saving the first step again with the same key finds the same draft', (await rpc(owner, 'outlet_draft_save', { state_code: '29', step: 'details' }, dk)).j.draft.id === did);
  ok('B cannot open A\'s draft (404)', (await rpc(other, 'outlet_draft_get', { id: did })).s === 404 && (await rpc(other, 'outlet_draft_save', { id: did, name: 'x' })).s === 404);
  ok('the branch manager cannot use drafts (403)', (await rpc(mgr, 'outlet_draft_get')).s === 403);
  ok('a GSTIN of the wrong state is refused (400)', (await rpc(owner, 'outlet_draft_save', { id: did, gstin: '27ABCDE1234F1Z5' })).s === 400);
  await rpc(owner, 'outlet_draft_save', { id: did, name: `ZZ A Indiranagar ${run}`, address_line: '5 100 Feet Road', locality: 'Indiranagar', pin_code: '560038', lat: 12.97, lng: 77.64,
    hours: { opens: '09:00', closes: '23:00', days: ['mon'] }, fssai: '12345678901234', gstin: '29ABCDE1234F1Z5', step: 'contact' });
  ok('incomplete: the contact is still missing (422)', (await rpc(owner, 'outlet_draft_submit', { id: did })).s === 422);
  ok('owner comes back to the same step', (await rpc(owner, 'outlet_draft_get')).j.draft.step === 'contact');
  const cmail = `zz-outlet-admin-${run}@example.test`;
  await rpc(owner, 'outlet_draft_save', { id: did, contact_name: 'Ravi Kumar', contact_mobile: '9845012345', contact_email: cmail, step: 'review' });
  const sub = await rpc(owner, 'outlet_draft_submit', { id: did });
  ok('inter-state outlet submitted as pending with its own GSTIN', sub.s === 200 && sub.j.outlet.verification === 'pending'
    && sql(`select gstin from locations where id='${sub.j.outlet.id}'`) === '29ABCDE1234F1Z5', sub);
  const dec2 = JSON.parse(sql(`select public.master_partner_application_decide('${sub.j.application_id}','approve',null,'${staffUser.id}')`));
  ok('approval invites the contact as outlet admin of that outlet', dec2.outlet_admin === 'invited'
    && sql(`select r.slug||':'||i.location_id from org_invitations i join roles r on r.id=i.role_id where i.id='${dec2.invitation_id}'`) === `outlet_admin:${sub.j.outlet.id}`, dec2);

  // the restaurant home for all outlets (0524)
  const all = await rpc(owner, 'rst_dashboard_scope', { location_id: 'all' });
  ok('all outlets: one summed dashboard over the 4 active outlets (main, branch, two approved)', all.s === 200 && all.j.scope === 'all' && all.j.outlet_count === 4 && /^All outlets \(4\)$/.test(all.j.location.name), all.j?.location);
  ok('a bad scope value is refused by the gateway (400)', (await rpc(owner, 'rst_dashboard_scope', { location_id: 'everything' })).s === 400);
  ok('B\'s all-outlets home has none of A', (await rpc(other, 'rst_dashboard_scope', { location_id: 'all' })).j.outlet_count === 1);
} catch (e) {
  fail++; console.log('FAIL (crash)', e?.message);
} finally {
  for (const id of users) { sql(`delete from platform_admins where user_id='${id}'`); sql(`delete from org_users where user_id='${id}'`); sql(`delete from auth.users where id='${id}'`); }
  // dev cleanup of this script's two ZZ businesses only (locations and outlet rows carry organization_id, so they go too)
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
  console.log('leftover test rows: ' + sql(`select (select count(*) from organizations where id in ('${orgA}','${orgB}')) + (select count(*) from locations where organization_id in ('${orgA}','${orgB}'))`));
}
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
