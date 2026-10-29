// node:http adapter: turns each request into a web Request, runs the router, writes the Response.
import { createServer, type IncomingMessage, type Server } from 'node:http';
import { Readable } from 'node:stream';
import './routes.ts';
import { dispatch } from './router.ts';
import { isSupabaseProxyPath, supabaseProxy } from './supabase-proxy.ts';
import { fail, redact } from './http.ts';

function cors(origin: string | undefined): Record<string, string> {
  const allowed = (process.env.CORS_ORIGINS ?? '').split(',').map(s => s.trim()).filter(Boolean);
  // Any local dev origin (Flutter web picks a port per run). Auth is a bearer token, not cookies.
  const isLocalDev = !!origin && /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin);
  if (!origin || !(isLocalDev || allowed.includes(origin))) return {};
  return {
    'Access-Control-Allow-Origin': origin, 'Vary': 'Origin',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type, Idempotency-Key, apikey, x-client-info, x-upsert, x-supabase-api-version',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS', 'Access-Control-Max-Age': '600',
  };
}

function toRequest(req: IncomingMessage, port: number): Request {
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) if (v !== undefined) headers.set(k, Array.isArray(v) ? v.join(', ') : v);
  // the socket's own address, for limits that must not trust the caller (clientIp); a client-sent copy is replaced
  headers.set('x-ol-peer', req.socket.remoteAddress ?? 'direct');
  const hasBody = req.method !== 'GET' && req.method !== 'HEAD';
  return new Request(`http://localhost:${port}${req.url ?? '/'}`, {
    method: req.method, headers,
    body: hasBody ? (Readable.toWeb(req) as unknown as ReadableStream) : undefined,
    // @ts-expect-error Node requires `duplex` for a streamed body
    duplex: hasBody ? 'half' : undefined,
  });
}

/** One request in, one response out: shared by the local node:http server and the Vercel function, so there is one codebase. */
export async function handle(request: Request): Promise<Response> {
  const extra = cors(request.headers.get('origin') ?? undefined);
  let response: Response;
  try {
    response = request.method === 'OPTIONS' ? new Response(null, { status: 204 })
      : isSupabaseProxyPath(new URL(request.url).pathname) ? await supabaseProxy(request)
      : await dispatch(request);
  } catch (error) {
    console.error('[server]', redact(error));
    response = fail(500, 'Something went wrong. Please try again.');
  }
  const headers = new Headers(response.headers);
  for (const [k, v] of Object.entries({ ...extra, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' })) headers.set(k, v);
  return new Response(response.body, { status: response.status, headers });
}

export function createApp(port = 0): Server {
  return createServer(async (req, res) => {
    const response = await handle(toRequest(req, port));
    const out: Record<string, string> = {};
    response.headers.forEach((v, k) => { out[k] = v; });
    res.writeHead(response.status, out);
    res.end(Buffer.from(await response.arrayBuffer()));
  });
}
