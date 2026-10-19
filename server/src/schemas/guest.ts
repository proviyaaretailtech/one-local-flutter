// Request shapes for table QR codes and guest orders (database: migrations 0560, 0561; spec specs/table-qr-guest-menu). A friendly first
// check of the shape; every rule (business, outlet, role, published menu, limits, session) is checked again in the database. Staff shapes
// keep extra keys (`loose`); the guest door's shapes are strict, because nobody signed in sends them.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const obj = <T extends z.ZodRawShape>(shape: T) => z.object({ location_id: id.nullish(), ...shape }).loose();
const key = z.string({ message: 'The request key is missing.' }).trim().min(8, 'The request key is missing.').max(100, 'The request key is too long.')
  .regex(/^[A-Za-z0-9_:.-]+$/, 'The request key is not valid.');
const line = z.object({
  menu_item_id: id,
  qty: z.number({ message: 'Choose 1 to 20 of a dish.' }).int('Choose 1 to 20 of a dish.').min(1, 'Choose 1 to 20 of a dish.').max(20, 'Choose 1 to 20 of a dish.'),
  notes: z.string().max(140, 'A dish note can be up to 140 characters.').nullish(),
}).strict();
const lines = z.array(line, { message: 'Add a dish first.' }).min(1, 'Add a dish first.').max(30, 'An order can have up to 30 different dishes.');
const name = z.string().max(40, 'A name can be up to 40 characters.').nullish();
const note = z.string().max(300, 'A note can be up to 300 characters.').nullish();

// ---- staff (POST /rpc/<name>, as the caller)
export const QrList = obj({});
export const QrIssue = obj({ table_id: id, replace: z.boolean().optional(), confirm_label: z.string().max(60).optional() });
export const QrEnabled = obj({ table_id: id, enabled: z.boolean({ message: 'Say whether the code is on or off.' }) });
export const Requests = obj({ table_id: id.nullish(), status: z.enum(['waiting', 'all'], { message: 'Unknown filter.' }).optional() });
export const Decide = obj({
  id, action: z.enum(['accept', 'decline'], { message: 'Accept or decline.' }),
  reason: z.string().max(200, 'The reason can be up to 200 characters.').nullish(),
});
export const StaffMenu = obj({ table_id: id });
export const StaffPlace = obj({ table_id: id, lines, idempotency_key: key.optional(), guest_name: name, note });

// ---- the guest door (POST /guest/<name>, no sign-in)
const session = z.string({ message: 'Please scan the table code again.' }).regex(/^[0-9a-f]{64}$/, 'Please scan the table code again.');
export const Open = z.object({ code: z.string({ message: 'This table code is not in use.' }).regex(/^[0-9a-f]{32,128}$/, 'This table code is not in use.') }).strict();
export const Session = z.object({ session }).strict();
export const Send = z.object({ session, idempotency_key: key, lines, guest_name: name, note }).strict();
