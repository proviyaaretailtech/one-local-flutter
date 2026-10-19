// Audit of every database function the gateway manifest can call, against the LOCAL database. Prints security type, search_path and
// grants; exits 1 on: function missing, anon (or PUBLIC) can execute, SECURITY DEFINER without a pinned search_path, authenticated
// cannot execute it, a body that creates temp tables, or a definer body that never looks at the caller (auth.uid / current_org_id /
// has_permission / has_org_role / location_is_allowed / gw__uid, directly or through a wrapper's callee). Local only.
// Usage: node scripts/manifest-audit.mjs
import { execFileSync } from 'node:child_process';
import { dbFunctions, MANIFEST } from '../src/rpc-manifest.ts';
import { guestFunctions } from '../src/guest-door.ts';

const psql = q => execFileSync('docker', ['exec', 'supabase_db_onelocal-dev', 'psql', '-U', 'postgres', '-d', 'postgres', '-At', '-F', '\t', '-c', q], { encoding: 'utf8' }).trim();
const CALLER = /auth\.uid\(\)|current_org_id\(\)|has_permission\(|has_org_role\(|location_is_allowed\(|gw__uid\(\)|pos_order_view\(/;
let bad = 0;
const rows = [];
for (const fn of dbFunctions()) {
  const head = psql(`select p.oid::regprocedure::text||E'\\t'||p.prosecdef||E'\\t'||coalesce((select c from unnest(p.proconfig) c where c like 'search_path=%'),'')||E'\\t'||has_function_privilege('anon',p.oid,'execute')||E'\\t'||has_function_privilege('authenticated',p.oid,'execute')||E'\\t'||exists(select 1 from aclexplode(coalesce(p.proacl, acldefault('f',p.proowner))) a where a.grantee=0 and a.privilege_type='EXECUTE')||E'\\t'||(p.prosrc ~* 'create\\s+(local\\s+|global\\s+)?temp(orary)?\\s+table')||E'\\t'||(p.prosrc ~ '(auth\\.uid\\(\\)|current_org_id\\(\\)|has_permission\\(|has_org_role\\(|location_is_allowed\\(|gw__uid\\(\\)|pos_order_view\\()') from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='${fn}'`);
  for (const line of head.split('\n')) {
    if (!line) { rows.push({ fn, problem: 'MISSING in database' }); bad++; continue; }
    const [sig, definer, sp, anon, authd, pub, temp, looks] = line.split('\t');
    const problems = [];
    if (anon === 'true') problems.push('ANON CAN EXECUTE');
    if (pub === 'true') problems.push('PUBLIC CAN EXECUTE');
    if (definer === 'true' && !sp) problems.push('DEFINER WITHOUT PINNED search_path');
    if (authd !== 'true') problems.push('authenticated cannot execute');
    if (temp === 'true') problems.push('creates a temp table');
    if (definer === 'true' && looks !== 'true') problems.push('definer body does not look at the caller (check by hand)');
    rows.push({ fn: sig, type: definer === 'true' ? 'DEFINER' : 'invoker', search_path: sp.replace('search_path=', '') || '-', anon, authenticated: authd, public: pub, caller_check: looks, problem: problems.join('; ') || 'ok' });
    if (problems.length) bad++;
  }
}
// The guest door (src/guest-door.ts) calls its functions with the service role, so the rule is the opposite: NO anon, NO authenticated,
// service_role yes, a pinned definer, and a body that checks the guest's code or session (qr_token / guest__session).
for (const fn of guestFunctions()) {
  const line = psql(`select p.oid::regprocedure::text||E'\\t'||p.prosecdef||E'\\t'||coalesce((select c from unnest(p.proconfig) c where c like 'search_path=%'),'')||E'\\t'||has_function_privilege('anon',p.oid,'execute')||E'\\t'||has_function_privilege('authenticated',p.oid,'execute')||E'\\t'||has_function_privilege('service_role',p.oid,'execute')||E'\\t'||exists(select 1 from aclexplode(coalesce(p.proacl, acldefault('f',p.proowner))) a where a.grantee=0 and a.privilege_type='EXECUTE')||E'\\t'||(p.prosrc ~ '(guest__session\\(|qr_token)') from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='${fn}'`);
  if (!line) { rows.push({ fn, problem: 'MISSING in database (guest door)' }); bad++; continue; }
  const [sig, definer, sp, anon, authd, srv, pub, looks] = line.split('\t');
  const problems = [];
  if (anon === 'true') problems.push('ANON CAN EXECUTE');
  if (pub === 'true') problems.push('PUBLIC CAN EXECUTE');
  if (authd === 'true') problems.push('AUTHENTICATED CAN EXECUTE (guest door is service_role only)');
  if (srv !== 'true') problems.push('service_role cannot execute');
  if (definer === 'true' && !sp) problems.push('DEFINER WITHOUT PINNED search_path');
  if (looks !== 'true') problems.push('body does not check the code or session');
  rows.push({ fn: `${sig} [guest door]`, type: definer === 'true' ? 'DEFINER' : 'invoker', search_path: sp.replace('search_path=', '') || '-', anon, authenticated: authd, public: pub, caller_check: looks, problem: problems.join('; ') || 'ok' });
  if (problems.length) bad++;
}
console.table(rows);
const secure = MANIFEST.filter(e => e.kind === 'secure').map(e => e.alias);
console.log(`manifest: ${MANIFEST.length} entries; ${dbFunctions().length} database functions; secure handlers: ${secure.join(', ')}`);
console.log(bad ? `FAIL: ${bad} problem(s)` : 'PASS: no anon grant, no unpinned definer');
process.exit(bad ? 1 : 0);
