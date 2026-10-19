// E2E: the restaurant Menu and Dish detail over HTTP against the POS server's one endpoint (POST /rpc/<alias>: rst_menu*, menu_ai_describe),
// as real signed-in staff of two businesses. LOCAL ONLY. Creates two ZZ restaurants and removes them, their users and their rows at the end.
// Two servers are used so Write with AI is checked without the real Claude API:
//   POS_API     (default http://localhost:8090)  started WITHOUT ANTHROPIC_API_KEY  -> 503 ai_not_configured
//   POS_API_AI  (optional)                        started with ANTHROPIC_API_KEY=<any> and ANTHROPIC_BASE_URL=http://127.0.0.1:9 (nothing listens):
//               the database gate (who, which dish, rate limit) runs, then the call fails locally -> 502 ai_failed. No request leaves the machine.
// Usage (from new-mobile-flutter/server):  POS_API=http://localhost:8154 POS_API_AI=http://localhost:8155 node scripts/menu-e2e.mjs
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const API = (process.env.POS_API ?? 'http://localhost:8090').replace(/\/+$/, '');
const API_AI = process.env.POS_API_AI?.replace(/\/+$/, '') || null;
const env = Object.fromEntries(readFileSync(process.env.OL_ENV ?? '.env', 'utf8').split('\n').filter(l => /^[A-Z_]+=/.test(l)).map(l => [l.split('=')[0], l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '')]));
const local = u => /^http:\/\/(127\.0\.0\.1|localhost):/.test(u);
if (!local(env.SUPABASE_URL) || !local(API) || (API_AI && !local(API_AI))) throw new Error('local only');
const U = env.SUPABASE_URL, ANON = env.SUPABASE_ANON_KEY || env.SUPABASE_PUBLISHABLE_KEY, SRV = env.SUPABASE_SERVICE_ROLE_KEY;
const sql = q => execSync(`docker exec supabase_db_onelocal-dev psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt -c "${q.replace(/"/g, '\\"')}"`, { encoding: 'utf8' }).trim();
let pass = 0, fail = 0;
const ok = (n, c, d) => { if (c) { pass++; console.log('ok  ', n); } else { fail++; console.log('FAIL', n, d === undefined ? '' : JSON.stringify(d).slice(0, 400)); } };

