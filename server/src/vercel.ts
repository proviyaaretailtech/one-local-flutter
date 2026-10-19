// Vercel entry: the SAME router as `npm run dev`, exposed as web-standard handlers. Built to api/index.js by `npm run build:vercel`.
import './routes.ts';
import { handle } from './server.ts';
import { isProduction } from './config.ts';

if (isProduction() && !process.env.PARTNER_PII_KEY?.trim()) console.error('[env] PARTNER_PII_KEY is not set: onboarding tax/bank saves answer 503.');

// x-ol-peer is the node server's socket address (src/server.ts); a caller must not be able to send one here
const run = (request: Request) => {
  if (!request.headers.has('x-ol-peer')) return handle(request);
  const headers = new Headers(request.headers); headers.delete('x-ol-peer');
  const hasBody = request.method !== 'GET' && request.method !== 'HEAD';
  return handle(new Request(request.url, { method: request.method, headers, body: hasBody ? request.body : undefined, duplex: hasBody ? 'half' : undefined } as RequestInit));
};
export default { fetch: run };
export const GET = run, POST = run, PUT = run, OPTIONS = run;
