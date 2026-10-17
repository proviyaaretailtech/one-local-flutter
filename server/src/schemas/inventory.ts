// Request shapes for the store inventory functions (database: migrations 0400-0403, section H). A friendly first check of the shape of
// the request; every rule (organisation, location, role, state, quantities) is checked again in the database. Extra keys are kept
// (`loose`) because the database functions read their own fields from the same object.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const loc = { location_id: id.nullish() };
const key = { idempotency_key: z.string().trim().max(100, 'The idempotency key is too long.').optional() };
const obj = <T extends z.ZodRawShape>(shape: T) => z.object({ ...loc, ...shape }).loose();

export const Options = obj({});
export const Dashboard = obj({});
export const StockList = obj({
  filter: z.enum(['all', 'healthy', 'low', 'critical', 'near_expiry', 'sku', 'ingredient'], { message: 'Unknown filter.' }).optional(),
  q: z.string().max(100).optional(), category: z.string().max(100).optional(),
  page: z.number().int().min(1).max(10_000).optional(), page_size: z.number().int().min(1).max(50).optional(),
});
export const StockDetail = obj({ item_id: id });
export const MovementList = obj({ item_id: id.nullish(), before_id: z.number().int().nullish(), limit: z.number().int().min(1).max(100).optional() });
export const MovementDetail = obj({ id: z.number().int({ message: 'Not a valid movement.' }) });
export const DocumentList = obj({
  doc_type: z.enum(['receipt', 'adjustment', 'transfer', 'audit'], { message: 'Unknown document type.' }).optional(),
  statuses: z.union([z.array(z.string().max(30)).max(10), z.string().max(200)]).optional(),
  scope: z.string().max(30).optional(), q: z.string().max(100).optional(), limit: z.number().int().min(1).max(100).optional(),
});
export const DocumentView = obj({ id });
export const Forecast = obj({ item_id: id, days: z.number().int().optional(), demand_per_day: z.number().min(0).max(1_000_000).nullish() });
// Create (no id) or save (id + version). Lines are replaced as a whole when sent; the database checks each one.
export const DocumentSave = obj({
  id: id.optional(), version: z.number().int().optional(), doc_type: z.enum(['receipt', 'adjustment', 'transfer', 'audit'], { message: 'Unknown document type.' }).optional(),
  lines: z.array(z.record(z.string(), z.unknown())).max(200, 'A document can have at most 200 lines.').optional(), ...key,
});
export const DocumentAct = obj({ id, action: z.string({ message: 'Choose an action.' }).min(1).max(30), version: z.number().int({ message: 'version is required' }), note: z.string().max(500).nullish(), ...key });
export const AuditToAdjustment = obj({ id, ...key });
