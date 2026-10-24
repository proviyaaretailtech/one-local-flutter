// Secret-bearing: Settings -> Integrations. Connects a business to Petpooja or GoFrugal and checks that connection.
//   connect: 1. the body is checked (strict: only the fields of that provider); 2. PARTNER_PII_KEY must be set (503 not_configured);
//            3. the caller may change integrations (pos_integrations_get AS THE CALLER says can_edit; the database decides) BEFORE any
//            provider is called, so this server is never a key-testing proxy for other staff; 4. one call to the provider with the keys;
//            5. only keys the provider accepted are saved: pos_integration_save (service role, the verified user id, the key) encrypts them
//            inside the database. The answer is the Integrations page; the keys never come back.
//   test:    the saved keys are decrypted in the database (pos_integration_secret, owner or manager), the provider is called once, and the
//            outcome is recorded (pos_integration_record_check). The answer is the page plus { check: { ok, message } }.
// Provider calls: Petpooja's fixed menu endpoint (PETPOOJA_MENU_URL overrides it) with the app-key / app-secret / access-token headers;
// GoFrugal at the store URL the business gives, so that call only goes to a PUBLIC address: every address the name resolves to is
// checked at connect time (no TOCTOU between the check and the connection), IP literals too, and redirects are not followed.
// Keys are never logged; only the provider and an HTTP status are.
import { lookup as dnsLookup, type LookupAddress } from 'node:dns';
import http from 'node:http';
import https from 'node:https';
import { BlockList, isIP } from 'node:net';
import { piiKey } from '../../config.ts';
import { mapDbError, rpc, userClient } from '../../db.ts';
import { HttpError } from '../../http.ts';
import { parse } from '../../validate.ts';
import { AnyProvider, GofrugalConnect, PetpoojaConnect, PROVIDER_NAME, storeUrl, Which, type Provider } from '../../schemas/integrations.ts';
import type { SecureCtx } from './index.ts';

export const PETPOOJA_MENU_URL = 'https://qle1yy2ydc.execute-api.ap-southeast-1.amazonaws.com/V1/mapped_restaurant_menus';
const TIMEOUT_MS = 20_000;
const MAX_BODY = 4 * 1024 * 1024;

type Fields = Record<string, unknown>;
export type Check = { ok: boolean; message: string; reason?: 'refused' | 'unreachable' | 'bad_address' | 'not_api' };
export type Deps = {
  key: () => string;
  canEdit: (request: Request) => Promise<boolean>;
  save: (userId: string, p: Fields, key: string) => Promise<unknown>;
  secret: (userId: string, p: Fields, key: string) => Promise<{ account?: Fields; credentials?: Fields }>;
  record: (userId: string, p: Fields) => Promise<unknown>;
  check: (provider: Provider, account: Fields, credentials: Fields) => Promise<Check>;
};

export const notConfigured = () => new HttpError(503, 'Saving integration keys is not available right now.', undefined, 'not_configured');

const ok = (message: string): Check => ({ ok: true, message });
const no = (reason: NonNullable<Check['reason']>, message: string): Check => ({ ok: false, reason, message });

/** A provider's own sentence, made safe to show and store: one line, no control characters, at most [max] characters. */
export function plain(v: unknown, max = 160): string {
  if (typeof v !== 'string') return '';
  const t = v.replace(/[\u0000-\u001f\u007f<>]+/g, ' ').replace(/\s+/g, ' ').trim();
  return t.length <= max ? t : `${t.slice(0, max - 1).trimEnd()}…`;
}

const s = (v: unknown) => (typeof v === 'string' ? v : '');
const hint = (k: string) => k.slice(-4);

// ---- Petpooja

