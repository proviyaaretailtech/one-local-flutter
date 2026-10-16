# Endpoints the VINII POS app calls

Base URL: `--dart-define=PARTNER_API_BASE_URL=http://<host>:8090`. Every call (except `/health` and the webhooks) sends `Authorization: Bearer <Supabase access token>`. No other key is in the app.
Errors are always `{ "detail": "<sentence the app shows>", "code"?: "<machine reason>" }` with the HTTP status. 401 = not signed in, 403 = the database refused the person, 404 = not found / not on the list, 429 = rate limited (`Retry-After`).

## 1. The one generic endpoint: `POST /rpc/<name>`

Body = the JSON arguments. The server verifies the token (public key only), then calls the database function **as the signed-in person** (their token on the anon key, `userClient` in `src/db.ts`). Row-level security and each function's own organisation / location / role checks are the gate; the service-role key is never used on this path. `Idempotency-Key` header is copied into `idempotency_key` for functions marked `idem`.
`POST /rpc` with `{ "calls": [{ "fn": "...", "args": {...} }] }` runs up to 10 calls in order (not one transaction) and answers `{ results: [{ ok, data } | { ok:false, status, detail, code }] }`.
The allowlist is `src/rpc-manifest.ts`: a name that is not listed is **404** (also without a token). No SQL, no table access. Functions waiting for their section to merge: `src/rpc-manifest.pending.md`.
Database errors `OL_/POS_/INV_/GRN_/SVC_<REASON>: sentence` become the HTTP status in `src/db.ts`.
Safety check of every listed function: `node scripts/manifest-audit.mjs` (fails on an anon grant, an unpinned definer, a temp-table body). Cross-tenant test: `node scripts/gateway-e2e.mjs`.

### Pass-through to a database function (called as the caller)

| Name | Database function | Who (the function decides) | Logic |
|---|---|---|---|
| `partner_app_get` | `gw_partner_app_get` | any signed-in person | 0348 via 0360 |
| `partner_app_save_profile` / `_choose_plan` / `_save_address` / `_save_identity` / `_save_consents` / `_accept_agreement` / `_submit` | `gw_partner_app_*` | any signed-in person | 0348 via 0360 |
| `partner_setup_get`, `_confirm_plan`, `_save_tax`, `_register_pos`, `_invite_staff`, `_add_item`, `_save_listing`, `_save_fulfilment`, `_tour_seen`, `_complete` | `gw_partner_setup_*` | owner of an approved business | 0350 via 0360; listing image paths in the answer become short-lived links |
| `pos_quote_order`, `pos_order_history`, `pos_order_view`, `pos_checkout` (idem), `pos_checkout_pay` (idem), `pos_set_order_status`, `pos_fulfilment_act` (idem), `pos_refund` (idem) | same name | staff of a business; roles inside | 0370, 0371 |
| `online_order_act` | `gw_online_order_act` | staff with order.update_status | 0361: accept / reject / ready an online order; writes the `dispatch.release_requested` / `dispatch.cancel_requested` outbox event |
| `pos_home_online`, `pos_home_channel` | same name | staff | 0362 |
| `static_taxonomy` | none (static lists) | any signed-in person | `schemas/onboarding.ts` |

The `gw_*` wrappers (0360) take the user id from the token (`auth.uid()`); the original `partner_app_*` / `partner_setup_*` functions take a user id and stay unreachable for the app.

### Secret-bearing (`src/modules/secure/`, same door, `POST /rpc/<name>`)

Only where a secret, storage or a third party is needed. They get the user id from the verified token (never from the body), may use the service-role key, and are limited to the person's own application / business.

