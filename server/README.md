# One Local POS server

The POS app's own small backend. Standalone: it imports nothing from the One Local customer app (OL-ui). Node + TypeScript, three dependencies (`@supabase/supabase-js`, `zod`, and `typescript` for type checks). Node 22.18+ runs the `.ts` files directly; there is no build step.

What it does: **one generic endpoint, `POST /rpc/<name>`.** It checks who is calling (the Supabase access token the app sends), checks the shape of the request, and calls the named database function AS THAT PERSON (their token on the anon key), so row-level security and each function's own checks decide. Only the names in the allowlist `src/rpc-manifest.ts` can be called. Only where a secret or a third party is needed (PII key, private storage, payment providers) a handler in `src/modules/secure/` does the work, still behind the same door. **Every business rule lives in the database** (migrations 0343 to 0372); the server holds none, so a second client cannot get around them. The app carries no key except the person's own session token.

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
| `SUPABASE_SERVICE_ROLE_KEY` | yes | ONLY the secret-bearing handlers (`src/modules/secure/`: storage slots, PII save for an already-verified user id, `me`) and the test scripts. The `/rpc` gateway and the order/home routes never use it |
| `SUPABASE_ANON_KEY` (or `SUPABASE_PUBLISHABLE_KEY`) | yes | verifies tokens and runs every call as the caller (their token on this key) so row-level security applies |
| `PARTNER_PII_KEY` | production | 16+ characters; encrypts PAN and bank numbers in the database. Local dev uses a fixed dev-only key; production without it answers 503 on tax/bank saves |
| `ANTHROPIC_API_KEY` | optional | Claude API key for "Write with AI" (dish descriptions). Unset: `menu_ai_describe` answers 503 `ai_not_configured`. Never print or commit it |
| `REMOVE_BG_API_KEY` | optional | remove.bg key for "Remove background (AI)" on the item form (`cat_image_remove_bg`). Unset: 503 `bg_not_configured`. `REMOVE_BG_SIZE` picks the output size (default `auto`). Never print or commit it |
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
src/routes.ts       /health, /rpc/:name, /rpc, webhooks, then the older presentation routes (home, pos-orders)
src/rpc.ts          the gateway: allowlist lookup, token check, args check, call as the caller
src/rpc-manifest.ts THE ALLOWLIST (one entry per function; kind db | secure | local)
src/rpc-manifest.pending.md  functions of unmerged sections, ready to be listed
src/schemas/        zod shapes for onboarding and setup arguments
src/modules/secure/ secret-bearing handlers: pii.ts, storage.ts, me.ts, payments.ts (webhook hook, not connected)
src/modules/        home.ts, orders.ts (presentation: formatting of database facts, runs as the caller)
src/http.ts         {detail, code} errors, body cap, rate limit, log redaction
src/auth.ts         verifies the Bearer token with Supabase Auth (public key, cached 60 s)
src/staff.ts        requireStaff (org_users + roles), requireSignedIn
src/db.ts           service-role client, anonClient, userClient (as the caller), OL_/POS_/INV_/GRN_/SVC_ error -> HTTP status
src/config.ts       env guard (local only), key lookup
scripts/            manifest-audit.mjs, gateway-e2e.mjs, orders-e2e.mjs, catalogue-e2e.mjs, home-checks.ts   (the python walks are in ../tool/)
tests/unit/         router, errors, limits, redaction, gateway door and manifest (no database)
```

## Tests

```bash
npm run typecheck && npm test                 # unit, no database
node scripts/manifest-audit.mjs               # every listed database function: security type, search_path, grants; fails on an anon grant / unpinned definer
npm run dev                                   # in another terminal (PORT=8091 npm run dev if 8090 is taken), then, with POS_API=http://localhost:<port>:
node scripts/gateway-e2e.mjs                  # 54 checks: the door, two businesses, B against A's ids on every function that takes an id, onboarding, secure handlers
python3 ../tool/onboarding_e2e.py             # 35 checks, section B  (through /rpc)
python3 ../tool/setup_e2e.py                  # 36 checks, section C  (through /rpc)
node scripts/orders-e2e.mjs                   # 44 checks, section E (two businesses, tenancy, idempotency, version conflicts)
node scripts/sell-e2e.mjs                     # 74 checks, section F, through /rpc (search, coupons, split pay, receipts, returns, refunds, tenancy)
node scripts/shift-e2e.mjs                    # 39 checks, store cash shift, payment pending, refund check, tenancy
node scripts/catalogue-e2e.mjs                # section G through /rpc (catalogue + GRN as real staff of two businesses; needs section H installed)
BASE_URL=http://localhost:8090 node --env-file=.env scripts/home-checks.ts   # 36 checks, section D (reads run as the signed-in person)
```

The scripts use the local Docker database (`supabase_db_onelocal-dev`) and clean up after themselves where the schema allows.

## Still depends on the customer app

- **Delivery job follow-up on accept of a One Local order: closed by migration 0363.** `gw_online_order_act` (0361) does the order step and writes a `dispatch.release_requested` event in the same transaction. `dispatch_apply_pos_events()` (0363, run every 10 s by pg_cron) reads it and releases the order's held delivery job (`dispatch_release`, with the prep time the restaurant gave), so riders are offered it. A reject already cancels the job inside `ol_partner_act`; the consumer only confirms it. This server calls no dispatch service. Not done: the push notification to the rider's phone that the customer app sent after an offer (the rider app also polls). On the hosted project the 0363 file must be run and pg_cron enabled, or the function called on a timer.
- **Signed upload URLs** point at the Supabase host in `SUPABASE_URL`; on a real phone that must be a host the phone can reach.
