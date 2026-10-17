// Request shapes for the back office functions (database: migration 0420, section J: Low Stock and Purchase Suggestions). A friendly first
// check of the shape; every rule (organisation, store, role, business-wide scope, state, quantities) is checked again in the database.
// Extra keys are kept (`loose`) because the database functions read their own fields from the same object.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const obj = <T extends z.ZodRawShape>(shape: T) => z.object({ location_id: id.nullish(), ...shape }).loose();

export const LowStock = obj({
  filter: z.enum(['all', 'critical', 'low'], { message: 'Unknown filter.' }).optional(),
  q: z.string().max(80, 'Search is too long.').optional(),
});
export const SuggestionsRefresh = obj({});
export const SuggestionsList = obj({});
// ordered: the person's own purchase order reference (free text; there is no purchase-order table yet). quantities: {suggestion id: qty}.
export const SuggestionsClose = z.object({
  ids: z.array(id).min(1, 'Choose at least one suggestion.').max(200, 'At most 200 suggestions at once.'),
  outcome: z.enum(['ordered', 'dismissed'], { message: 'Outcome must be ordered or dismissed.' }),
  purchase_order_ref: z.string().trim().min(1).max(80, 'Purchase order reference is too long.').nullish(),
  quantities: z.record(z.string().regex(UUID, 'Not a valid id.'), z.number().positive('Enter a quantity above zero.').max(100_000)).optional(),
}).loose();
