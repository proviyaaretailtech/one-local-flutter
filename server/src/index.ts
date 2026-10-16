import { createApp } from './server.ts';
import { isProduction, serviceKey, supabaseUrl } from './config.ts';

const port = Number(process.env.PORT) || 8090;
if (isProduction() && !process.env.PARTNER_PII_KEY?.trim()) console.error('[env] PARTNER_PII_KEY is not set: onboarding tax/bank saves answer 503.');
const server = createApp(port);
server.listen(port, () => {
  console.log(`VINII POS server listening on :${port}  (database ${supabaseUrl() && serviceKey() ? 'configured' : 'NOT configured: set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY'})`);
});
for (const sig of ['SIGINT', 'SIGTERM'] as const) process.on(sig, () => server.close(() => process.exit(0)));