| Name | Why it is not a plain database call | Notes |
|---|---|---|
| `me` | reads the membership with the service role | `{person, restaurant}`; 403 when not staff |
| `partner_app_save_tax`, `partner_app_save_bank`, `partner_setup_save_payment` | `PARTNER_PII_KEY` encrypts PAN and bank numbers inside the database; the key lives only on the server | 503 `not_configured` in production without the key |
| `partner_app_document_slot`, `partner_app_document_attach`, `partner_app_document_preview` | signed upload slots / previews in private bucket `partner-documents` | the path must be inside the caller's own application folder |
| `partner_setup_image_slot`, `partner_setup_image_attach` | same, bucket `partner-listing-media` | path inside the caller's business folder |
| `POST /webhooks/razorpay`, `POST /webhooks/cashfree` | payment provider webhooks (real HTTP endpoints, no user token) | **not connected**: answer 501 until `RAZORPAY_WEBHOOK_SECRET` / `CASHFREE_WEBHOOK_SECRET` and the hand-off to a database function exist |

Delivery dispatch on accept/reject: the database writes the outbox event in the same transaction as the action (0361). Nothing reads those events yet; whoever connects the delivery partner consumes `dispatch.*` from `domain_events`. This is the open gap from the README.

## 2. Presentation routes (still dedicated; they run as the caller, no service role)

Sections D and E need the server to turn database facts into the labels, stages and buttons the screens draw (about 400 lines of formatting). That is not a pass-through, so these stay as routes until the shaping moves into database functions or the app. Every read and write runs through `userClient`: the server only verifies the token and formats.

## Section D: control centre — `lib/home/home_api.dart`, `modules/home.ts`

Staff only. Read-only; scoped to the caller's organisation and, when they have `org_user_locations` rows, to those outlets (another business's outlet id is 404).

| Method | Path | Query | Response |
|---|---|---|---|
| GET | `/api/partner/home` | `location?` | `HomeSummary`: today's sales, bills, active orders with delivery status/ETA, catalogue gaps, low stock, cancelled KOTs, goods received. Unknown sources are `null`. |
| GET | `/api/partner/home/feed` | `days` (1/7/30), `compare` (0/1), `location?` | `HubFeed`: period totals, previous period, daily totals. `days` other than 1/7/30 → 400. |

Logic is in `modules/home.ts` (queries as the caller; the two online-order facts come from `pos_home_online` / `pos_home_channel`, 0362).

## Section E: counter bill and order lifecycle — `lib/orders/orders_api.dart`, `modules/orders.ts`, migration 0370

Staff only. Every database call runs AS the signed-in staff member (their token on the anon key), so row-level security and the role checks inside the functions apply. `Idempotency-Key` header is required where marked.

| Method | Path | Request | Database function |
|---|---|---|---|
| GET | `/api/partner/pos-orders` | `filter=all\|completed\|pending\|cancelled`, `q?` | `pos_order_history` |
| GET | `/api/partner/pos-orders/catalog` | `q?` | `menu_items` (RLS) |
| POST | `/api/partner/pos-orders/quote` | `{lines:[{menu_item_id,qty}], coupon_code?}` | `pos_quote_order` (writes nothing) |
| POST | `/api/partner/pos-orders/checkout` (key) | `{lines, method, tendered?, reference?}` | `pos_checkout` |
| POST | `/api/partner/pos-orders/hold` (key) | `{lines}` | `pos_checkout` (hold) |
| GET | `/api/partner/pos-orders/:id` | – | `pos_order_view` |
| POST | `/api/partner/pos-orders/:id/pay` (key) | `{method, tendered?, reference?, version}` | `pos_checkout_pay` |
| POST | `/api/partner/pos-orders/:id/cancel` | `{reason, version}` | `pos_set_order_status` |
| POST | `/api/partner/pos-orders/:id/act` (key) | `{action, version, lines?, delivery?, note?, reason?}` | `pos_fulfilment_act`; `online_accept/online_reject/online_ready` → `ol_partner_act` |

## Not called by the app today (exist in the customer app for the OLD partner app, not ported)

`/api/partner/outlet`, `/items`, `/orders`, `/payments`, `/devices`, `/test-order`, `/account/*`. The new POS has no Dart caller for them. If a future screen needs one, port it here against the same database functions rather than calling the customer app.
