// node:http adapter: turns each request into a web Request, runs the router, writes the Response.
import { createServer, type IncomingMessage, type Server } from 'node:http';
import { Readable } from 'node:stream';
import './routes.ts';
import { dispatch } from './router.ts';
import { fail, redact } from './http.ts';

function cors(origin: string | undefined): Record<string, string> {
  const allowed = (process.env.CORS_ORIGINS ?? '').split(',').map(s => s.trim()).filter(Boolean);
  if (!origin || !allowed.includes(origin)) return {};
  return {
    'Access-Control-Allow-Origin': origin, 'Vary': 'Origin',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type, Idempotency-Key',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS', 'Access-Control-Max-Age': '600',
  };
}

function toRequest(req: IncomingMessage, port: number): Request {
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) if (v !== undefined) headers.set(k, Array.isArray(v) ? v.join(', ') : v);
  const hasBody = req.method !== 'GET' && req.method !== 'HEAD';
  return new Request(`http://localhost:${port}${req.url ?? '/'}`, {
    method: req.method, headers,
    body: hasBody ? (Readable.toWeb(req) as unknown as ReadableStream) : undefined,
    // @ts-expect-error Node requires `duplex` for a streamed body
    duplex: hasBody ? 'half' : undefined,
  });
}

export function createApp(port = 0): Server {
  return createServer(async (req, res) => {
    const extra = cors(req.headers.origin);
    let response: Response;
    try {
      response = req.method === 'OPTIONS' ? new Response(null, { status: 204 }) : await dispatch(toRequest(req, port));
    } catch (error) {
      console.error('[server]', redact(error));
      response = fail(500, 'Something went wrong. Please try again.');
    }
    const out: Record<string, string> = { ...extra, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
    response.headers.forEach((v, k) => { out[k] = v; });
    res.writeHead(response.status, out);
    res.end(Buffer.from(await response.arrayBuffer()));
  });
}
