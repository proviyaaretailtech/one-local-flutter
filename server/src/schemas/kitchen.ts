// Request shapes for the kitchen functions (database: migrations 0480 setup and 0481 display, section H). A friendly first check of the
// shape of the request; every rule (organisation, location, role, state, names, references) is checked again in the database. Extra keys
// are kept (`loose`) because the database functions read their own fields from the same object.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const key = { idempotency_key: z.string().trim().max(100, 'The idempotency key is too long.').optional() };

export const Config = z.object({}).loose();
export const StationView = z.object({ id }).loose();
// Create (no id) or change (id + version: only the fields sent change; null clears a group / printer / area).
export const StationSave = z.object({
  id: id.optional(), version: z.number().int().optional(), name: z.string({ message: 'Enter a station name.' }).trim().min(1, 'Enter a station name.').max(60, 'The station name is too long.').optional(),
  kds_group_id: id.nullish(), printer_id: id.nullish(), prep_area_id: id.nullish(), active: z.boolean().optional(), ...key,
}).loose();
export const Queue = z.object({
  station: z.string().max(60).regex(/^[a-z0-9_]+$/, 'Unknown station.').nullish(),
  status: z.enum(['all', 'new', 'in_progress', 'ready', 'served'], { message: 'Unknown status.' }).optional(),
  q: z.string().max(100).optional(), location_id: id.nullish(),
}).loose();
export const TicketAct = z.object({
  ticket_id: id, station: z.string().max(60).regex(/^[a-z0-9_]+$/, 'Unknown station.').nullish(), action: z.enum(['start', 'item_done', 'item_undo', 'ready', 'serve', 'print'], { message: 'Unknown action.' }),
  item_id: id.nullish(), expected_version: z.string().max(64).nullish(), ...key,
}).loose();
