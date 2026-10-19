// Request shapes for the multi-outlet calls (database: migrations 0520-0522). A friendly first check; the organisation, outlet, role,
// verification and every value range are checked again in the database. Extra keys are kept (`loose`).
import { z } from 'zod';
import { UUID, hhmm } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'] as const;

export const List = z.object({ location_id: id.nullish(), q: z.string().max(80, 'The search can be up to 80 characters.').nullish() }).loose();
export const SetChannel = z.object({
  location_id: id,
  accepting: z.boolean({ message: 'Delivery status is on or off.' }).optional(),
  rush_mode: z.boolean({ message: 'Rush mode is on or off.' }).optional(),
  rush_extra_minutes: z.number().int().min(5, 'Rush mode adds 5 to 60 minutes.').max(60, 'Rush mode adds 5 to 60 minutes.').optional(),
}).loose().refine(v => v.accepting !== undefined || v.rush_mode !== undefined || v.rush_extra_minutes !== undefined, { message: 'Nothing to change.' });
export const Add = z.object({
  idempotency_key: z.string().trim().min(8, 'The idempotency key is missing.').max(120, 'The idempotency key is too long.').optional(),
  name: z.string({ message: 'Enter the outlet name.' }).trim().min(2, 'Enter the outlet name.').max(80, 'The outlet name can be up to 80 characters.'),
  address_line: z.string({ message: 'Enter the address.' }).trim().min(5, 'Enter the full address.').max(200, 'The address can be up to 200 characters.'),
  locality: z.string().trim().max(100, 'The locality is too long.').nullish(),
  city: z.string().trim().max(80, 'The city is too long.').nullish(),
  pin_code: z.string({ message: 'Enter the PIN code.' }).regex(/^[1-9][0-9]{5}$/, 'The PIN code must be 6 digits.'),
  lat: z.number({ message: 'Place the map pin on the outlet.' }).min(-90).max(90),
  lng: z.number({ message: 'Place the map pin on the outlet.' }).min(-180).max(180),
  hours: z.object({
    opens: hhmm('Opening time must be HH:MM.'),
    closes: hhmm('Closing time must be HH:MM.'),
    days: z.array(z.enum(DAYS, { message: 'Unknown day.' })).min(1, 'Choose at least one day.').max(7),
  }, { message: 'Enter the opening hours.' }),
  gstin: z.string().trim().toUpperCase().regex(/^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/, 'The GSTIN is not valid.').nullish().or(z.literal('')),
  fssai: z.string().trim().regex(/^[0-9]{14}$/, 'The FSSAI licence number must be 14 digits.').nullish().or(z.literal('')),
}).loose();
