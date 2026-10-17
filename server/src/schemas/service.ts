// Request shapes for the Service POS functions (database: migrations 0410-0413, section I). A friendly first check of the shape of the
// request; every rule (organisation, location, role, state, times, money) is checked again in the database. Extra keys are kept (`loose`)
// because the database functions read their own fields from the same object.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const ids = z.array(id).max(50);
const key = { idempotency_key: z.string().trim().max(100, 'The idempotency key is too long.').optional() };
const ver = z.number({ message: 'Refresh and try again.' }).int();
const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Not a valid date.');
const hhmm = z.string().regex(/^\d{2}:\d{2}$/, 'Not a valid time.');
const when = z.string().max(40).refine(s => !Number.isNaN(Date.parse(s)), 'Not a valid time.');
const money = z.number().min(0).max(1_000_000);
const method = z.enum(['cash', 'card', 'upi'], { message: 'Choose cash, card or UPI.' });
const text = (n: number) => z.string().max(n);
const obj = <T extends z.ZodRawShape>(shape: T) => z.object(shape).loose();
const fulfilment = z.enum(['appointment', 'event', 'on_location', 'on_demand'], { message: 'Unknown fulfilment.' });

export const Catalogue = obj({ location_id: id.nullish() });
export const Calendar = obj({ date: day.nullish(), view: z.enum(['day', 'week']).optional(), location_id: id.nullish(), staff_id: id.nullish() });
export const Quote = obj({ service_id: id, addon_ids: ids.optional(), staff_id: id.nullish() });
export const Slots = obj({ date: day, service_id: id, addon_ids: ids.optional(), staff_id: id.nullish(), location_id: id.nullish() });
export const Book = obj({
  customer_name: text(80), customer_phone: text(20).nullish(), service_id: id, addon_ids: ids.optional(), staff_id: id, resource_id: id.nullish(),
  starts_at: when, notes: text(300).nullish(), service_address: text(300).nullish(), access_note: text(200).nullish(), entitlement_id: id.nullish(),
  deposit: obj({ method, tendered: money.nullish(), reference: text(60).nullish() }).nullish(), ...key,
});
export const View = obj({ id });
export const Act = obj({
  id, action: z.enum(['pay_deposit', 'reschedule', 'check_in', 'start', 'cancel', 'no_show'], { message: 'Unknown action.' }), expected_version: ver,
  method: method.optional(), tendered: money.nullish(), reference: text(60).nullish(), starts_at: when.nullish(), staff_id: id.nullish(), resource_id: id.nullish(),
  reason: text(300).optional(), refund: z.boolean().optional(), refund_method: method.optional(), verification: z.enum(['otp', 'confirmation']).optional(),
  code: text(8).optional(), ...key,
});
export const JobUpdate = obj({
  id, expected_version: ver, done: z.array(text(120)).max(20).optional(), provider_notes: text(500).nullish(), request_confirmation: z.boolean().optional(),
  extras: z.array(obj({ menu_item_id: id, qty: z.number().int().min(1).max(99).optional(), kind: z.enum(['material', 'travel', 'labour', 'other']).optional(),
    approved_by_customer: z.boolean(), note: text(200).nullish() })).max(20).optional(), ...key,
});
export const Bill = obj({ id, expected_version: ver, method: method.optional(), tendered: money.nullish(), reference: text(60).nullish(), ...key });
export const History = obj({
  filter: z.enum(['all', 'upcoming', 'completed', 'cancelled']).optional(), q: text(100).optional(), before: when.nullish(), limit: z.number().int().min(1).max(100).optional(),
  fulfilment: fulfilment.nullish(), staff_id: id.nullish(), period: z.enum(['all', 'this_month']).optional(),
});
export const ServiceList = obj({
  q: text(100).optional(), category: text(60).nullish(), type: z.enum(['appointment', 'event', 'on_location', 'on_demand', 'package', 'membership']).nullish(),
  status: z.enum(['active', 'paused', 'draft']).nullish(),
});
export const ServiceSave = obj({
  id: id.nullish(), name: text(80), price: money, category: text(60).optional(), code: text(20).nullish(), fulfilment: fulfilment.optional(),
  kind: z.enum(['service', 'addon']).optional(), duration_min: z.number().int().min(5).max(600).optional(), buffer_min: z.number().int().min(0).max(120).optional(),
  capacity: z.number().int().min(1).max(500).optional(), staff_required: text(80).optional(), min_notice_min: z.number().int().min(0).max(10080).optional(),
  grace_min: z.number().int().min(0).max(120).optional(), description: text(500).nullish(), is_bookable: z.boolean().optional(),
  checklist: z.array(text(120)).max(20).optional(), staff_ids: ids.optional(), addon_ids: ids.optional(), expected_updated_at: when.nullish(), ...key,
});
export const StaffList = obj({ q: text(100).optional(), filter: z.enum(['all', 'available', 'on_job', 'off_duty']).optional() });
export const ProviderSave = obj({
  staff_id: id, location_id: id.nullish(), title: text(60).optional(), skills: text(120).optional(), certification: text(120).optional(),
  service_area: text(120).optional(), is_bookable: z.boolean().optional(), service_ids: ids.optional(), ...key,
});
export const Schedule = obj({ location_id: id.nullish() });
export const ScheduleSave = obj({
  location_id: id,
  hours: z.array(obj({ weekday: z.number().int().min(1).max(7), open: hhmm, close: hhmm, break_start: hhmm.nullish(), break_end: hhmm.nullish() })).max(7).optional(),
  providers: z.array(obj({ staff_id: id, hours: z.array(obj({ weekday: z.number().int().min(1).max(7), start: hhmm, end: hhmm })).max(21) })).max(50).optional(),
  slot_minutes: z.union([z.literal(5), z.literal(10), z.literal(15), z.literal(20), z.literal(30), z.literal(60)]).nullish(),
  closures_add: z.array(obj({ day, reason: text(120) })).max(30).optional(), closures_remove: ids.optional(),
  time_off_add: z.array(obj({ staff_id: id, starts_at: when, ends_at: when, reason: text(120).optional() })).max(30).optional(), time_off_remove: ids.optional(), ...key,
});
export const PlanList = obj({ kind: z.enum(['package', 'membership']).optional(), q: text(100).optional(), status: z.enum(['active', 'paused', 'draft']).nullish() });
export const PlanSave = obj({
  id: id.nullish(), kind: z.enum(['package', 'membership']), name: text(80), price: money, code: text(20).nullish(), status: z.enum(['active', 'paused', 'draft']).optional(),
  validity_days: z.number().int().min(1).max(1100).optional(), period: z.enum(['month', 'year']).nullish(), usage_note: text(120).optional(),
  exclusions: text(200).optional(), benefits: text(200).optional(), discount_pct: z.number().min(0).max(100).optional(), discount_category: text(60).nullish(),
  credit_rules: text(120).optional(), renewal_note: text(120).optional(), items: z.array(obj({ service_id: id, qty: z.number().int().min(1).max(50) })).max(30).optional(),
  expected_updated_at: when.nullish(), ...key,
});
export const Sell = obj({
  plan_id: id, customer_name: text(80), customer_phone: text(20), method, tendered: money.nullish(), reference: text(60).nullish(), location_id: id.nullish(), ...key,
});
export const EntitlementsFor = obj({ customer_phone: text(20) });
