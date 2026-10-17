// Vercel entry: the SAME router as `npm run dev`, exposed as web-standard handlers. Built to api/index.js by `npm run build:vercel`.
import './routes.ts';
import { handle } from './server.ts';
import { isProduction } from './config.ts';

if (isProduction() && !process.env.PARTNER_PII_KEY?.trim()) console.error('[env] PARTNER_PII_KEY is not set: onboarding tax/bank saves answer 503.');

export default { fetch: (request: Request) => handle(request) };
export const GET = handle, POST = handle, PUT = handle, OPTIONS = handle;
