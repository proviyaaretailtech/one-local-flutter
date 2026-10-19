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
| `menu_ai_describe` | `ANTHROPIC_API_KEY` calls the Claude API (`claude-opus-5-5`) to draft a dish description; the database (`rst_menu_ai_begin`) checks menu.update, the dish and the per-business limit; nothing is saved | 503 `ai_not_configured` without the key; 429 `rate_limited` over 20/hour or 100/day per business |
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

## Section F: the till on top of E (search, split payment, receipts, returns, coupons) — `lib/sell/sell_api.dart`, `src/schemas/sell.ts`, migrations 0380 to 0383

Through the generic endpoint `POST /rpc/<name>` (body = the function's `p` object; zod shape in `src/schemas/sell.ts`; the database checks organisation, store, role and every amount again). Money calls carry `Idempotency-Key` (copied into the body). Manager-only rules (refund, approve a return, coupons) answer 403 for anyone else. The per-feature `/api/partner/sell/*` routes no longer exist. `POST /api/partner/pos-orders/quote | checkout | hold` (section E) also take `coupon_code` (checkout and hold also `customer_name`, `customer_phone`); the discount is worked out by `pos_place_order` (0380).

| Name | Request (`p`) | Answer | Rate / key | Who |
|---|---|---|---|---|
| `pos_sell_catalog` | `q?` (name or SKU), `category?`, `available?`, `sort?: name\|price_asc\|price_desc` | `{items:[{id,name,sku,price,category,image_url,available}], categories}`; unavailable items are listed, flagged | read | staff |
| `pos_split_pay` | `{order_id, payments:[{method: cash\|card\|upi, amount, tendered?, reference?}] (2 to 4, must add up to the amount due), expected_updated_at?}` | `{order_id, replayed, parts}` (read the bill with `GET /pos-orders/:id`) | money, key | staff who take payment |
| `pos_refund` (0371) | `{order_id, amount, method: cash\|upi\|card\|other, kind?: goodwill\|cancel\|missing_items, reason}` | refund record | money, key | managers; capped to money taken |
| `pos_payment_attempt_record` | `{order_id, method: cash\|upi\|card\|online, status?: declined\|failed\|cancelled, code?, message?}` | `{attempt_id, order_id, display_no, method, status, code, message, amount_due, charged:false}`; moves no money | write | staff who take payment |
| `pos_online_checkout` | `{order_id}` | always **503 `provider_not_configured`** for the caller's own bill (404 for anyone else's) until a payment provider (Razorpay, test mode) is wired here | money | staff who take payment |
| `pos_receipt_list` | `q?`, `status?: all\|paid\|part_paid\|unpaid\|refunded\|cancelled`, `from?`, `to?` (2026-10-09, India time), `before?` | array of bills with lines (`items[].order_item_id`), money, methods, status | read | staff |
| `pos_return_list` | `status?`, `q?` | array of returns with lines and refund method | read | staff |
| `pos_return_create` | `{order_id, lines:[{order_item_id, qty, restock?: false for a damaged item}], reason, note?}` | `{return_id, return_no, amount, status, replayed}`; amount = the items' share of the bill, set by the database; refused when more than is still refundable; the same key with other lines is 422 | write, key | staff who take payment |
| `pos_return_decide` | `{return_id, decision: approve\|reject, note?}` (reject needs a note) | `{return_id, status}`; whoever recorded the return cannot approve it while another manager exists; approval puts the goods back in stock through section H (same shelf and lot; expired lot to quarantine; damaged lines post nothing) | write | managers |
| `pos_return_issue_refund` | `{return_id, method}` | `{return_id, status:'refunded', amount, refund_id, replayed}`; calls `pos_refund` | money, key | managers |
| `pos_coupon_list` | `{}` | `{coupons:[...]}` | read | staff |
| `pos_coupon_save` | `{code, label?, kind: percent\|flat, value, min_order?, max_discount?, max_uses?, max_uses_per_customer?, active?, starts_at?, ends_at?}` | the coupon. Limits count open and paid bills and are given back when a bill is cancelled; a per-customer limit needs the customer's mobile on the bill | write | managers |