export async function petpoojaCheck(account: Fields, credentials: Fields, call: typeof fetch = fetch, url = process.env.PETPOOJA_MENU_URL?.trim() || PETPOOJA_MENU_URL): Promise<Check> {
  let res: Response;
  try {
    res = await call(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json', 'app-key': s(credentials.app_key), 'app-secret': s(credentials.app_secret), 'access-token': s(credentials.access_token) },
      body: JSON.stringify({ restID: s(account.restaurant_id) }),
      redirect: 'manual',
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (e) {
    console.error('[integrations] petpooja call failed', e instanceof Error ? e.name : 'error');
    return no('unreachable', 'Petpooja did not answer. Try again in a few minutes.');
  }
  let json: any = null;
  try { json = await res.json(); } catch { /* an empty or non-JSON answer: decided by the status below */ }
  if (res.status === 401 || res.status === 403) return no('refused', 'Petpooja refused these keys. Check the app key, app secret and access token.');
  if (res.status !== 200 || !json || typeof json !== 'object') {
    console.error('[integrations] petpooja answered', res.status);
    return no('unreachable', 'Petpooja did not answer properly. Try again in a few minutes.');
  }
  if (String(json.success) !== '1') {
    const why = plain(json.message);
    return no('refused', why ? `Petpooja refused these details: ${why}` : 'Petpooja refused these details. Check the restaurant ID and keys.');
  }
  const name = plain(json.restaurants?.[0]?.details?.restaurantname ?? json.restaurants?.[0]?.restaurantname, 80);
  const items = Array.isArray(json.items) ? json.items.length : null;
  const where = name ? `Connected to ${name} on Petpooja.` : 'Connected to Petpooja.';
  return ok(items === null ? where : `${where} ${items} ${items === 1 ? 'item' : 'items'} on the menu.`);
}

// ---- GoFrugal (an address the business gives: public addresses only)

const v4Blocked = new BlockList();
for (const [net, bits] of [['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8], ['169.254.0.0', 16], ['172.16.0.0', 12], ['192.0.0.0', 24], ['192.0.2.0', 24],
  ['192.88.99.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15], ['198.51.100.0', 24], ['203.0.113.0', 24], ['224.0.0.0', 4], ['240.0.0.0', 4]] as const) v4Blocked.addSubnet(net, bits, 'ipv4');
const v6Blocked = new BlockList();
for (const [net, bits] of [['::', 128], ['::1', 128], ['100::', 64], ['2001:db8::', 32], ['fc00::', 7], ['fe80::', 10], ['fec0::', 10], ['ff00::', 8]] as const) v6Blocked.addSubnet(net, bits, 'ipv6');

/** "::ffff:7f00:1" -> [0,0,0,0,0,0xffff,0x7f00,1]; null when it is not an IPv6 address. */
function hextets(ip: string): number[] | null {
  if (isIP(ip) !== 6) return null;
  let a = ip.split('%')[0];
  const dotted = a.match(/(\d+\.\d+\.\d+\.\d+)$/);
  if (dotted) {
    const [p, q, r, t] = dotted[1].split('.').map(Number);
    a = a.slice(0, -dotted[1].length) + `${((p << 8) | q).toString(16)}:${((r << 8) | t).toString(16)}`;
  }
  const [head, tail] = a.includes('::') ? a.split('::') : [a, null];
  const h = head ? head.split(':') : [];
  const t = tail === null ? [] : tail ? tail.split(':') : [];
  const fill = tail === null ? [] : Array(8 - h.length - t.length).fill('0');
  const all = [...h, ...fill, ...t].map(x => parseInt(x, 16));
  return all.length === 8 && all.every(n => n >= 0 && n <= 0xffff) ? all : null;
}

const v4Of = (hi: number, lo: number) => `${hi >> 8}.${hi & 255}.${lo >> 8}.${lo & 255}`;

/** True only for an address on the public internet (not loopback, private, link-local, carrier NAT, multicast, documentation…). */
export function isPublicAddress(ip: string): boolean {
  if (isIP(ip) === 4) return !v4Blocked.check(ip, 'ipv4');
  const h = hextets(ip);
  if (!h) return false;
  const zero5 = h.slice(0, 5).every(n => n === 0);
  if (zero5 && (h[5] === 0xffff || h[5] === 0)) return isPublicAddress(v4Of(h[6], h[7]));          // IPv4-mapped / IPv4-compatible
  if (h[0] === 0x64 && h[1] === 0xff9b && h.slice(2, 6).every(n => n === 0)) return isPublicAddress(v4Of(h[6], h[7])); // NAT64
  if (h[0] === 0x2002) return isPublicAddress(v4Of(h[1], h[2]));                                       // 6to4
  return !v6Blocked.check(ip, 'ipv6');
}

const blockedError = () => Object.assign(new Error('address not allowed'), { code: 'EBLOCKED' });

/** dns.lookup for the HTTP agent: every address must be public, or the connection is never made. */
export function guardedLookup(hostname: string, options: any, callback: (...a: any[]) => void): void {
  dnsLookup(hostname, { ...(typeof options === 'object' ? options : {}), all: true }, (err, addresses) => {
    if (err) return callback(err);
    const list = addresses as unknown as LookupAddress[];                  // all: true always answers a list
    if (!list.length || list.some(a => !isPublicAddress(a.address))) return callback(blockedError());
    if (typeof options === 'object' && options?.all) return callback(null, list);
    callback(null, list[0].address, list[0].family);
  });
}

export type GetAnswer = { status: number; body: string };

/** One GET that never reaches a private address and never follows a redirect. */
export function guardedGet(url: string, headers: Record<string, string>, timeoutMs = TIMEOUT_MS): Promise<GetAnswer> {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const host = u.hostname.replace(/^\[|\]$/g, '');
    if (isIP(host) && !isPublicAddress(host)) return reject(blockedError());
    const lib = u.protocol === 'https:' ? https : http;
    const req = lib.request(u, { method: 'GET', headers, lookup: guardedLookup as any, timeout: timeoutMs }, res => {
      const chunks: Buffer[] = [];
      let size = 0;
      res.on('data', (c: Buffer) => {
        size += c.length;
        if (size > MAX_BODY) req.destroy(new Error('answer too large'));
        else chunks.push(c);
      });
      res.on('end', () => resolve({ status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString('utf8') }));
      res.on('error', reject);
    });
    const timer = setTimeout(() => req.destroy(new Error('timeout')), timeoutMs);
    req.on('close', () => clearTimeout(timer));
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.end();
  });
}

const WRONG_URL = 'GoFrugal answered, but this is not its API address. Check the store URL: it ends in /WebReporter, or /RayMedi_HQ for HQ.';

export async function gofrugalCheck(account: Fields, credentials: Fields, get: typeof guardedGet = guardedGet): Promise<Check> {
  const base = storeUrl(s(account.store_url));
  if (!base) return no('bad_address', 'Enter the GoFrugal store URL, for example http://yourstore.example.com/WebReporter.');
  let res: GetAnswer;
  try {
    res = await get(`${base}/api/v1/items?page=1&limit=1`, { 'X-Auth-Token': s(credentials.api_key), Accept: 'application/json', 'Content-Type': 'application/json' });
  } catch (e) {
    if ((e as { code?: string })?.code === 'EBLOCKED') {
      return no('bad_address', 'This store URL points to a private or local network address. One Local can only reach your GoFrugal server at a public address.');
    }
    console.error('[integrations] gofrugal call failed', e instanceof Error ? e.name : 'error');
    return no('unreachable', 'GoFrugal did not answer at this store URL. Check the URL and that your GoFrugal server is online.');
  }
  if (res.status === 401 || res.status === 403) return no('refused', 'GoFrugal refused this API key. Copy the key again from GoFrugal.');
  if (res.status === 404) return no('not_api', WRONG_URL);
  if (res.status >= 300 && res.status < 400) return no('not_api', 'This store URL sends us somewhere else. Enter the final GoFrugal address.');
  if (res.status !== 200) {
    console.error('[integrations] gofrugal answered', res.status);
    return no('unreachable', 'GoFrugal did not answer properly. Try again in a few minutes.');
  }
  let json: any = null;
  try { json = JSON.parse(res.body); } catch { /* not JSON: not the API */ }
  if (!json || typeof json !== 'object' || !Array.isArray(json.items)) return no('not_api', WRONG_URL);
  const total = Number(json.total_records ?? json.count ?? json.items.length);
  return ok(Number.isFinite(total) ? `Connected to GoFrugal. ${total} ${total === 1 ? 'item' : 'items'} in your catalogue.` : 'Connected to GoFrugal.');
}

// ---- handlers

export const defaultDeps: Deps = {
  key: () => piiKey(),
  canEdit: async request => {
    const { data, error } = await userClient(request).rpc('pos_integrations_get', { p: {} });
    if (error) mapDbError(error);
    return (data as { can_edit?: unknown } | null)?.can_edit === true;
  },
  save: (userId, p, key) => rpc('pos_integration_save', { p_user_id: userId, p, p_key: key }),
  secret: (userId, p, key) => rpc('pos_integration_secret', { p_user_id: userId, p, p_key: key }),
  record: (userId, p) => rpc('pos_integration_record_check', { p_user_id: userId, p }),
  check: (provider, account, credentials) => (provider === 'petpooja' ? petpoojaCheck(account, credentials) : gofrugalCheck(account, credentials)),
};

function refusal(provider: Provider, check: Check): HttpError {
  switch (check.reason) {
    case 'unreachable':
      return new HttpError(502, check.message, undefined, 'integration_unreachable');
    case 'bad_address':
    case 'not_api':
      return new HttpError(422, check.message, undefined, 'integration_bad_address');
    default:
      return new HttpError(422, check.message || `${PROVIDER_NAME[provider]} refused these details.`, undefined, 'integration_refused');
  }
}

/** pos_integration_connect: check the keys with the provider, then save them (encrypted) only if the provider accepted them. */
export async function connect({ request, userId, args }: SecureCtx, deps: Deps = defaultDeps) {
  const { provider } = parse(AnyProvider, args);
  let account: Fields, credentials: Fields, keyHint: string;
  if (provider === 'petpooja') {
    const b = parse(PetpoojaConnect, args);
    account = { restaurant_id: b.restaurant_id };
    credentials = { app_key: b.app_key, app_secret: b.app_secret, access_token: b.access_token };
    keyHint = hint(b.access_token);
  } else {
    const b = parse(GofrugalConnect, args);
    account = { store_url: b.store_url, ...(b.outlet_id ? { outlet_id: b.outlet_id } : {}) };
    credentials = { api_key: b.api_key };
    keyHint = hint(b.api_key);
  }
  const key = deps.key();
  if (!key) throw notConfigured();
  if (!(await deps.canEdit(request))) throw new HttpError(403, 'Only the owner or a manager can change integrations.', undefined, 'forbidden');
  const check = await deps.check(provider, account, credentials);
  if (!check.ok) throw refusal(provider, check);
  return deps.save(userId, { provider, account, credentials, key_hint: keyHint, message: check.message }, key);
}

/** pos_integration_test: check the saved keys with the provider again and record the outcome. */
export async function testConnection({ userId, args }: SecureCtx, deps: Deps = defaultDeps) {
  const { provider } = parse(Which, args);
  const key = deps.key();
  if (!key) throw notConfigured();
  const saved = await deps.secret(userId, { provider }, key);
  const check = await deps.check(provider, saved?.account ?? {}, saved?.credentials ?? {});
  const page = await deps.record(userId, { provider, ok: check.ok, message: check.message });
  return { ...(page && typeof page === 'object' ? page : {}), check: { provider, ok: check.ok, message: check.message } };
}
