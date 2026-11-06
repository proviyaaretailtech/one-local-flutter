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
export const Dashboard = obj({ location_id: id.nullish() });
// free slots and who is free (founder, 2 Nov 2026); the service money split
export const FreeSlots = obj({ location_id: id.nullish(), date: day.nullish() });
export const MoneySplit = obj({ location_id: id.nullish() });
// month and with_cancelled: the Bookings screen (2 Nov 2026): month grid, and cancelled bookings for its Kanban
export const Calendar = obj({
  date: day.nullish(), view: z.enum(['day', 'week', 'month']).optional(), location_id: id.nullish(), staff_id: id.nullish(), with_cancelled: z.boolean().optional(),
  source: z.enum(['pos', 'app']).nullish(), // offline (logged in the POS) or online (booked in the customer app), 2 Nov 2026
});
export const FrontDesk = obj({ date: day.nullish(), location_id: id.nullish() }); // the Bill tab's day, 5 Nov 2026
// the door's count: one walk-in on or off, 0 starts a count now; how many on a booking are in
export const SessionCount = obj({ service_id: id, starts_at: when.nullish(), delta: z.number().int().min(-1).max(1), location_id: id.nullish(), ...key });
export const Admit = obj({ id, admitted: z.number().int().min(0).max(500), expected_version: ver, ...key });
// who is coming (4 Nov 2026): checked against the listing's rules and limits, and priced by them
const party = obj({
  group: z.enum(['Single', 'Couple', 'Family', 'Group'], { message: 'Choose single, couple, family or group.' }).nullish(),
  guests: z.array(obj({ g: z.enum(['woman', 'man', 'any']), a: z.enum(['under_8', '8_11', '12_17', '18_59', '60_plus']) })).min(1, 'Add who is coming.').max(200, 'At most 200 people in one booking.'),
});
export const Quote = obj({ service_id: id, addon_ids: ids.optional(), staff_id: id.nullish(), party: party.nullish(), starts_at: when.nullish(), unit: text(80).nullish(), part: text(80).nullish() });
export const Slots = obj({ date: day, service_id: id, addon_ids: ids.optional(), staff_id: id.nullish(), location_id: id.nullish(), unit: text(80).nullish(), part: text(80).nullish(), except_id: id.nullish() });
export const Book = obj({
  customer_name: text(80), customer_phone: text(20).nullish(), service_id: id, addon_ids: ids.optional(), staff_id: id.nullish(), resource_id: id.nullish(), unit: text(80).nullish(), part: text(80).nullish(),
  starts_at: when, notes: text(300).nullish(), service_address: text(300).nullish(), access_note: text(200).nullish(), entitlement_id: id.nullish(),
  deposit: obj({ method, tendered: money.nullish(), reference: text(60).nullish() }).nullish(), party: party.nullish(), ...key,
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
// Inventory (founder's catalogue design, 3 Nov 2026): places, tools, materials and customers' items in care
const qty = z.number().min(0).max(100000);
export const Inventory = obj({});
export const InventorySave = obj({
  id: id.nullish(), kind: z.enum(['place', 'tool', 'material'], { message: 'Choose a place, a tool or a material.' }).optional(), name: text(60).optional(),
  note: text(200).nullish(), qty: qty.optional(), unit: text(20).nullish(), reorder_at: qty.nullish(), per_booking: qty.nullish(), blocked: z.boolean().optional(),
  blocked_note: text(120).nullish(), blocked_until: day.nullish(), service_ids: ids.optional(), archived: z.boolean().optional(), ...key,
});
export const InventoryMove = obj({ id, action: z.enum(['out', 'back', 'add', 'use'], { message: 'Unknown action.' }), qty: qty.positive(), note: text(120).nullish(), ...key });
export const CareSave = obj({
  id: id.nullish(), item: text(80).optional(), customer_name: text(80).optional(), customer_phone: text(20).nullish(), note: text(200).nullish(), promised_on: day.nullish(),
  status: z.enum(['with_you', 'in_work', 'ready', 'returned'], { message: 'Unknown status.' }).optional(), ...key,
});
// Listing forms (founder's design canvas, 3 Nov 2026): one form per category; the answers are kept with the service
// no Dining in the Service POS (founder, 4 Nov 2026)
const listingCategory = z.enum(['events', 'activities', 'play', 'service', 'stay'], { message: 'Choose Events, Activities, Play, Service or Stay.' });
export const ListingView = obj({ service_id: id.nullish() });
export const ListingSave = obj({
  service_id: id, category: listingCategory,
  listing: z.record(z.string(), z.unknown()).refine(v => JSON.stringify(v).length <= 30000, 'The listing is too long.'), ...key,
});
// Templates (founder, 3 Nov 2026: "like a restaurant's recipe master"): what a service needs and its rules, saved under a name
const templateFields = {
  name: text(60), category: listingCategory.nullish(), subcategory: text(60).nullish(), duration_min: z.number().int().min(5).max(600).nullish(),
  requirements: z.array(z.record(z.string(), z.unknown())).max(50).optional(), rules: z.array(z.record(z.string(), z.unknown())).max(50).optional(),
  notes: text(500).nullish(),
};
export const TemplateList = obj({ q: text(100).optional() });
export const TemplateSave = obj({ id: id.nullish(), ...templateFields, name: text(60).optional(), archived: z.boolean().optional(), ...key });
export const TemplateImport = obj({ templates: z.array(obj(templateFields)).min(1, 'The file has no templates.').max(200, 'Import up to 200 templates at a time.'), ...key });
// Reports (founder, 4 Nov 2026): the restaurant's Reports, for a service business
export const Report = obj({
  kind: z.enum(['sales', 'services', 'categories', 'bookings', 'staff', 'payments', 'dues', 'discounts', 'cancellations'], { message: 'Unknown report.' }),
  from: day.nullish(), to: day.nullish(),
});
export const Schedule = obj({ location_id: id.nullish() });
// Service management's slot table (2 Nov 2026): one weekday, 1 = Monday
export const SlotTable = obj({ location_id: id.nullish(), weekday: z.number().int().min(1).max(7).nullish() });
export const ScheduleSave = obj({
  location_id: id,
  hours: z.array(obj({ weekday: z.number().int().min(1).max(7), open: hhmm, close: hhmm, break_start: hhmm.nullish(), break_end: hhmm.nullish() })).max(7).optional(),
  providers: z.array(obj({ staff_id: id, hours: z.array(obj({ weekday: z.number().int().min(1).max(7), start: hhmm, end: hhmm })).max(21) })).max(50).optional(),
  // 90 to 240: slots of 1½ to 4 hours (Service management, 2 Nov 2026)
  slot_minutes: z.literal([5, 10, 15, 20, 30, 60, 90, 120, 180, 240]).nullish(),
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

// The Bill tab (2 Nov 2026): the business's bills, one bill, a new bill (services from the catalogue), taking payment on it.
export const BillList = obj({ filter: z.enum(['all', 'due', 'paid', 'today']).optional(), q: text(60).nullish() });
export const BillView = obj({ order_id: id });
export const InvoiceCreate = obj({
  customer_name: text(80), customer_phone: text(20).nullish(), address: text(300).nullish(), title: text(80).nullish(), message: text(500).nullish(),
  lines: z.array(obj({ menu_item_id: id, qty: z.number().int().min(1).max(99) })).min(1, 'Add at least one service.').max(50),
  discount: money.nullish(), discount_pct: z.number().min(0).max(100).nullish(), ...key,
});
export const InvoicePay = obj({ order_id: id, method, tendered: money.nullish(), reference: text(60).nullish(), ...key });

// Jobs (New job, 2 Nov 2026): several services, a team, a time or "schedule later", an arrival window, repeating visits.
export const JobSave = obj({
  customer_name: text(80), customer_phone: text(20).nullish(), address: text(300).nullish(), title: text(80).nullish(), instructions: text(1000).nullish(),
  lines: z.array(obj({ menu_item_id: id, qty: z.number().int().min(1).max(99) })).min(1, 'Add at least one service.').max(50),
  discount: money.nullish(), discount_pct: z.number().min(0).max(100).nullish(), team: ids.optional(),
  schedule_later: z.boolean().optional(), date: day.nullish(), start: hhmm.nullish(), end: hhmm.nullish(),
  arrival_window_min: z.number().int().min(0).max(480).optional(), repeat: z.enum(['none', 'weekly', 'fortnightly', 'monthly']).optional(),
  repeat_count: z.number().int().min(1).max(12).optional(), remind_invoice: z.boolean().optional(), ...key,
});
export const JobView = obj({ id });
export const JobAct = obj({ id, action: z.enum(['start', 'complete', 'close', 'cancel']), visit_id: id.nullish(), ...key });
