# Functions waiting to join the manifest (src/rpc-manifest.ts)

Not on main yet, so not callable. When a section merges: add one `db(...)` line per function (all take `p jsonb`, so `map: P`, `args: 'passthrough'`),
run `node scripts/manifest-audit.mjs` (must PASS), add the names to the cross-tenant test (`scripts/gateway-e2e.mjs`), and delete the section's old
`/api/partner/...` route. Each function below was seen on the LOCAL database with EXECUTE for `authenticated`; **none of them has been audited
by this work** (the audit script does it the moment they are listed). `anon` must have no grant; the script fails if it has.

## Section F, sell (branch claude/section-f-sell-8318ef, routes /api/partner/sell/*)
| Route (old) | Function | Suggested rate | Note |
|---|---|---|---|
| POST orders/:id/split-pay | pos_split_pay | money | idem |
| POST orders/:id/refund | pos_refund | money | already in the manifest (0371 on main) |
| POST orders/:id/attempts | pos_payment_attempt_record | write | records a payment attempt only |
| POST orders/:id/online-checkout | (provider call, check sell.ts) | secure | a payment provider is involved: stays a `secure` handler in src/modules/secure/payments.ts |
| GET receipts | pos_receipt_list | read | |
| GET/POST returns | pos_return_list, pos_return_create | read / write | |
| POST returns/:id/decide | pos_return_decide | write | |
| POST returns/:id/refund | pos_return_issue_refund | money | idem |
| GET/POST coupons | (list: check sell.ts), pos_coupon_save | write | |
| GET catalog | table read of menu_items in the old route | — | needs a function (invoker, RLS) before it can use the gateway |

## Section G, catalogue and goods received (branch claude/section-g-catalogue-2079b3, routes /api/partner/catalogue*, /api/partner/grn*)
cat_item_list, cat_item_lookup, cat_item_view, cat_item_save,
grn_open, grn_list, grn_view, grn_matching_view, grn_invoice_save, grn_costs_save, grn_resolve, grn_request_approval, grn_decide.
(grn_decide posts the receipt through section H's inv_document_act.) Errors use prefixes GRN_, POS_, INV_: all already mapped in db.ts.

## Seen on the local database from other sections (not in the two branches above)
Section H (inventory): now in the manifest (all twelve inv_ functions), audited and in the cross-tenant e2e.
Section H (tables and floor, 0404): now in the manifest (all nine tbl_ functions), audited and in the cross-tenant e2e.
Section I (services): svc_catalogue, svc_quote, svc_calendar, svc_slots, svc_book, svc_appointment_view, svc_appointment_act, svc_bill, svc_history.
Section J (back office): now in the manifest (backoffice_low_stock, purchase_suggestions_refresh / list / close), audited and in the cross-tenant e2e.

## Never through the gateway (service role or a third party)
ol_partner_act (replaced by gw_online_order_act), pos_start_online_payment, pos_online_payment_status, partner_app_save_tax / save_bank / attach_document /
document_path, partner_setup_save_payment / attach_listing_image (secret or storage: `secure` handlers), every partner_app_* / partner_setup_* with a `p_user_id`
argument (only reachable through the gw_ wrappers).
