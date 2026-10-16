// Environment guard. Names only: no value is ever printed.
//   1. This server talks only to a LOCAL Supabase unless ALLOW_REMOTE=1 is set on purpose, so a .env that carries a hosted
//      project's URL and key cannot reach that project by accident.
//   2. A Supabase management token has no use here; it is removed from the process environment when this module loads.
Reflect.deleteProperty(process.env, 'SUPABASE_ACCESS_TOKEN');

export const isProduction = () => process.env.NODE_ENV === 'production';

const LOCAL_HOST = /^(localhost|127\.0\.0\.1|\[::1\]|[a-z0-9-]+\.localhost)$/i;
export function isLocalUrl(url: string | undefined | null): boolean {
  try { return LOCAL_HOST.test(new URL(String(url)).hostname); } catch { return false; }
}

let told = false;
function refuse(url: string) {
  if (told) return;
  told = true;
  let host = 'a remote host';
  try { host = new URL(url).hostname; } catch { /* generic wording */ }
  console.error(`[env] Refusing to use the Supabase project at ${host}: it is not a local database. Set ALLOW_REMOTE=1 on the server meant to use it.`);
}

/** The Supabase address this server may use, or null (not configured, or remote without ALLOW_REMOTE=1). */
export function supabaseUrl(): string | null {
  const url = process.env.SUPABASE_URL?.trim();
  if (!url) return null;
  if (!isLocalUrl(url) && process.env.ALLOW_REMOTE !== '1') { refuse(url); return null; }
  return url;
}

export const serviceKey = () => process.env.SUPABASE_SERVICE_ROLE_KEY?.trim() || null;
export const anonKey = () => process.env.SUPABASE_ANON_KEY?.trim() || process.env.SUPABASE_PUBLISHABLE_KEY?.trim() || null;

/** Key that encrypts PAN and bank numbers in the database. */
export function piiKey(): string {
  const k = process.env.PARTNER_PII_KEY?.trim();
  if (k && k.length >= 16) return k;
  if (isProduction()) return '';
  return 'dev-only-partner-pii-key-0123456789'; // local development only; never used in production
}
