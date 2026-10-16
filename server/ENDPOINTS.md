# Endpoints the VINII POS app calls

Base URL: `--dart-define=PARTNER_API_BASE_URL=http://<host>:8090`. Every call (except `/health`) sends `Authorization: Bearer <Supabase access token>`.
Errors are always `{ "detail": "<sentence the app shows>", "code"?: "<machine reason>" }` with the HTTP status. 401 = not signed in, 429 = rate limited (`Retry-After`).
"Logic" says where the rule lives: the database function (migration) does the work; the server file only authenticates, checks the shape, handles files and the PII key.
The code that existed before this folder was written inside the customer app (OL-ui): onboarding in commit `cd1fe9f` (branch `feat/expo-router-api`), setup in `162ca32` (`feat/partner-setup`), home in `d3b1580` (`feat/partner-home`), POS orders in `41bead3` (`claude/section-e-orders`). `/api/partner/me` was ported from `frontend/app/api/partner/me+api.ts` (still live there for the old partner app).

| # | Method | Path | Called from (Dart) | Server file → database | Notes |
|---|---|---|---|---|---|
| 1 | GET | `/health` | none (ops check) | `routes.ts` | `{ok:true}`, no auth |
| 2 | GET | `/api/partner/me` | `lib/auth/partner_api.dart` | `modules/me.ts`; tables `org_users`, `roles`, `organizations`, `ol_merchant_channels` | Staff only. `{person:{id,email,name,role,organization_id}, restaurant:{id,name,accepting,set_up,…}}`. 403 when not staff. |

## Section B: onboarding (any signed-in person, no store yet) — `lib/onboarding/onboarding_api.dart`, `modules/onboarding.ts`, migration 0348

| Method | Path | Request | Response | Database function |
|---|---|---|---|---|
| GET | `/api/onboarding/application` | – | application state `{exists, application, …}` | `partner_app_get` |
| GET | `/api/onboarding/taxonomy` | – | `{store, restaurant, service, states, banks, account_types, document_kinds, upload}` | none (static lists) |
| PUT | `/api/onboarding/profile` | `{partner_type, business_name, owner_name, phone, email?, selling_mode, category?, subcategory?, specialty?}` | application state | `partner_app_save_profile` |
| PUT | `/api/onboarding/plan` | `{plan: pos_and_onelocal\|onelocal_app}` | state | `partner_app_choose_plan` |
| PUT | `/api/onboarding/address` | `{address_line, locality, city, state, pin_code, lat?, lng?, confirmed:true}` | state | `partner_app_save_address` |
| PUT | `/api/onboarding/tax` | `{pan?, gst_registered, gstin?}` (blank PAN keeps the saved one) | state (PAN masked) | `partner_app_save_tax` (+ `PARTNER_PII_KEY`) |
| PUT | `/api/onboarding/identity` | `{consent:true, aadhaar_last4?, business_structure?}` | state | `partner_app_save_identity` |
| PUT | `/api/onboarding/bank` | `{holder_name, bank_name, account_number, confirm_account_number, ifsc, account_type, authorised, draft?}` | state (last 4 only) | `partner_app_save_bank` (+ key) |
| PUT | `/api/onboarding/consents` | `{service_terms, privacy_notice, marketing_updates?}` | state | `partner_app_save_consents` |
| PUT | `/api/onboarding/agreement` | `{version, acknowledged}` | state | `partner_app_accept_agreement` |
| POST | `/api/onboarding/submit` | – | state with reference | `partner_app_submit` |
| POST | `/api/onboarding/documents/upload` | `{kind: pan_copy\|business_proof\|food_license, content_type, size, file_name}` | `{path, upload_url, max_bytes}` (signed slot in private bucket `partner-documents`; the app PUTs the bytes to `upload_url`) | storage signed upload |
| POST | `/api/onboarding/documents` | upload request + `{path}` | state | `partner_app_attach_document`; old copy removed |
| GET | `/api/onboarding/documents/:kind/preview` | – | `{url, expires_in:300}` | `partner_app_document_path` + signed read URL |

## Section C: workspace setup after approval — `lib/setup/setup_api.dart`, `modules/setup.ts`, migration 0350

Caller must own an approved business (the database decides; 404 "not approved yet" otherwise).

| Method | Path | Request | Database function |
|---|---|---|---|
| GET | `/api/setup/state` | – | `partner_setup_get` (listing images come back as short-lived links, never storage paths) |
| PUT | `/api/setup/plan` | `{plan_code?}` | `partner_setup_confirm_plan` |
| PUT | `/api/setup/payment` | `{holder_name, bank_name?, account_number? (blank keeps saved), ifsc?, accept_upi, accept_card, upi_id?}` | `partner_setup_save_payment` (+ key) |
| PUT | `/api/setup/tax` | `{gst_registered, gstin?, invoice_prefix?, prices_include_tax, show_address_on_receipt?, show_gstin_on_invoice?}` | `partner_setup_save_tax` |
| PUT | `/api/setup/pos` | `{device_name, peripherals: receipt_printer\|scanner\|kot_printer[], connection?: bluetooth\|usb\|lan}` | `partner_setup_register_pos` |
| POST | `/api/setup/staff` | `{name, email, role: cashier\|manager\|kitchen, permissions: billing.collect\|catalogue.view\|refunds.manage\|settings.manage[]}` | `partner_setup_invite_staff` |
| POST | `/api/setup/items` | `{name, category, price, food_type?: veg\|non_veg\|egg}` | `partner_setup_add_item` |
| PUT | `/api/setup/listing` | `{public_name, description, address_line, open_days, opens_at, closes_at}` | `partner_setup_save_listing` |
| PUT | `/api/setup/fulfilment` | `{pickup, self_delivery, onelocal_delivery, radius_km, service_areas, min_order, delivery_fee, delivery_hours…}` | `partner_setup_save_fulfilment` |
| POST | `/api/setup/tour` | `{step: 1..10}` | `partner_setup_tour_seen` |
| POST | `/api/setup/complete` | – | `partner_setup_complete` |
| POST | `/api/setup/images/upload` | `{kind: logo\|cover, content_type, size}` → `{path, upload_url, max_bytes}` (private bucket `partner-listing-media`) | storage signed upload |
| POST | `/api/setup/images` | upload request + `{path}` → setup state | `partner_setup_attach_listing_image` |

All setup responses except the two uploads' first step are the full setup state (`SetupState`). Exact field lists are in `modules/setup.ts` (zod schemas) and `lib/setup/setup_api.dart`.

## Section D: control centre — `lib/home/home_api.dart`, `modules/home.ts`

Staff only. Read-only; scoped to the caller's organisation and, when they have `org_user_locations` rows, to those outlets (another business's outlet id is 404).

| Method | Path | Query | Response |
|---|---|---|---|
| GET | `/api/partner/home` | `location?` | `HomeSummary`: today's sales, bills, active orders with delivery status/ETA, catalogue gaps, low stock, cancelled KOTs, goods received. Unknown sources are `null`. |
| GET | `/api/partner/home/feed` | `days` (1/7/30), `compare` (0/1), `location?` | `HubFeed`: period totals, previous period, daily totals. `days` other than 1/7/30 → 400. |

Logic is in `modules/home.ts` (queries only, no migration).

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
