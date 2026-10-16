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
import { secureHandlers, withImageLinks, type SecureHandler } from './modules/secure/index.ts';
import * as ob from './schemas/onboarding.ts';
import * as su from './schemas/setup.ts';
import * as inv from './schemas/inventory.ts';

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
  db('pos_home_online', { args: 'passthrough', map: P, rate: 'read', roles: STAFF }),
  db('pos_home_channel', { args: 'passthrough', map: () => ({}), rate: 'read', roles: STAFF }),
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
  db('online_order_act', { fn: 'gw_online_order_act', args: 'passthrough', map: P, rate: 'write', roles: 'staff with order.update_status' }),
];

const byAlias = new Map<string, Entry>(MANIFEST.map(e => [e.alias, e]));
export const lookup = (alias: string): Entry | undefined => byAlias.get(alias);
/** Entries that call a database function (what the audit checks). */
export const dbFunctions = (): string[] => [...new Set(MANIFEST.filter((e): e is DbEntry => e.kind === 'db').map(e => e.fn))];
