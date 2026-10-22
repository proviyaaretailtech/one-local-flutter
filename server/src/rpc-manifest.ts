// THE ALLOWLIST of the one generic endpoint (POST /rpc/<alias>). A name that is not here is 404. Nothing else is reachable through
// the gateway: no SQL, no table access, no function the list does not name.
//
// Two kinds of entry:
//   db     -> the database function `fn`, called AS THE CALLER (their own token on the anon key). Row-level security and the function's
//             own organisation / location / role checks are the gate. The service-role key is never used on this path.
//   local  -> answered by the gateway itself from static data (no database).
//   secure -> a handler in src/modules/secure/, only where a secret (PARTNER_PII_KEY), storage or a third party is needed. It gets the
//             user id from the verified token and may use the service role; it must not trust the client for who the user is.
//
// Fields: alias (the public name; the app calls this), fn (database function), args (zod schema, or 'passthrough' = any JSON object and
// the database validates), map (checked args -> database argument names; default {p: args} for the `p jsonb` convention), rate (limit class),
// roles (a HINT for readers and the audit script; the database decides), post (a transform of the result), idem (Idempotency-Key header
// is copied into args.idempotency_key when the body has none).
// scripts/manifest-audit.mjs reads this file and fails on any function that is unsafe for the `authenticated` role.
import type { z } from 'zod';
import { dropRemovedFile, secureHandlers, withImageLinks, withStorefrontLinks, type SecureHandler } from './modules/secure/index.ts';
import * as ob from './schemas/onboarding.ts';
import * as su from './schemas/setup.ts';
import * as inv from './schemas/inventory.ts';
import * as kit from './schemas/kitchen.ts';
import * as cat from './schemas/catalogue.ts';
import * as grn from './schemas/grn.ts';
import * as tbl from './schemas/tables.ts';
import * as bo from './schemas/backoffice.ts';
import * as svc from './schemas/service.ts';
import * as rst from './schemas/restaurant.ts';
import * as sell from './schemas/sell.ts';
import * as pur from './schemas/purchasing.ts';
import * as mo from './schemas/money.ts';
import * as team from './schemas/team.ts';
import * as sf from './schemas/storefront.ts';
import * as nt from './schemas/notices.ts';
import * as st from './schemas/settings.ts';
import { helpContent } from './modules/help.ts';
import * as out from './schemas/outlets.ts';
import * as cu from './schemas/customers.ts';
import * as sh from './schemas/shift.ts';
import * as ord from './schemas/orders.ts';
import * as gst from './schemas/guest.ts';

export type Rate = 'read' | 'write' | 'money' | 'secure';
type Common = { alias: string; rate: Rate; roles: string; maxBytes?: number };
export type DbEntry = Common & {
  kind: 'db'; fn: string; args: z.ZodTypeAny | 'passthrough'; map?: (args: any) => Record<string, unknown>;
  post?: (result: any) => Promise<unknown> | unknown; idem?: boolean;
};
export type SecureEntry = Common & { kind: 'secure'; args: z.ZodTypeAny | 'passthrough'; handler: SecureHandler };
export type LocalEntry = Common & { kind: 'local'; args: z.ZodTypeAny | 'passthrough'; run: () => unknown };
export type Entry = DbEntry | SecureEntry | LocalEntry;

const ANY = 'any signed-in person';
const STAFF = 'staff of a business (the function checks membership)';
const OWNER = 'owner of an approved business (the function checks)';

const db = (alias: string, e: Omit<DbEntry, 'kind' | 'alias' | 'fn'> & { fn?: string }): DbEntry => ({ kind: 'db', alias, fn: e.fn ?? alias, ...e });
const sec = (alias: string, e: Omit<SecureEntry, 'kind' | 'alias' | 'handler'>): SecureEntry => ({ kind: 'secure', alias, handler: (secureHandlers as Record<string, SecureHandler>)[alias], ...e });
const P = (a: unknown) => ({ p: a });
const links = (r: unknown) => withImageLinks(r);
const links2 = (r: unknown) => withStorefrontLinks(r);
const STOREFRONT = 'owner, admin, manager, business manager, location manager, operations or marketing manager (the function checks)';

const empty = { rate: 'read' as Rate, args: 'passthrough' as const };

