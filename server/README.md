# VINII POS server

The POS app's own small backend. Standalone: it imports nothing from the One Local customer app (OL-ui). Node + TypeScript, three dependencies (`@supabase/supabase-js`, `zod`, and `typescript` for type checks). Node 22.18+ runs the `.ts` files directly; there is no build step.

What it does: checks who is calling (the Supabase access token the app sends), checks the shape of each request, hands out private upload slots (buckets `partner-documents`, `partner-listing-media`), supplies the PII encryption key, and calls the database functions. **Every business rule lives in the database** (migrations 0343 to 0372). The server holds none, so a second client cannot get around them.

Endpoint list with callers and database functions: [ENDPOINTS.md](ENDPOINTS.md).

## Run (local)

```bash
cd new-mobile-flutter/server
cp .env.example .env        # then fill SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY from the local stack (names only here)
npm install
npm run dev                 # http://localhost:8090  (PORT overrides)
```

Flutter dev run: `--dart-define=PARTNER_API_BASE_URL=http://localhost:8090` (Android emulator: `http://10.0.2.2:8090`).
Local Supabase only: the server refuses a non-local `SUPABASE_URL` unless `ALLOW_REMOTE=1`.

## Configuration (variable names)

| Name | Needed | Purpose |
|---|---|---|
| `SUPABASE_URL` | yes | API gateway, local `http://127.0.0.1:54321` |
| `SUPABASE_SERVICE_ROLE_KEY` | yes | verifies tokens, staff lookup, storage slots, calls onboarding/setup functions for an already-verified user id |
| `SUPABASE_ANON_KEY` (or `SUPABASE_PUBLISHABLE_KEY`) | yes | POS orders run as the caller (their token on this key) so row-level security applies |
| `PARTNER_PII_KEY` | production | 16+ characters; encrypts PAN and bank numbers in the database. Local dev uses a fixed dev-only key; production without it answers 503 on tax/bank saves |
| `PORT` | no | default 8090 |
| `ALLOW_REMOTE` | no | `1` only on the host meant to use a hosted project |
| `TRUSTED_PROXY_HOPS` | no | proxies in front of the server (for per-address limits) |
| `CORS_ORIGINS` | no | comma list of origins, only for Flutter web |

Never commit `.env`. It is git-ignored.

## Layout

```
src/index.ts        listen
src/server.ts       node:http <-> web Request/Response, optional CORS
src/router.ts       tiny router (404 / 405 as {detail})
src/routes.ts       every endpoint, one line each
src/http.ts         {detail, code} errors, body cap, rate limit, log redaction
src/auth.ts         verifies the Bearer token with Supabase Auth (cached 60 s)
src/staff.ts        requireStaff (org_users + roles) / requireUser (onboarding, setup)
src/db.ts           service-role client, userClient (as the caller), rpc, OL_* error -> HTTP status
src/config.ts       env guard (local only), key lookup
src/modules/        me, onboarding, setup, home, orders
scripts/            home-checks.ts, orders-e2e.mjs   (the python walks are in ../tool/)
tests/unit/         router, errors, limits, redaction (no database)
```

## Tests

```bash
npm run typecheck && npm test                 # unit, no database
npm run dev                                   # in another terminal, then:
python3 ../tool/onboarding_e2e.py             # 35 checks, section B
python3 ../tool/setup_e2e.py                  # 36 checks, section C
node scripts/orders-e2e.mjs                   # 44 checks, section E (two businesses, tenancy, idempotency, version conflicts)
node scripts/catalogue-e2e.mjs                # 49 checks, section G (catalogue + GRN over HTTP; needs section H installed)
BASE_URL=http://localhost:8090 node --env-file=.env scripts/home-checks.ts   # 36 checks, section D
```

The scripts use the local Docker database (`supabase_db_onelocal-dev`) and clean up after themselves where the schema allows.

## Still depends on the customer app

- **Delivery job follow-up on accept/reject of a One Local order.** In the customer app, accepting released the held delivery job and rejecting cancelled it, by calling the dispatch service (`dispatch.ts`, signed calls to an external service). This server runs the database step (`ol_partner_act`) and does not call dispatch. The customer app's own sweep cancels jobs of cancelled orders; whether anything else releases a held job after accept is NOT verified. A decision is needed (see the journal entry).
- **Signed upload URLs** point at the Supabase host in `SUPABASE_URL`; on a real phone that must be a host the phone can reach.