New error codes: `coupon_minimum`, `coupon_limit`, `coupon_customer`, `coupon_zero` (a coupon that would make the bill free is refused), `over_refund`, `over_return` (422), `provider_not_configured` (503). Tests: `node scripts/sell-e2e.mjs` (74 checks, through the gateway) and the F block in `scripts/gateway-e2e.mjs` (cross-tenant: B against A's bill, returns, receipts, coupons; viewer and applicant refused); `node scripts/manifest-audit.mjs` must PASS.

## Store cash shift, payment pending, refund not allowed — `lib/shift/shift_api.dart`, `src/schemas/shift.ts`, migrations 0500 to 0502

Through `POST /rpc/<name>` (body = the function's `p` object; the database checks organisation, store, role and every amount again). `location_id`
is optional everywhere: without it the business's main store allowed to the caller is used. Spec: `specs/store-shift-payments/spec.md`.

| Name | Request (`p`) | Answer | Rate / key | Who |
|---|---|---|---|---|
| `pos_shift_current` | `{location_id?}` | `{location_id, location_name, policy:{require_open_shift, variance_limit, return_days}, shift: null \| shift, must_open, can_approve, pending_approval:[shift]}` | read | staff |
| `pos_shift_list` | `{location_id?, limit?, before?}` | `[shift]` newest first | read | staff |
| `pos_shift_open` | `{location_id?, opening_float}` | shift (`status:'open'`, `shift_no`, `totals`) + `replayed` | money, key | staff who take payment |
| `pos_shift_cash_move` | `{shift_id, kind: in\|out, amount, reason}` | shift with `cash_moves` | money, key | staff who take payment |
| `pos_shift_close` | `{shift_id, counted_cash, variance_reason? (needed when counted ≠ expected), expected_version?}` | shift (`closed` or `pending_approval`) + `needs_approval`, `variance_limit` | money, key | staff who take payment |
| `pos_shift_approve` | `{shift_id, note}` | shift (`closed`, `approved_by`) | money | managers, not the person who counted (unless the only manager) |
| `pos_till_policy_set` | `{location_id?, require_open_shift?, variance_limit?, return_days?}` | the store policy | write | managers |
| `pos_payment_start` | `{order_id, method: upi\|card}` | intent `{id, status:'pending', amount, due, order_status, age_seconds, stale}` | money, key | staff who take payment |
| `pos_payment_confirm` | `{intent_id, reference}` (UPI reference / card approval code, 4 to 40) | intent `succeeded`, the bill paid through `pos_checkout_pay` | money | staff who take payment |
| `pos_payment_fail` | `{intent_id, status?: declined\|failed\|cancelled, code?, message?}` | intent `failed` / `cancelled` with `attempt` | write | staff who take payment |
| `pos_payment_status` | `{intent_id}` or `{order_id}` (latest) | intent, or `{status:'none'}` | read | staff |
| `pos_refund_check` | `{order_id, purpose?: refund\|return, amount?}` | `{allowed, reasons:[{code, message}], taken, refunded, refundable_left, return_days, days_since_paid, is_manager}`; codes `over_paid`, `outside_return_days`, `needs_manager`, `not_paid_in_full`, `online_order`, `cancelled`, `nothing_taken` | read | staff |

A shift holds no copy of money: `totals` are read from `payments` and `pos_refunds` at that store in the shift window (frozen on the row at close).
New error codes: `shift_open`, `no_shift`, `payment_pending` (409); `reason_required`, `not_enough_cash`, `return_window` (422).
E2E + cross-tenant: `node scripts/shift-e2e.mjs` (39 checks).
## Table QR codes and the guest menu — `lib/tables/table_qr_screen.dart`, `lib/guest/*`, `src/schemas/guest.ts`, migrations 0560, 0561

Spec: `specs/table-qr-guest-menu/spec.md`.

### Staff (`POST /rpc/<name>`, as the caller)

| Name | Who (the database decides) | Logic |
|---|---|---|
| `tbl_qr_list` | floor staff; the code itself only for table managers | every table of the store with has_code / enabled / issued_at |
| `tbl_qr_issue` | table managers | first code, or `replace: true` with `confirm_label` = the table's name (422 `confirm` otherwise); replacing ends the table's guest sessions |
| `tbl_qr_set_enabled` | table managers | on / off; off ends the guest sessions |
| `guest_requests_list` | floor staff | waiting guest orders of the store (or one table), `can_decide` |
| `guest_request_decide` | staff with order:place | `accept` places the order with `pos_place_order` as the caller (placed_by guest, KOT); `decline` needs a reason the guest sees |
| `guest_staff_menu`, `guest_staff_place` (idem) | staff with order:place | Hand to guest on the staff phone: the same published menu; places the order straight away |

### The guest door (`POST /guest/<name>`, no sign-in) — `src/guest-door.ts`

Separate allowlist: `open` (`guest_qr_open`), `menu` (`guest_menu`), `send` (`guest_order_send`), `status` (`guest_order_status`). The guest
functions are executable by **service_role only**, so the gateway is the only way in. Limits per network address (240/min overall; open 30,
menu 60, send 12, status 120 per minute) and per code / session; strict bodies (no extra keys, 16 KB). The database adds its own limits
(per table and per address hash per hour, three waiting orders per table, eight per session per hour). A guest never sends a price, a
table, an outlet or a business: the session names them. Errors: `GUEST_<REASON>`; an ended session answers 409 `session_expired`.

### The guest page (`GET /t/<code>`) — `src/guest-web.ts`

Static files of the Flutter web build `lib/guest_web_main.dart` (`../tool/build_guest_web.sh` writes `public/t/`, not committed). Any path
under `/t/` that is not a built file gets the page; the page reads the code from its own address. `Referrer-Policy: no-referrer` so the
code never leaks to other sites. On Vercel the build is served from `public/t/` and `vercel.json` rewrites `/t/<code>` to the page.
E2E: `node scripts/guest-e2e.mjs` (two businesses, cross-tenant, abuse limits, replaced code, accept into an order, Hand to guest).
