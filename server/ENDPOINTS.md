# Endpoints the One Local POS app calls

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
| `cat_item_list`, `cat_item_view`, `cat_item_lookup`, `cat_item_save` (idem); `grn_list`, `grn_view`, `grn_matching_view`, `grn_open`, `grn_invoice_save`, `grn_costs_save`, `grn_resolve`, `grn_request_approval`, `grn_decide` | same name | staff; menu / inventory permissions inside | section G, 0390 / 0391 / 0409 (details below) |
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

Delivery dispatch on accept/reject: the database writes the outbox event in the same transaction as the action (0361); `dispatch_apply_pos_events()` (0363, pg_cron every 10 s) consumes `dispatch.*` from `domain_events` and releases the held delivery job (a reject already cancels it inside `ol_partner_act`). No server code involved.

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
| POST | `/api/partner/pos-orders/hold` (key) | `{lines, reason?}` | `pos_hold_place` (0530: `pos_checkout` hold + the hold reason) |
| GET | `/api/partner/pos-orders/:id` | – | `pos_order_view` |
| POST | `/api/partner/pos-orders/:id/pay` (key) | `{method, tendered?, reference?, version}` | `pos_checkout_pay` |
| POST | `/api/partner/pos-orders/:id/cancel` | `{reason, version}` | `pos_set_order_status` |
| POST | `/api/partner/pos-orders/:id/act` (key) | `{action, version, lines?, delivery?, note?, reason?}` | `pos_fulfilment_act`; `online_accept/online_reject/online_ready` → `ol_partner_act` |

## Orders tab: Live orders and Hold orders — `lib/orders/orders_api.dart` → `POST /rpc/<name>`, migrations 0530, 0531

Spec: `specs/orders-live-hold/spec.md`. Body = the function's `p` object, shape checked by `src/schemas/orders.ts`; every rule is in the database.

| Name | Request | Answer |
|---|---|---|
| `pos_orders_board` | `{channel?: all\|dine_in\|takeaway\|delivery\|zomato\|swiggy, status?: new\|preparing\|ready\|dispatched\|completed, q?, location_id?}` | `{header, counts, channels[], integrations[], orders[]}` |
| `pos_hold_list` | `{channel?, q?, location_id?}` | `{delayed_after_minutes, oldest, count, holds[]}` |
| `pos_hold_update` (key) | `{order_id, expected_updated_at, lines?, reason?}` | `{order_id, updated_at, changed, replayed}` — same order; then pay with `/pos-orders/:id/pay` and `version = updated_at` |

## Section G: store catalogue and GRN matching — `lib/catalogue/catalogue_api.dart` → `POST /rpc/<name>`, migrations 0390, 0391, 0409

All through the one generic endpoint (section 1); every call runs AS the signed-in staff member. Body = the function's `p` object, checked
for shape by `src/schemas/catalogue.ts` and `src/schemas/grn.ts` (unknown fields refused, 400 `validation`); every rule is in the database.
Money is in **minor units** (paise). `Idempotency-Key` header on item create (`cat_item_save` is `idem`).

Stable item fields (section F reads these): `id`, `name`, `sku`, `barcode`, `category`, `price_minor`, `mrp_minor`, `currency`, `selling_unit`, `net_qty`, `net_qty_unit`, `gst_pct`, `hsn`, `status` (`active|inactive|draft`), `available`, `stock_qty` (null when stock is unknown), `inventory_item_id`, `version`.

| Name | Body (`p`) | Answer / rules |
|---|---|---|
| `cat_item_list` | `q? status?(all\|active\|inactive\|draft\|out\|combo) category? page? page_size?(1-100) location_id?` | `{counts{total,active,out_of_stock,inactive,combos,categories,drafts}, categories[], total_matching, page, page_size, items[]}`. The sell screen's search is this call with `status: 'active'` (name, SKU, barcode or brand). |
| `cat_item_lookup` | `code` (barcode, then SKU), `location_id?` | one item; 404 when no item has the code |
| `cat_item_view` | `id`, `location_id?` | one item |
| `cat_item_save` | create: `{mode: quick\|full, draft?, name, sku, price_minor, category?, brand?, barcode?, mrp_minor?, cost_minor?, hsn?, gst_pct?, selling_unit?, net_qty?, net_qty_unit?, unit_description?, purchase_pack_units?, storage?}`; change: same fields + `id`, `version` | Full non-draft needs `hsn` + `gst_pct` (422 `tax_required`); duplicate SKU/barcode 409; price above MRP 400; stale 409 `version_conflict`. A stock item section H already keeps with the same SKU is linked as it is (never renamed or relabelled); a selling unit different from its counting unit is 400. |
| `grn_list` | `{}` | receipts in review, approved in the last 30 days, and cancelled in the last 30 days (`review_status: cancelled`) |
| `grn_open` | `{receipt_document_id}` | creates the GRN number once; 409 if the receipt is not in review |
| `grn_view` | `{receipt_document_id}` | dashboard: totals, `invoice_total_minor`, rows, resolution, posting preview, checklist, blockers, allowed actions; `status` matching \| approval_due \| approved \| cancelled |
| `grn_matching_view` | `{receipt_document_id}` | invoice lines, received rows with state: matched, short, over, price_diff, rejected, missing, not_on_invoice. A product billed on several lines at different prices: `invoice.unit_price_minor` null, `price_mixed` true, `unit_prices[]`, `amount_minor` = sum of the lines (state price_diff). |
| `grn_invoice_save` | `{receipt_document_id, supplier_name, invoice_no, invoice_date: YYYY-MM-DD, po_ref?, lines:[{inventory_item_id?, product_name, qty, unit?, unit_price_minor}]}` | replaces the invoice while matching; clears the resolution |
| `grn_costs_save` | `{receipt_document_id, costs:[{line_id, unit_cost_minor}]}` | unit prices noticed at receiving (location scoped) |
| `grn_resolve` | `{receipt_document_id, version, resolution: accept_claim_credit\|accept_as_received, claim_ref?, evidence?, note?}` | claim needs reference + evidence; waiving a claim needs a note |
| `grn_request_approval` | `{receipt_document_id, version}` | 422 `unresolved` while exceptions are unresolved |
| `grn_decide` | `{receipt_document_id, version, decision: approve\|reject, note?}` | approver role only; the requester cannot approve unless the only approver; approve posts stock through section H `inv_document_act`; reject needs a note |

`receipt_document_id` is the section H receipt (`inventory_documents.id`); a receipt must be sent to GRN review in section H first.
**Every** section H receipt needs an approved GRN before its stock goes up: `inv_document_act` `post` without one is 409 (`GRN_NOT_APPROVED`, trigger
`grn_post_gate` on `stock_movements`). Cancelling a receipt closes its GRN as `cancelled` (0409).

## Not called by the app today (exist in the customer app for the OLD partner app, not ported)

`/api/partner/outlet`, `/items`, `/orders`, `/payments`, `/devices`, `/test-order`, `/account/*`. The new POS has no Dart caller for them. If a future screen needs one, port it here against the same database functions rather than calling the customer app.