const run = Date.now().toString(36);
const orgA = randomUUID(), orgB = randomUUID(), catA = randomUUID(), d1 = randomUUID(), d2 = randomUUID(), dB = randomUUID();
const users = [];
async function staff(org, role, tag) {
  const email = `zz-menu-${tag}-${run}@example.test`, pw = `Zz-${randomUUID()}Aa1!`;
  const c = await fetch(`${U}/auth/v1/admin/users`, { method: 'POST', headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw, email_confirm: true }) }).then(r => r.json());
  users.push(c.id);
  sql(`insert into org_users(organization_id,user_id,role_id,email,full_name,status) values ('${org}','${c.id}',(select id from roles where slug='${role}'),'${email}','ZZ ${tag}','active')`);
  const login = await fetch(`${U}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: pw }) }).then(r => r.json());
  return login.access_token;
}
async function rpc(token, alias, args = {}, base = API) {
  const r = await fetch(`${base}/rpc/${alias}`, { method: 'POST', headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
  const t = await r.text();
  let j = null; try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t.slice(0, 200) }; }
  return { s: r.status, j };
}

try {
  sql(`insert into organizations(id,name,slug,type,business_domain) values ('${orgA}','Golden ZZ Menu A ${run}','zz-menu-a-${run}','franchise','Restaurant'),('${orgB}','Golden ZZ Menu B ${run}','zz-menu-b-${run}','franchise','Restaurant')`);
  sql(`update locations set timezone='Asia/Kolkata' where organization_id in ('${orgA}','${orgB}')`);
  sql(`insert into menu_categories(id,organization_id,name,sort_order) values ('${catA}','${orgA}','Hot Cafe',1)`);
  sql(`insert into menu_items(id,organization_id,category_id,name,price,description) values ('${d1}','${orgA}','${catA}','Americano (Large)',125,'Coffee shot with hot water'),('${d2}','${orgA}','${catA}','Cappuccino',139,null),('${dB}','${orgB}',null,'B dish',99,'B only')`);
  const owner = await staff(orgA, 'org_owner', 'owner'), biller = await staff(orgA, 'biller', 'biller'), omar = await staff(orgB, 'org_owner', 'omar');

  ok('menu needs a sign-in', (await rpc(null, 'rst_menu')).s === 401);
  const m = await rpc(owner, 'rst_menu');
  ok('menu: 2 dishes, Hot Cafe (2) all in stock, 2 need an image, editable', m.s === 200 && m.j.counts.total === 2 && m.j.categories[0].name === 'Hot Cafe' && m.j.categories[0].count === 2 && m.j.categories[0].all_in_stock && m.j.counts.needs_image === 2 && m.j.can_edit, m.j);
  ok('menu: bad filter 400 at the gateway', (await rpc(owner, 'rst_menu', { filter: 'drafts' })).s === 400);
  const v = await rpc(owner, 'rst_menu_item_view', { id: d1 });
  ok('dish view: version, no windows, channels coming soon', v.s === 200 && typeof v.j.version === 'number' && v.j.availability.length === 0 && v.j.channels.status === 'coming_soon', v.j);
  const s1 = await rpc(owner, 'rst_menu_item_save', { id: d1, version: v.j.version, description: 'Bold espresso topped with hot water.', availability: [{ slot: 'morning' }, { slot: 'custom', starts_at: '22:00', ends_at: '02:00' }] });
  ok('save: description and two windows', s1.s === 200 && s1.j.description === 'Bold espresso topped with hot water.' && s1.j.availability.length === 2, s1.j);
  ok('save with the old version: 409 version_conflict', (await rpc(owner, 'rst_menu_item_save', { id: d1, version: v.j.version, description: 'x' })).j?.code === 'version_conflict');
  ok('unknown field 400 (no mass assignment)', (await rpc(owner, 'rst_menu_item_save', { id: d1, version: s1.j.version, organization_id: orgB })).s === 400);
  ok('afternoon is not a preset: 400', (await rpc(owner, 'rst_menu_item_save', { id: d1, version: s1.j.version, availability: [{ slot: 'afternoon' }] })).s === 400);
  const off = await rpc(owner, 'rst_menu_stock_set', { id: d2, in_stock: false });
  ok('switch a dish off; the category is no longer all in stock', off.s === 200 && off.j.updated === 1 && (await rpc(owner, 'rst_menu')).j.categories[0].all_in_stock === false, off.j);
  ok('category all in stock back on', (await rpc(owner, 'rst_menu_stock_set', { category_id: catA, in_stock: true })).j.updated === 1);

  // roles
  ok('a biller reads the menu but cannot save or switch', (await rpc(biller, 'rst_menu')).j.can_edit === false
    && (await rpc(biller, 'rst_menu_item_save', { id: d1, version: s1.j.version, description: 'x' })).s === 403 && (await rpc(biller, 'rst_menu_stock_set', { id: d1, in_stock: false })).s === 403);

  // tenancy
  ok('org B sees only its own dish', (await rpc(omar, 'rst_menu')).j.counts.total === 1);
  ok('org B cannot open, save or switch A\'s dish, or A\'s category', (await rpc(omar, 'rst_menu_item_view', { id: d1 })).s === 404
    && (await rpc(omar, 'rst_menu_item_save', { id: d1, version: s1.j.version, description: 'hacked' })).s === 404
    && (await rpc(omar, 'rst_menu_stock_set', { id: d1, in_stock: false })).s === 404 && (await rpc(omar, 'rst_menu_stock_set', { category_id: catA, in_stock: false })).s === 404);
  ok('A\'s dish unchanged by B', sql(`select description||':'||is_available from menu_items where id='${d1}'`) === 'Bold espresso topped with hot water.:true');

  // Write with AI on the server without a key
  const nk = await rpc(owner, 'menu_ai_describe', { item_id: d1, notes: 'coffee shot, hot water' });
  ok('AI not configured: 503 "AI writing is not set up yet", no quota spent', nk.s === 503 && nk.j.code === 'ai_not_configured' && nk.j.detail === 'AI writing is not set up yet.'
    && sql(`select count(*) from menu_ai_requests where organization_id='${orgA}'`) === '0', nk);
  ok('AI: dish facts cannot be sent from the phone (400)', (await rpc(owner, 'menu_ai_describe', { item_id: d1, dish: { name: 'x' } })).s === 400);

  if (API_AI) {
    ok('AI: org B cannot run it on A\'s dish (404), no quota of A spent', (await rpc(omar, 'menu_ai_describe', { item_id: d1 }, API_AI)).s === 404
      && sql(`select count(*) from menu_ai_requests where organization_id='${orgA}'`) === '0');
    ok('AI: a biller cannot use it (403)', (await rpc(biller, 'menu_ai_describe', { item_id: d1 }, API_AI)).s === 403);
    const f = await rpc(owner, 'menu_ai_describe', { item_id: d1, notes: 'coffee shot, hot water' }, API_AI);
    ok('AI: gate passed, the (unreachable) model fails as 502 ai_failed, recorded as failed with sizes only', f.s === 502 && f.j.code === 'ai_failed'
      && sql(`select status||':'||input_chars from menu_ai_requests where organization_id='${orgA}'`) === 'failed:22', f);
    sql(`insert into menu_ai_requests(organization_id,menu_item_id,requested_by,status) select '${orgA}','${d1}','${users[0]}','ok' from generate_series(1,19)`);
    const rl = await rpc(owner, 'menu_ai_describe', { item_id: d1 }, API_AI);
    ok('AI: 21st request in the hour for business A is 429 rate_limited', rl.s === 429 && rl.j.code === 'rate_limited', rl);
    const bOk = await rpc(omar, 'menu_ai_describe', { item_id: dB }, API_AI);
    ok('AI: business B has its own quota (gate passes, 502 from the unreachable model)', bOk.s === 502, bOk);
  } else console.log('skip  AI gate checks (set POS_API_AI to a server started with a dummy key and ANTHROPIC_BASE_URL=http://127.0.0.1:9)');
} catch (e) {
  fail++; console.log('FAIL (crash)', e?.message);
} finally {
  for (const id of users) { sql(`delete from org_users where user_id='${id}'`); sql(`delete from auth.users where id='${id}'`); }
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
