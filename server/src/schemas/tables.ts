// Request shapes for the tables-and-floor functions (database: migration 0404, section H). A friendly first check of the shape of the
// request; every rule (organisation, store, role, capacity, overlap, state) is checked again in the database. Extra keys are kept (`loose`).
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const obj = <T extends z.ZodRawShape>(shape: T) => z.object({ location_id: id.nullish(), ...shape }).loose();
// An instant must carry its own zone (Z or +05:30); otherwise send the store's wall clock as local_date + local_time (the database reads it in the store's zone).
const when = z.string({ message: 'Choose a date and time.' }).max(40, 'Choose a date and time.').regex(/(Z|[+-]\d{2}(:?\d{2})?)$/, 'The time needs its time zone.').refine(v => !Number.isNaN(Date.parse(v)), 'Choose a date and time.');

export const Floor = obj({
  status: z.enum(['all', 'available', 'occupied', 'reserved', 'cleaning'], { message: 'Unknown filter.' }).optional(),
  area_id: id.nullish(),
});
export const TableRef = obj({ table_id: id });
export const History = obj({ table_id: id, limit: z.number().int().min(1).max(50).optional() });
export const Reserve = obj({
  table_id: id,
  guest_name: z.string({ message: 'Enter the guest name.' }).trim().min(1, 'Enter the guest name.').max(80, 'The guest name is too long.'),
  phone: z.string({ message: 'Enter a phone number.' }).trim().regex(/^[+0-9 ()-]{6,20}$/, 'Enter a phone number.'),
  guests: z.number({ message: 'Choose a party size.' }).int('Choose a party size.').min(1, 'Choose a party size.').max(50, 'Choose a party size.'),
  scheduled_at: when.optional(),
  local_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a date.').optional(),
  local_time: z.string().regex(/^\d{2}:\d{2}$/, 'Choose a time.').optional(),
  notes: z.string().max(300, 'Special notes can be up to 300 characters.').nullish(),
  idempotency_key: z.string().trim().max(100, 'The idempotency key is too long.').optional(),
}).refine(v => !!(v.scheduled_at || v.local_date), { message: 'Choose a date and time.' });
export const ReserveCancel = obj({ id, outcome: z.enum(['cancelled', 'no_show'], { message: 'Unknown outcome.' }).optional() });
export const Transfer = obj({ from_table_id: id, to_table_id: id });
export const Merge = obj({ table_ids: z.array(id, { message: 'Choose the tables to join.' }).min(2, 'Choose at least two tables.').max(8, 'You can join up to eight tables.') });
export const Split = obj({ merge_id: id.optional(), table_id: id.optional() }).refine(v => !!(v.merge_id || v.table_id), { message: 'Choose the joined tables to split.' });

// Take an order at a table (database: migration 0485). Dishes, quantities and notes; the database checks the dishes, the table's open order and the bill.
const line = z.object({
  menu_item_id: id,
  qty: z.number({ message: 'Choose a quantity.' }).int('Choose a quantity.').min(1, 'Quantities are 1 to 99.').max(99, 'Quantities are 1 to 99.'),
  notes: z.string().max(200, 'A note can be up to 200 characters.').nullish(),
  takeaway: z.boolean({ message: 'takeaway is true or false.' }).optional(), // a takeaway dish on a dine-in bill (0606)
  variant_id: id.optional(), // a size of the dish (0611): Small / Medium / Large
  addons: z.array(id, { message: 'Add-ons are a list.' }).max(40, 'Too many add-ons on one dish.').optional(), // add-ons chosen in the billing pop-up (0624); an id twice = two
  combos: z.array(id, { message: 'Combos are a list.' }).max(10).optional(), // combos chosen on the dish (0624)
}).loose();
export const OrderAdd = obj({
  table_id: id,
  lines: z.array(line, { message: 'Choose the dishes.' }).min(1, 'Choose at least one dish.').max(50, 'Up to 50 dishes at a time.'),
  send: z.boolean({ message: 'send is true or false.' }).optional(),
  guest_count: z.number().int().min(1).max(50).optional(),
});
// The Bill's Takeaway / Delivery pills (0604): an order without a table. Delivery needs a phone and an address (checked again in the database).
export const CounterOrder = obj({
  service_type: z.enum(['pickup', 'delivery'], { message: 'Choose Takeaway or Delivery.' }),
  lines: z.array(line, { message: 'Choose the dishes.' }).min(1, 'Choose at least one dish.').max(50, 'Up to 50 dishes at a time.'),
  send: z.boolean({ message: 'send is true or false.' }).optional(),
  customer_name: z.string().trim().max(80, 'The name is too long.').nullish(),
  customer_phone: z.string().trim().regex(/^[+0-9 ()-]{0,20}$/, 'Enter a phone number.').nullish(),
  address: z.string().trim().max(300, 'The address can be up to 300 characters.').nullish(),
  notes: z.string().max(300).nullish(),
});
export const KotSend = obj({ order_id: id.optional(), table_id: id.optional() }).refine(v => !!(v.order_id || v.table_id), { message: 'Choose the order or the table.' });
export const ReadyList = obj({});
export const MarkServed = obj({ item_ids: z.array(id, { message: 'Choose the dishes.' }).min(1, 'Choose at least one dish.').max(100, 'Up to 100 dishes at a time.') });

// Manage tables (0602): create, rename, change seats, remove. Names unique per outlet, seats 1 to 50, and who may are checked again in the database.
export const TableList = obj({});
export const TableSave = obj({
  id: id.optional(),
  label: z.string({ message: 'Give the table a name.' }).trim().min(1, 'Give the table a name.').max(20, 'A table name is up to 20 characters.'),
  seats: z.number({ message: 'Enter the seats.' }).int().min(1, 'Seats are 1 to 50.').max(50, 'Seats are 1 to 50.'),
});
export const TableRemove = obj({ id });
