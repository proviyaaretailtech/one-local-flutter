# Hosting the POS server on Vercel

One codebase: `npm run dev` (node:http, local) and the Vercel function (`api/index.js`) both call `handle()` in `src/server.ts`, which uses the same router.
`vercel.json` rewrites every path to that one function. `npm run build:vercel` (run by Vercel as the build command) bundles `src/vercel.ts` into `api/index.js` with esbuild; the file is not committed.

## Settings
- Framework preset: Other. Build command and install command come from `vercel.json`. Node.js 22.x (`engines`).
- Region: `bom1` (Mumbai) in `vercel.json`. **Change it to the region closest to the hosted Supabase project** (not known to this repo; edit `regions`).
- `maxDuration` 30 s, memory 512 MB.
- Request bodies: the server refuses anything over 64 KB (batch 256 KB), far under Vercel's 4.5 MB limit. File uploads never pass through the function: the app sends bytes to a signed Supabase Storage slot.
- No file is written and nothing needs to persist between requests. Rate limits (per user) and the 60-second token cache are **per function instance**: correct, but not shared across instances (a burst spread over several instances can exceed a limit). Database rules do not depend on them.
- CORS is off unless `CORS_ORIGINS` is set (only needed for Flutter web).

## Environment variables (Vercel dashboard → Settings → Environment Variables; names only here)
| Name | Secret? | Purpose |
|---|---|---|
| `SUPABASE_URL` | no | the hosted project's API URL |
| `SUPABASE_ANON_KEY` (or `SUPABASE_PUBLISHABLE_KEY`) | no (public key) | verifies tokens and runs every `/rpc` call as the signed-in person |
| `SUPABASE_SERVICE_ROLE_KEY` | **yes** | only the secret-bearing handlers (storage slots and previews, PAN/bank saves, `me`). The `/rpc` pass-through never uses it |
| `PARTNER_PII_KEY` | **yes** | 16+ characters; encrypts PAN and bank numbers inside the database. **Without it, production answers 503 on tax and bank saves.** Keep the same value forever: changing it makes saved numbers unreadable |
| `ANTHROPIC_API_KEY` | no | Claude API key for "Write with AI" on the restaurant dish screen. Without it the screen says "AI writing is not set up yet" and manual writing still works |
| `ALLOW_REMOTE` | no | must be `1`, otherwise the server refuses a non-local Supabase URL |
| `TRUSTED_PROXY_HOPS` | no | `1` (Vercel is one proxy in front) |
| `NODE_ENV` | no | Vercel sets `production` itself |
| `CORS_ORIGINS` | no | optional, comma list of browser origins |
| `RAZORPAY_WEBHOOK_SECRET`, `CASHFREE_WEBHOOK_SECRET` | **yes** | reserved; the webhook hooks answer 501 until a provider is connected |

Run the hosted SQL files in `docs/online-migrations/` (0360, 0361, 0362 and what they need) **before** the first deploy.

## Health probe
`GET /health` → `{"ok":true,"version":"0.1.0+<commit>","db":"reachable"|"unreachable"}`. Uses the public key only; no secret is read or shown. Point the Vercel/uptime check at it.

## Local check of the Vercel build
`npm run build:vercel && node --env-file=.env -e "import('./api/index.js').then(async m=>console.log(await (await m.default.fetch(new Request('https://x/health'))).text()))"`
The same entry is covered by `tests/unit/vercel.test.ts`.

## Making the separate repo
`scripts/make-vercel-snapshot.sh <empty-folder>` copies `server/` (no node_modules, no .env, no local test data) and makes one commit authored `proviyaaretailtech <339435687+proviyaaretailtech@users.noreply.github.com>` (Vercel Hobby blocks other authors). It does not create or push to GitHub.