export const MANIFEST: Entry[] = [
  // ---- identity
  sec('me', { rate: 'read', args: 'passthrough', roles: 'staff of a business' }),

  // ---- onboarding (a person with no business yet) — database: 0348 via the 0360 gw_ wrappers
  { kind: 'local', alias: 'static_taxonomy', args: 'passthrough', rate: 'read', roles: ANY, run: () => ob.lists() },   // static lists, no database
  db('partner_app_get', { fn: 'gw_partner_app_get', ...empty, map: () => ({}), roles: ANY }),
  db('partner_app_save_profile', { fn: 'gw_partner_app_save_profile', args: ob.Profile, map: a => P(ob.profileArgs(a)), rate: 'write', roles: ANY }),
  db('partner_app_choose_plan', { fn: 'gw_partner_app_choose_plan', args: ob.Plan, map: a => ({ p_plan: a.plan }), rate: 'write', roles: ANY }),
  db('partner_app_save_address', { fn: 'gw_partner_app_save_address', args: ob.Address, map: P, rate: 'write', roles: ANY }),
  db('partner_app_save_identity', { fn: 'gw_partner_app_save_identity', args: ob.Identity, map: P, rate: 'write', roles: ANY }),
  db('partner_app_save_consents', { fn: 'gw_partner_app_save_consents', args: ob.Consents, map: P, rate: 'write', roles: ANY }),
  db('partner_app_accept_agreement', { fn: 'gw_partner_app_accept_agreement', args: ob.Agreement, map: a => ({ p_version: a.version, p_ack: a.acknowledged }), rate: 'write', roles: ANY }),
  db('partner_app_submit', { fn: 'gw_partner_app_submit', ...empty, rate: 'write', map: () => ({}), roles: ANY }),
  sec('partner_app_save_tax', { args: ob.Tax, rate: 'secure', roles: ANY }),
  sec('partner_app_save_bank', { args: ob.Bank, rate: 'secure', roles: ANY }),
  sec('partner_app_document_slot', { args: ob.UploadAsk, rate: 'secure', roles: ANY }),
  sec('partner_app_document_attach', { args: ob.Attach, rate: 'secure', roles: ANY }),
  sec('partner_app_document_preview', { args: ob.PreviewAsk, rate: 'secure', roles: ANY }),

  // ---- workspace setup after approval — database: 0350 via 0360. Results carry storage paths for listing images: post turns them into links.
  db('partner_setup_get', { fn: 'gw_partner_setup_get', ...empty, map: () => ({}), post: links, roles: OWNER }),
  db('partner_setup_confirm_plan', { fn: 'gw_partner_setup_confirm_plan', args: su.ConfirmPlan, map: a => ({ p_plan_code: a.plan_code || null }), post: links, rate: 'write', roles: OWNER }),
  db('partner_setup_save_tax', { fn: 'gw_partner_setup_save_tax', args: su.Tax, map: P, post: links, rate: 'write', roles: OWNER }),
  db('partner_setup_register_pos', { fn: 'gw_partner_setup_register_pos', args: su.Pos, map: P, post: links, rate: 'write', roles: OWNER }),
  db('partner_setup_invite_staff', { fn: 'gw_partner_setup_invite_staff', args: su.Staff, map: P, post: links, rate: 'write', roles: OWNER }),
  db('partner_setup_add_item', { fn: 'gw_partner_setup_add_item', args: su.Item, map: P, post: links, rate: 'write', roles: OWNER }),
  db('partner_setup_save_listing', { fn: 'gw_partner_setup_save_listing', args: su.Listing, map: P, post: links, rate: 'write', roles: OWNER }),
  db('partner_setup_save_fulfilment', { fn: 'gw_partner_setup_save_fulfilment', args: su.Fulfilment, map: P, post: links, rate: 'write', roles: OWNER }),
  db('partner_setup_tour_seen', { fn: 'gw_partner_setup_tour_seen', args: su.Tour, map: a => ({ p_step: a.step }), post: links, rate: 'write', roles: OWNER }),
  db('partner_setup_complete', { fn: 'gw_partner_setup_complete', ...empty, rate: 'write', map: () => ({}), post: links, roles: OWNER }),
  sec('partner_setup_save_payment', { args: su.Payment, rate: 'secure', roles: OWNER }),
  sec('partner_setup_image_slot', { args: su.ImageAsk, rate: 'secure', roles: OWNER }),
  sec('partner_setup_image_attach', { args: su.ImageAttach, rate: 'secure', roles: OWNER }),

  // ---- POS counter bill and order lifecycle (0370, 0371). Body = the function's `p` object; the database validates and checks role/location.
  db('pos_quote_order', { args: 'passthrough', map: P, rate: 'read', roles: STAFF }),
  db('pos_order_history', { args: 'passthrough', map: P, rate: 'read', roles: STAFF }),
  db('pos_order_view', { args: 'passthrough', map: P, rate: 'read', roles: STAFF }),
  db('pos_checkout', { args: 'passthrough', map: P, rate: 'money', idem: true, roles: 'staff allowed to place orders' }),
  db('pos_checkout_pay', { args: 'passthrough', map: P, rate: 'money', idem: true, roles: 'staff allowed to take payment' }),
  db('pos_set_order_status', { args: 'passthrough', map: P, rate: 'write', roles: 'staff with order.update_status' }),
  db('pos_fulfilment_act', { args: 'passthrough', map: P, rate: 'write', idem: true, roles: 'staff with order.update_status' }),
  db('pos_refund', { args: 'passthrough', map: P, rate: 'money', idem: true, roles: 'manager roles only' }),
  // ---- the till on top of the counter bill, section F (0380-0383). Body = the function's `p` object; the database checks organisation,
  //      store, role and every amount. Money calls carry the Idempotency-Key header; manager-only rules answer 403 for anyone else.
  db('pos_sell_catalog', { args: sell.Catalog, map: P, rate: 'read', roles: STAFF }),
  db('pos_receipt_list', { args: sell.Receipts, map: P, rate: 'read', roles: STAFF }),
  db('pos_split_pay', { args: sell.SplitPay, map: P, rate: 'money', idem: true, roles: 'staff allowed to take payment' }),
  db('pos_payment_attempt_record', { args: sell.Attempt, map: P, rate: 'write', roles: 'staff allowed to take payment' }),
  db('pos_online_checkout', { args: sell.OnlineCheckout, map: P, rate: 'money', roles: 'staff allowed to take payment' }),
  db('pos_return_list', { args: sell.ReturnList, map: P, rate: 'read', roles: STAFF }),
  db('pos_return_create', { args: sell.ReturnCreate, map: P, rate: 'write', idem: true, roles: 'staff allowed to take payment' }),
  db('pos_return_decide', { args: sell.ReturnDecide, map: P, rate: 'write', roles: 'manager roles only' }),
  db('pos_return_issue_refund', { args: sell.ReturnRefund, map: P, rate: 'money', idem: true, roles: 'manager roles only' }),
  db('pos_coupon_list', { args: sell.CouponList, map: P, rate: 'read', roles: STAFF }),
  db('pos_coupon_save', { args: sell.CouponSave, map: P, rate: 'write', roles: 'manager roles only' }),
  db('pos_home_online', { args: 'passthrough', map: P, rate: 'read', roles: STAFF }),
  db('pos_home_channel', { args: 'passthrough', map: () => ({}), rate: 'read', roles: STAFF }),
  // ---- Orders tab: Live orders and Hold orders (0530-0531). Resume POS = pos_hold_update (same order, re-priced lines), then pos_checkout_pay.
  //      Save & Hold with a reason is POST /api/partner/pos-orders/hold (pos_hold_place); cancel stays pos_set_order_status.
  db('pos_orders_board', { args: ord.Board, map: P, rate: 'read', roles: STAFF }),
  db('pos_hold_list', { args: ord.HoldList, map: P, rate: 'read', roles: STAFF }),
  db('pos_hold_update', { args: ord.HoldUpdate, map: P, rate: 'write', idem: true, roles: 'staff allowed to place orders' }),
  // ---- store inventory, section H (0400-0403). Body = the function's `p` object (location_id, ids, filters); the database validates it and
  //      checks organisation, location and role (inventory:read / record / approve). Writes carry the Idempotency-Key header.
  db('inv_options', { args: inv.Options, map: P, rate: 'read', roles: 'staff who may see or record stock' }),
  db('inv_dashboard', { args: inv.Dashboard, map: P, rate: 'read', roles: 'staff with inventory:read' }),
  db('inv_stock_list', { args: inv.StockList, map: P, rate: 'read', roles: 'staff with inventory:read' }),
  db('inv_stock_detail', { args: inv.StockDetail, map: P, rate: 'read', roles: 'staff with inventory:read' }),
  db('inv_movement_list', { args: inv.MovementList, map: P, rate: 'read', roles: 'staff with inventory:read' }),
  db('inv_movement_detail', { args: inv.MovementDetail, map: P, rate: 'read', roles: 'staff with inventory:read' }),
  db('inv_document_list', { args: inv.DocumentList, map: P, rate: 'read', roles: 'staff with inventory:read or record' }),
  db('inv_document_view', { args: inv.DocumentView, map: P, rate: 'read', roles: 'staff with inventory:read or record' }),
  db('inv_forecast', { args: inv.Forecast, map: P, rate: 'read', roles: 'staff with inventory:read' }),
  db('inv_document_save', { args: inv.DocumentSave, map: P, rate: 'write', idem: true, roles: 'staff with inventory:record' }),
  db('inv_document_act', { args: inv.DocumentAct, map: P, rate: 'write', idem: true, roles: 'inventory:record (inventory:approve to approve or reject)' }),
  db('inv_audit_to_adjustment', { args: inv.AuditToAdjustment, map: P, rate: 'write', idem: true, roles: 'staff with inventory:record' }),
  // ---- kitchen stations and the kitchen display, section H (0480, 0481). Body = the function's `p` object; the database checks organisation,
  //      location and role (kitchen:view / kitchen:configure; order.update_status to act on a ticket). Writes carry the Idempotency-Key header.
  db('kitchen_config', { args: kit.Config, map: P, rate: 'read', roles: 'staff with kitchen:view' }),
  db('kitchen_station_view', { args: kit.StationView, map: P, rate: 'read', roles: 'staff with kitchen:view' }),
  db('kitchen_station_save', { args: kit.StationSave, map: P, rate: 'write', idem: true, roles: 'staff with kitchen:configure' }),
  db('kds_queue', { args: kit.Queue, map: P, rate: 'read', roles: 'staff with kitchen:view' }),
  db('kds_ticket_act', { args: kit.TicketAct, map: P, rate: 'write', idem: true, roles: 'staff with order.update_status' }),
  // ---- store catalogue and goods-received (GRN) matching, section G (0390, 0391, 0409). Body = the function's `p` object; the database
  //      checks organisation, location and role (menu:create / menu:update, inventory:record / inventory:approve). The sell screen's search
  //      is cat_item_list with status 'active'. Helpers (cat_stock_map, cat_location, cat_item_json, grn_rows, grn_totals, grn_signature,
  //      grn_person, grn_receipt, the triggers) are not executable by `authenticated` and stay off this list.
  db('cat_item_list', { args: cat.List, map: P, rate: 'read', roles: STAFF }),
  db('cat_item_view', { args: cat.View, map: P, rate: 'read', roles: STAFF }),
  db('cat_item_lookup', { args: cat.Lookup, map: P, rate: 'read', roles: STAFF }),
  db('cat_item_save', { args: cat.Save, map: P, rate: 'write', idem: true, roles: 'staff with menu:create (new) or menu:update (change)' }),
  // Item form "Remove background (AI)": remove.bg with REMOVE_BG_API_KEY (server only); a photo up to 5 MB, nothing saved.
  sec('cat_image_remove_bg', { args: cat.RemoveBg, rate: 'secure', roles: 'active staff of a business (checked on the server)', maxBytes: 7 * 1024 * 1024 + 64 * 1024 }),
  db('grn_list', { args: grn.List, map: P, rate: 'read', roles: STAFF }),
  db('grn_view', { args: grn.Receipt, map: P, rate: 'read', roles: STAFF }),
  db('grn_matching_view', { args: grn.Receipt, map: P, rate: 'read', roles: STAFF }),
  db('grn_open', { args: grn.Receipt, map: P, rate: 'write', roles: 'staff with inventory:record' }),
  db('grn_invoice_save', { args: grn.Invoice, map: P, rate: 'write', roles: 'staff with inventory:record' }),
  db('grn_costs_save', { args: grn.Costs, map: P, rate: 'write', roles: 'staff with inventory:record' }),
  db('grn_resolve', { args: grn.Resolve, map: P, rate: 'write', roles: 'staff with inventory:record' }),
  db('grn_request_approval', { args: grn.RequestApproval, map: P, rate: 'write', roles: 'staff with inventory:record' }),
  db('grn_decide', { args: grn.Decide, map: P, rate: 'write', roles: 'inventory:approve; approving posts the receipt through section H' }),
  // ---- tables and floor, section H (0404). Body = the function's `p` object (location_id, table ids); the database validates it and checks
  //      organisation, store and role (order:place for reserving; order:place + order:update_status or dining_tables:manage for transfer / merge / split).
  db('tbl_floor', { args: tbl.Floor, map: P, rate: 'read', roles: 'floor staff (order place / update status, or table manager)' }),
  db('tbl_view', { args: tbl.TableRef, map: P, rate: 'read', roles: 'floor staff' }),
  db('tbl_order_view', { args: tbl.TableRef, map: P, rate: 'read', roles: 'floor staff' }),
  db('tbl_history', { args: tbl.History, map: P, rate: 'read', roles: 'floor staff' }),
  db('tbl_reserve', { args: tbl.Reserve, map: P, rate: 'write', idem: true, roles: 'staff with order:place (or table manager)' }),
  db('tbl_reserve_cancel', { args: tbl.ReserveCancel, map: P, rate: 'write', roles: 'staff with order:place (or table manager)' }),
  db('tbl_transfer', { args: tbl.Transfer, map: P, rate: 'write', roles: 'staff who can place and move orders, or a table manager' }),
  db('tbl_merge', { args: tbl.Merge, map: P, rate: 'write', roles: 'staff who can place and move orders, or a table manager' }),
  db('tbl_split', { args: tbl.Split, map: P, rate: 'write', roles: 'staff who can place and move orders, or a table manager' }),
  // ---- take an order at a table (0485): add dishes (send or hold), send held dishes, Ready to serve, Mark as served. Writes carry the Idempotency-Key
  //      header (the database refuses a reused key with another body); Mark as served is safe to repeat (dishes already served are counted, not refused).
  db('tbl_order_add', { args: tbl.OrderAdd, map: P, rate: 'write', idem: true, roles: 'staff with order:place' }),
  db('tbl_kot_send', { args: tbl.KotSend, map: P, rate: 'write', idem: true, roles: 'staff with order:place or order:update_status' }),
  db('tbl_ready_list', { args: tbl.ReadyList, map: P, rate: 'read', roles: 'floor staff' }),
  db('tbl_mark_served', { args: tbl.MarkServed, map: P, rate: 'write', roles: 'staff with order:update_status' }),
  // ---- back office, section J (0420): Low Stock and Purchase Suggestions, read from section H's stock numbers. Body = the function's `p`
  //      object; no location_id = the whole business, which the database allows only for a business-wide person.
  db('backoffice_low_stock', { args: bo.LowStock, map: P, rate: 'read', roles: 'staff with inventory:read' }),
  db('purchase_suggestions_list', { args: bo.SuggestionsList, map: P, rate: 'read', roles: 'staff with inventory:read' }),
  db('purchase_suggestions_refresh', { args: bo.SuggestionsRefresh, map: P, rate: 'write', roles: 'owner, managers, inventory and procurement roles' }),
  db('purchase_suggestions_close', { args: bo.SuggestionsClose, map: P, rate: 'write', idem: true, roles: 'owner, managers, inventory and procurement roles' }),
  // ---- Service POS, section I (0410-0413). Body = the function's `p` object; the database checks organisation, location and role
  //      (book: owner/admin/manager/biller/captain/...; manage: owner/admin/manager). Writes carry the Idempotency-Key header and the
  //      database refuses a replayed key with a different body (OL_IDEMPOTENCY_MISMATCH).
  db('svc_catalogue', { args: svc.Catalogue, map: P, rate: 'read', roles: 'staff who may book' }),
  db('svc_dashboard', { args: svc.Dashboard, map: P, rate: 'read', roles: 'staff who may book' }),
  // ---- Restaurant dashboard (0491): the home screen of a restaurant; each block is read as the caller, a block the role may not read is null.
  db('rst_dashboard', { args: rst.Dashboard, map: P, rate: 'read', roles: 'floor staff (order place / update status, or table manager)' }),
  // ---- Restaurant menu and dish detail (0540-0541): reads for any staff member, writes need menu.update. Write with AI is a secure handler
  //      (ANTHROPIC_API_KEY on this server; the database gates who, the dish facts and the per-business rate limit; nothing is saved by it).
  db('rst_menu', { args: rst.Menu, map: P, rate: 'read', roles: STAFF }),
  db('rst_menu_item_view', { args: rst.MenuItemView, map: P, rate: 'read', roles: STAFF }),
  db('rst_menu_item_save', { args: rst.MenuItemSave, map: P, rate: 'write', roles: 'menu editors (menu.update)' }),
  db('rst_menu_stock_set', { args: rst.MenuStockSet, map: P, rate: 'write', roles: 'menu editors (menu.update)' }),
  sec('menu_ai_describe', { args: rst.AiDescribe, rate: 'secure', roles: 'menu editors (menu.update; checked in the database)', maxBytes: 8 * 1024 }),
  // ---- Restaurant bill and pay (0550): the bill of a table, split it per guest, pay a part or the whole bill (money, idempotent: a part is never
  //      paid twice), discount code on a placed bill, kitchen note, receipt view and send log. Roles and amounts are the database's.
  db('rst_bill_view', { args: rst.BillView, map: P, rate: 'read', roles: 'floor staff (order place / update status, or table manager)' }),
  db('rst_bill_split', { args: rst.BillSplit, map: P, rate: 'write', idem: true, roles: 'staff allowed to take payment' }),
  db('rst_bill_pay', { args: rst.BillPay, map: P, rate: 'money', idem: true, roles: 'staff allowed to take payment' }),
  db('rst_bill_coupon', { args: rst.BillCoupon, map: P, rate: 'write', roles: 'staff allowed to take payment' }),
  db('rst_bill_note', { args: rst.BillNote, map: P, rate: 'write', roles: 'staff with order:place or order:update_status' }),
  db('rst_receipt_view', { args: rst.BillOrder, map: P, rate: 'read', roles: 'floor staff or staff allowed to take payment' }),
  db('rst_receipt_log', { args: rst.ReceiptLog, map: P, rate: 'write', roles: 'floor staff or staff allowed to take payment' }),
  db('svc_calendar', { args: svc.Calendar, map: P, rate: 'read', roles: STAFF }),
  db('svc_quote', { args: svc.Quote, map: P, rate: 'read', roles: 'staff who may book' }),
  db('svc_slots', { args: svc.Slots, map: P, rate: 'read', roles: 'staff who may book' }),
  db('svc_appointment_view', { args: svc.View, map: P, rate: 'read', roles: STAFF }),
  db('svc_history', { args: svc.History, map: P, rate: 'read', roles: 'staff who may book' }),
  db('svc_service_list', { args: svc.ServiceList, map: P, rate: 'read', roles: 'staff who may book' }),
  db('svc_service_detail', { args: svc.View, map: P, rate: 'read', roles: 'staff who may book' }),
  db('svc_staff_list', { args: svc.StaffList, map: P, rate: 'read', roles: 'staff who may book' }),
  db('svc_schedule', { args: svc.Schedule, map: P, rate: 'read', roles: 'staff who may book' }),
  db('svc_plan_list', { args: svc.PlanList, map: P, rate: 'read', roles: 'staff who may book' }),
  db('svc_entitlements_for', { args: svc.EntitlementsFor, map: P, rate: 'read', roles: 'staff who may book' }),
  db('svc_book', { args: svc.Book, map: P, rate: 'money', idem: true, roles: 'staff who may book' }),
  db('svc_appointment_act', { args: svc.Act, map: P, rate: 'money', idem: true, roles: 'staff who may book (keeping an advance: manager)' }),
  db('svc_job_update', { args: svc.JobUpdate, map: P, rate: 'write', idem: true, roles: 'staff who may book' }),
  db('svc_bill', { args: svc.Bill, map: P, rate: 'money', idem: true, roles: 'staff who may book' }),
  db('svc_entitlement_sell', { args: svc.Sell, map: P, rate: 'money', idem: true, roles: 'staff who may book' }),
  db('svc_service_save', { args: svc.ServiceSave, map: P, rate: 'write', idem: true, roles: 'manager roles only' }),
  db('svc_provider_save', { args: svc.ProviderSave, map: P, rate: 'write', idem: true, roles: 'manager roles only' }),
  db('svc_schedule_save', { args: svc.ScheduleSave, map: P, rate: 'write', idem: true, roles: 'manager roles only' }),
  db('svc_plan_save', { args: svc.PlanSave, map: P, rate: 'write', idem: true, roles: 'manager roles only' }),
  db('pur_options', { args: pur.Options, map: P, rate: 'read', roles: 'staff with purchasing:read' }),
  db('pur_po_list', { args: pur.PoList, map: P, rate: 'read', roles: 'staff with purchasing:read' }),
  db('pur_po_view', { args: pur.PoView, map: P, rate: 'read', roles: 'staff with purchasing:read' }),
  db('pur_price_view', { args: pur.PriceView, map: P, rate: 'read', roles: 'staff with purchasing:read' }),
  db('pur_po_create', { args: pur.PoCreate, map: P, rate: 'write', idem: true, roles: 'staff with purchasing:record' }),
  db('pur_po_act', { args: pur.PoAct, map: P, rate: 'write', roles: 'purchasing:record (submit, cancel a draft or pending order); purchasing:approve_po (approve, reject, cancel an approved order)' }),
  db('pur_po_receive', { args: pur.PoReceive, map: P, rate: 'write', idem: true, roles: 'purchasing:record and inventory:record' }),
  db('pur_sourcing_select', { args: pur.SourcingSelect, map: P, rate: 'write', idem: true, roles: 'staff with purchasing:approve' }),
  db('pur_audit_record', { args: pur.AuditRecord, map: P, rate: 'write', idem: true, roles: 'staff with purchasing:record' }),
  // ---- money, section K (0435). Body = the function's `p` object; the database checks organisation, location and permission (money:read / record /
  //      approve; settlements, payouts and reports need the organisation-level settlements:read / payouts:read). Writes carry the Idempotency-Key header.
  db('money_options', { args: mo.Options, map: P, rate: 'read', roles: ANY }),
  db('money_overview', { args: mo.Window, map: P, rate: 'read', roles: 'staff with money:read' }),
  db('money_payments_list', { args: mo.Payments, map: P, rate: 'read', roles: 'staff with money:read' }),
  db('money_transactions_list', { args: mo.Transactions, map: P, rate: 'read', roles: 'staff with money:read' }),
  db('money_invoices_list', { args: mo.Invoices, map: P, rate: 'read', roles: 'staff with money:read' }),
  db('money_cashbook', { args: mo.Day, map: P, rate: 'read', roles: 'staff with money:read' }),
  db('money_expenses_list', { args: mo.Expenses, map: P, rate: 'read', roles: 'staff with money:read' }),
  db('money_refunds_list', { args: mo.Refunds, map: P, rate: 'read', roles: 'staff with money:read' }),
  db('money_settlements_list', { args: mo.Settlements, map: P, rate: 'read', roles: 'whole-business roles with settlements:read' }),
  db('money_settlement_detail', { args: mo.IdOnly, map: P, rate: 'read', roles: 'whole-business roles with settlements:read' }),
  db('money_payouts_list', { args: mo.Payouts, map: P, rate: 'read', roles: 'whole-business roles with payouts:read' }),
  db('money_reports', { args: mo.Window, map: P, rate: 'read', roles: 'whole-business roles with settlements:read and payment_ledger:read' }),
  db('money_report_rows', { args: mo.ReportRows, map: P, rate: 'read', roles: 'staff with the permission of that report' }),
  db('money_expense_record', { args: mo.ExpenseRecord, map: P, rate: 'money', idem: true, roles: 'staff with money:record' }),
  db('money_expense_void', { args: mo.Void, map: P, rate: 'money', idem: true, roles: 'staff with money:approve' }),
  db('money_cash_record', { args: mo.CashRecord, map: P, rate: 'money', idem: true, roles: 'staff with money:record' }),
  db('money_cash_void', { args: mo.Void, map: P, rate: 'money', idem: true, roles: 'staff with money:approve' }),
  db('money_party_record', { args: mo.PartyRecord, map: P, rate: 'money', idem: true, roles: 'staff with money:record' }),
  db('money_adjustment_request', { args: mo.AdjustmentRequest, map: P, rate: 'money', idem: true, roles: 'staff with money:record' }),
  db('money_adjustment_decide', { args: mo.AdjustmentDecide, map: P, rate: 'money', idem: true, roles: 'staff with money:approve (not the requester)' }),
  db('money_invoice_pay', { args: mo.InvoicePay, map: P, rate: 'money', idem: true, roles: 'staff with money:record' }),
  db('money_invoice_set_due', { args: mo.InvoiceDue, map: P, rate: 'write', roles: 'staff with money:record' }),
  // ---- team, section L (0440). Body = the function's `p` object; the database checks organisation, place and role (owner/admin invite and change people;
  //      managers read and run tasks; the assigned person starts and submits their own). Roles are read-only here. No pay or bank data is ever returned.
  db('team_options', { args: team.Options, map: P, rate: 'read', roles: 'staff who may open the team (pos_staff:read or org_invitations:manage)' }),
  db('team_dashboard', { args: team.Dashboard, map: P, rate: 'read', roles: 'staff who may open the team' }),
  db('team_user_list', { args: team.UserList, map: P, rate: 'read', roles: 'staff who may open the team' }),
  db('team_user_view', { args: team.UserView, map: P, rate: 'read', roles: 'staff who may open the team' }),
  db('team_role_view', { args: team.RoleView, map: P, rate: 'read', roles: 'staff who may open the team' }),
  db('team_activity', { args: team.Activity, map: P, rate: 'read', roles: 'audit_logs:read or pos_audit_log:read or org_invitations:manage' }),
  db('team_task_list', { args: team.TaskList, map: P, rate: 'read', roles: 'task managers (all tasks); the assigned person (own tasks)' }),
  db('team_task_view', { args: team.TaskView, map: P, rate: 'read', roles: 'task managers; the assigned person' }),
  db('team_invite', { args: team.Invite, map: P, rate: 'write', roles: 'owner or admin (org_invitations:manage); only an owner invites an owner or admin' }),
  db('team_invite_act', { args: team.InviteAct, map: P, rate: 'write', roles: 'owner or admin (org_invitations:manage)' }),
  db('team_user_act', { args: team.UserAct, map: P, rate: 'write', roles: 'owner or admin (org_invitations:manage); never on yourself' }),
  db('team_task_save', { args: team.TaskSave, map: P, rate: 'write', idem: true, roles: 'task managers (owner, admin, manager, business / operations / location manager)' }),
  db('team_task_act', { args: team.TaskAct, map: P, rate: 'write', roles: 'task managers; the assigned person may start and submit' }),
  // ---- storefront, section M (0450-0451). Body = the function's `p` object; the database validates it and checks organisation and role
  //      (owner / admin / manager / marketing roles edit; storefront:publish publishes). Results carry storage paths: post turns them into short links.
  //      Pictures go through the two secure handlers below (signed slot, then confirm); the app never holds a storage key.
  db('sf_options', { args: sf.None, map: P, rate: 'read', roles: STOREFRONT }),
  db('sf_builder_get', { args: sf.None, map: P, rate: 'read', roles: STOREFRONT }),
  db('sf_settings_get', { args: sf.None, map: P, rate: 'read', post: links2, roles: STOREFRONT }),
  db('sf_products', { args: sf.Products, map: P, rate: 'read', post: links2, roles: STOREFRONT }),
  db('sf_preview', { args: sf.Preview, map: P, rate: 'read', post: links2, roles: STOREFRONT }),
  db('sf_image_library', { args: sf.ImageLibrary, map: P, rate: 'read', post: links2, roles: STOREFRONT }),
  db('sf_offer_list', { args: sf.None, map: P, rate: 'read', roles: STOREFRONT }),
  db('sf_ad_list', { args: sf.None, map: P, rate: 'read', post: links2, roles: STOREFRONT }),
  db('sf_draft_save', { args: sf.DraftSave, map: P, rate: 'write', roles: STOREFRONT }),
  db('sf_draft_discard', { args: sf.DraftDiscard, map: P, rate: 'write', roles: STOREFRONT }),
  db('sf_publish', { args: sf.Publish, map: P, rate: 'write', roles: 'staff with storefront:publish' }),
  db('sf_product_save', { args: sf.ProductSave, map: P, rate: 'write', post: links2, roles: 'storefront roles; catalogue facts need menu:update' }),
  db('sf_profile_save', { args: 'passthrough', map: P, rate: 'write', post: links2, roles: STOREFRONT }),
  db('sf_hours_save', { args: 'passthrough', map: P, rate: 'write', post: links2, roles: STOREFRONT }),
  db('sf_delivery_save', { args: 'passthrough', map: P, rate: 'write', post: links2, roles: STOREFRONT }),
  db('sf_offer_save', { args: 'passthrough', map: P, rate: 'write', roles: STOREFRONT }),
  db('sf_offer_act', { args: sf.OfferAct, map: P, rate: 'write', roles: STOREFRONT }),
  db('sf_ad_save', { args: 'passthrough', map: P, rate: 'write', post: links2, roles: STOREFRONT }),
  db('sf_ad_act', { args: sf.AdAct, map: P, rate: 'write', post: links2, roles: STOREFRONT }),
  sec('storefront_image_slot', { args: sf.ImageAsk, rate: 'secure', roles: STOREFRONT }),
  sec('storefront_image_attach', { args: sf.ImageAttach, rate: 'secure', roles: STOREFRONT }),
  // ---- customer communication, section N (0460). Notices and announcements are for any signed-in staff (the database filters by role and place);
  //      customer messages are RECORDED AND QUEUED only (nothing is sent); the database checks pos_campaigns:read / send and pos_customer_feedback:read / respond.
  db('notice_list', { args: nt.NoticeList, map: P, rate: 'read', roles: STAFF }),
  db('notice_mark_read', { args: nt.NoticeMarkRead, map: P, rate: 'write', roles: STAFF }),
  db('announce_list', { args: nt.AnnounceList, map: P, rate: 'read', roles: STAFF }),
  db('announce_mark_read', { args: nt.AnnounceMarkRead, map: P, rate: 'write', roles: STAFF }),
  db('comm_options', { args: nt.CommOptions, map: P, rate: 'read', roles: 'staff with pos_campaigns:read' }),
  db('comm_audience', { args: nt.CommAudience, map: P, rate: 'read', roles: 'staff with pos_campaigns:read' }),
  db('comm_queue', { args: nt.CommQueue, map: P, rate: 'write', idem: true, roles: 'staff with pos_campaigns:send' }),
  db('comm_list', { args: nt.CommList, map: P, rate: 'read', roles: 'staff with pos_campaigns:read' }),
  db('comm_cancel', { args: nt.CommCancel, map: P, rate: 'write', roles: 'staff with pos_campaigns:send' }),
  db('comm_feedback_list', { args: nt.FeedbackList, map: P, rate: 'read', roles: 'staff with pos_customer_feedback:read' }),
  db('comm_feedback_respond', { args: nt.FeedbackRespond, map: P, rate: 'write', roles: 'staff with pos_customer_feedback:respond' }),
  // ---- settings and store profile, section P (0470). Body = the function's `p` object; the database checks the caller's business and role
  //      (read: any active person; save: owner, admin, business manager, manager; bank only owner and admin). Bank numbers are saved by the
  //      existing secure handler partner_setup_save_payment and are never returned.
  db('pos_settings_get', { args: st.Empty, map: P, rate: 'read', roles: STAFF }),
  db('pos_settings_save_hours', { args: st.Hours, map: P, rate: 'write', roles: 'owner or manager' }),
  db('pos_settings_save_readiness', { args: st.Readiness, map: P, rate: 'write', roles: 'owner or manager' }),
  db('pos_settings_save_help', { args: st.Help, map: P, rate: 'write', roles: 'owner or manager' }),
  db('pos_settings_save_owner', { args: st.Owner, map: P, rate: 'write', roles: 'owner or manager' }),
  db('pos_settings_save_staff_phone', { args: st.StaffPhone, map: P, rate: 'write', roles: 'owner or manager' }),
  db('pos_settings_set_pickup', { args: st.Switch, map: P, rate: 'write', roles: 'owner or manager' }),
  db('pos_settings_set_qr_checkout', { args: st.Switch, map: P, rate: 'write', roles: 'owner or manager' }),
  db('pos_settings_save_location', { args: st.Location, map: P, rate: 'write', roles: 'owner or manager' }),
  db('pos_settings_save_language', { args: st.Language, map: P, rate: 'write', roles: 'owner or manager' }),
  db('pos_settings_documents', { args: st.Empty, map: P, rate: 'read', roles: 'owner, admin, managers, finance' }),
  db('pos_settings_document_remove', { args: st.DocumentRemove, map: P, post: dropRemovedFile, rate: 'write', roles: 'owner or manager' }),
  db('pos_settings_remove_qr', { args: st.Empty, map: P, post: dropRemovedFile, rate: 'write', roles: 'owner or manager' }),
  db('pos_support_list', { args: st.Empty, map: P, rate: 'read', roles: STAFF }),
  db('pos_support_create', { args: st.SupportCreate, map: P, rate: 'write', idem: true, roles: STAFF }),
  { kind: 'local', alias: 'pos_help_content', args: 'passthrough', rate: 'read', roles: ANY, run: () => helpContent() },   // static FAQ, no database
  sec('pos_settings_file_slot', { args: st.FileAsk, rate: 'secure', roles: STAFF }),
  sec('pos_settings_file_attach', { args: st.FileAttach, rate: 'secure', roles: STAFF }),
  sec('pos_settings_file_link', { args: st.FileLink, rate: 'secure', roles: STAFF }),
  // ---- Customers, One Local Wallet, Manage account (0510-0512). Body = the function's `p` object; the database checks organisation, outlet and
  //      role (customers: order:place, edit pos_customers:manage; wallet: settlements:read; account: the signed-in person only).
  db('cust_list', { args: cu.List, map: P, rate: 'read', roles: 'staff who may place orders, or customer managers' }),
  db('cust_lookup', { args: cu.Lookup, map: P, rate: 'read', roles: 'staff who may place orders, or customer managers' }),
  db('cust_view', { args: cu.View, map: P, rate: 'read', roles: 'staff who may place orders, or customer managers' }),
  db('cust_save', { args: cu.Save, map: P, rate: 'write', roles: 'new: order:place; change: pos_customers:manage' }),
  db('cust_attach_order', { args: cu.Attach, map: P, rate: 'write', roles: 'order:place (changing a set customer: order:adjust_bill)' }),
  db('wallet_overview', { args: cu.WalletOverview, map: P, rate: 'read', roles: 'owner and finance roles (settlements:read)' }),
  db('wallet_movements', { args: cu.WalletMovements, map: P, rate: 'read', roles: 'owner and finance roles (settlements:read)' }),
  db('wallet_settlement_view', { args: cu.WalletSettlement, map: P, rate: 'read', roles: 'owner and finance roles (settlements:read)' }),
  db('acct_get', { ...empty, map: () => ({}), roles: ANY }),
  db('acct_save_name', { args: cu.SaveName, map: P, rate: 'write', roles: ANY }),
  db('acct_sync_contact', { ...empty, rate: 'write', map: () => ({}), roles: ANY }),
  db('acct_signed_out_everywhere', { ...empty, rate: 'write', map: () => ({}), roles: ANY }),
  // ---- store cash shift, payment pending, refund check (0500-0502). Body = the function's `p` object; the database checks organisation,
  //      store, role and every amount. Writes carry the Idempotency-Key header; approving a cash difference is manager-only (403 otherwise).
  db('pos_shift_current', { args: sh.Current, map: P, rate: 'read', roles: STAFF }),
  db('pos_shift_list', { args: sh.List, map: P, rate: 'read', roles: STAFF }),
  db('pos_shift_open', { args: sh.Open, map: P, rate: 'money', idem: true, roles: 'staff allowed to take payment' }),
  db('pos_shift_cash_move', { args: sh.CashMove, map: P, rate: 'money', idem: true, roles: 'staff allowed to take payment' }),
  db('pos_shift_close', { args: sh.Close, map: P, rate: 'money', idem: true, roles: 'staff allowed to take payment' }),
  db('pos_shift_approve', { args: sh.Approve, map: P, rate: 'money', roles: 'manager roles only, not the person who counted' }),
  db('pos_till_policy_set', { args: sh.Policy, map: P, rate: 'write', roles: 'manager roles only' }),
  db('pos_payment_start', { args: sh.PayStart, map: P, rate: 'money', idem: true, roles: 'staff allowed to take payment' }),
  db('pos_payment_confirm', { args: sh.PayConfirm, map: P, rate: 'money', roles: 'staff allowed to take payment' }),
  db('pos_payment_fail', { args: sh.PayFail, map: P, rate: 'write', roles: 'staff allowed to take payment' }),
  db('pos_payment_status', { args: sh.PayStatus, map: P, rate: 'read', roles: STAFF }),
  db('pos_refund_check', { args: sh.RefundCheck, map: P, rate: 'read', roles: STAFF }),
  // ---- table QR codes and guest orders (0560, 0561; spec specs/table-qr-guest-menu). Body = the function's `p` object; the database checks
  //      organisation, store and role (floor staff read; table managers issue / replace / switch codes; order:place accepts guest orders).
  //      The guest's own calls do not come through here: they use the guest door (src/guest-door.ts, POST /guest/<name>).
  db('menu_link_get', { args: st.Empty, map: P, rate: 'read', roles: 'any member of the business (its public menu link and why it is not live)' }),
  db('tbl_qr_list', { args: gst.QrList, map: P, rate: 'read', roles: 'floor staff (the code itself: table managers only)' }),
  db('tbl_qr_issue', { args: gst.QrIssue, map: P, rate: 'write', roles: 'table managers; replacing names the table' }),
  db('tbl_qr_set_enabled', { args: gst.QrEnabled, map: P, rate: 'write', roles: 'table managers' }),
  db('guest_requests_list', { args: gst.Requests, map: P, rate: 'read', roles: 'floor staff' }),
  db('guest_request_decide', { args: gst.Decide, map: P, rate: 'write', roles: 'staff with order:place (accepting places the order as them)' }),
  db('guest_staff_menu', { args: gst.StaffMenu, map: P, rate: 'read', roles: 'staff with order:place' }),
  db('guest_staff_place', { args: gst.StaffPlace, map: P, rate: 'write', idem: true, roles: 'staff with order:place (Hand to guest)' }),
  db('online_order_act', { fn: 'gw_online_order_act', args: 'passthrough', map: P, rate: 'write', roles: 'staff with order.update_status' }),
  // ---- Outlets (0520-0522): the outlet header, Restaurant status (Delivery status, Rush mode per outlet) and adding an outlet, which stays
  //      pending until Master Admin approves it. The database checks organisation, outlet, role and verification. outlet_json is internal.
  db('outlet_list', { args: out.List, map: P, rate: 'read', roles: STAFF }),
  db('outlet_set_channel', { args: out.SetChannel, map: P, rate: 'write', roles: 'channel_integrations:update at that outlet (owner, admin, managers)' }),
  db('outlet_add', { args: out.Add, map: P, rate: 'write', idem: true, roles: 'locations:manage (owner, admin, business manager) of an approved business' }),
  // ---- Outlet drafts (0523): save and continue later; where the outlet is (same state reuses the business GSTIN, another state needs its own
  //      GSTIN and a contact who becomes the outlet admin). Submit makes the pending outlet. The "all outlets" restaurant home (0524).
  db('outlet_draft_get', { args: out.DraftGet, map: P, rate: 'read', roles: 'locations:manage of an approved business' }),
  db('outlet_draft_save', { args: out.DraftSave, map: P, rate: 'write', idem: true, roles: 'locations:manage of an approved business' }),
  db('outlet_draft_submit', { args: out.DraftRef, map: P, rate: 'write', roles: 'locations:manage of an approved business' }),
  db('outlet_draft_discard', { args: out.DraftRef, map: P, rate: 'write', roles: 'locations:manage of an approved business' }),
  db('rst_dashboard_scope', { args: rst.DashboardScope, map: P, rate: 'read', roles: 'floor staff (order place / update status, or table manager)' }),
];

const byAlias = new Map<string, Entry>(MANIFEST.map(e => [e.alias, e]));
export const lookup = (alias: string): Entry | undefined => byAlias.get(alias);
/** Entries that call a database function (what the audit checks). */
export const dbFunctions = (): string[] => [...new Set(MANIFEST.filter((e): e is DbEntry => e.kind === 'db').map(e => e.fn))];
