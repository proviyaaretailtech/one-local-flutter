// Request shapes for the tables-and-floor functions (database: migration 0404, section H). A friendly first check of the shape of the
// request; every rule (organisation, store, role, capacity, overlap, state) is checked again in the database. Extra keys are kept (`loose`).
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const obj = <T extends z.ZodRawShape>(shape: T) => z.object({ location_id: id.nullish(), ...shape }).loose();
const when = z.string({ message: 'Choose a date and time.' }).min(10, 'Choose a date and time.').max(40, 'Choose a date and time.').refine(v => !Number.isNaN(Date.parse(v)), 'Choose a date and time.');

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
  scheduled_at: when,
  notes: z.string().max(300, 'Special notes can be up to 300 characters.').nullish(),
  idempotency_key: z.string().trim().max(100, 'The idempotency key is too long.').optional(),
});
export const ReserveCancel = obj({ id });
export const Transfer = obj({ from_table_id: id, to_table_id: id });
export const Merge = obj({ table_ids: z.array(id, { message: 'Choose the tables to join.' }).min(2, 'Choose at least two tables.').max(8, 'You can join up to eight tables.') });
export const Split = obj({ merge_id: id.optional(), table_id: id.optional() }).refine(v => !!(v.merge_id || v.table_id), { message: 'Choose the joined tables to split.' });
