// Passes a phone's sign-in and file traffic on to Supabase (`/sb/auth/v1/...`, `/sb/storage/v1/...`), for networks whose DNS blocks
// supabase.co (29 Oct 2026). Only those two services, only to this server's own Supabase project; nothing is added to the request
// (no service key): Supabase checks the caller's own anon key and token exactly as if the phone had called it.
import { supabaseUrl } from './config.ts';
import { fail } from './http.ts';

const ALLOWED = /^\/sb\/(auth|storage)\/v1(\/|$)/;
// hop-by-hop and our own headers stay here
const DROP_IN = ['host', 'connection', 'content-length', 'x-ol-peer', 'x-forwarded-host', 'accept-encoding'];
const DROP_OUT = ['content-encoding', 'content-length', 'transfer-encoding', 'connection'];

export const isSupabaseProxyPath = (path: string) => ALLOWED.test(path);

export async function supabaseProxy(request: Request): Promise<Response> {
  const base = supabaseUrl();
  if (!base) return fail(503, 'Sign-in is not connected yet.');
  const url = new URL(request.url);
  const target = base.replace(/\/+$/, '') + url.pathname.slice('/sb'.length) + url.search;
  const headers = new Headers();
  request.headers.forEach((v, k) => { if (!DROP_IN.includes(k.toLowerCase())) headers.set(k, v); });
  const hasBody = request.method !== 'GET' && request.method !== 'HEAD';
  let upstream: Response;
  try {
    upstream = await fetch(target, {
      method: request.method, headers, redirect: 'manual',
      body: hasBody ? request.body : undefined,
      // @ts-expect-error Node needs `duplex` for a streamed body
      duplex: hasBody ? 'half' : undefined,
    });
  } catch {
    return fail(502, 'Could not reach sign-in. Try again.');
  }
  const out = new Headers();
  upstream.headers.forEach((v, k) => { if (!DROP_OUT.includes(k.toLowerCase())) out.set(k, v); });
  return new Response(upstream.body, { status: upstream.status, headers: out });
}
