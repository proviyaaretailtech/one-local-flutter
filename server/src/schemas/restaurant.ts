// Request shape for the restaurant dashboard (database: migration 0491). A friendly first check; the organisation, outlet and role
// are checked again in the database.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
export const Dashboard = z.object({ location_id: id.nullish() }).loose();

// Restaurant menu and dish detail (database: migrations 0540-0541). Every rule (menu.update, windows, 500-character description, stale
// version, tenancy, rate limit) is checked again in the database.
const hhmm = z.string().regex(/^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$/, 'Use a time like 09:30.');
const Window = z.object({
  slot: z.enum(['morning', 'evening', 'night', 'custom'], { message: 'Availability is morning, evening, night or custom.' }),
  starts_at: hhmm.nullish(), ends_at: hhmm.nullish(), days: z.array(z.number().int().min(1).max(7)).max(7).nullish(),
}).strict();
export const Menu = z.object({
  location_id: id.nullish(), q: z.string().max(60).nullish(), filter: z.enum(['all', 'in_stock', 'out_of_stock', 'needs_image']).optional(),
}).strict();
export const MenuItemView = z.object({ id, location_id: id.nullish() }).strict();
export const MenuItemSave = z.object({
  id, version: z.number().int().min(1), location_id: id.nullish(), description: z.string().max(500, 'A description is up to 500 characters.').nullish(),
  food_type: z.enum(['veg', 'non_veg', 'egg']).optional(), availability: z.array(Window).max(6, 'Up to 6 serving windows per dish.').optional(),
}).strict();
export const MenuStockSet = z.object({ id: id.optional(), category_id: id.optional(), in_stock: z.boolean() }).strict()
  .refine(b => !!b.id !== !!b.category_id, { message: 'Choose one dish or one category.' });
// Write with AI: the owner's notes are capped here and again in the handler; the dish facts come from the database.
export const AiDescribe = z.object({ item_id: id, notes: z.string().max(1000, 'Notes are up to 1000 characters.').optional() }).strict();
