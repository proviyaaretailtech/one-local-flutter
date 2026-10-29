// Request shapes for the store staff functions (C:\onelocal\hosted_store_staff_2026-10-28.sql): staff, attendance, salary, advances.
// A first check of the shape; the database checks the business, the role and every rule again. Extra keys are kept (`loose`).
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'The date must look like 2026-10-17.');
const key = { idempotency_key: z.string().trim().max(100).optional() };
const obj = <T extends z.ZodRawShape>(shape: T) => z.object(shape).loose();
const rupees = z.number().min(0).max(10_000_000);

export const Empty = obj({});
export const Save = obj({
  id: id.nullish(), name: z.string().trim().min(1, 'Enter the name.').max(80), mobile: z.string().max(20).optional(), role: z.string().max(60).optional(),
  salary_type: z.enum(['monthly', 'daily', 'hourly']).optional(), pay: rupees.optional(), working_hours: z.number().min(1).max(24).optional(), joining_date: day.optional(),
  status: z.enum(['active', 'inactive']).optional(),
});
export const Day = obj({ date: day.nullish() });
export const Mark = obj({ date: day, rows: z.array(obj({ staff_id: id, status: z.string().max(10).nullish(), ot_hours: z.number().min(0).max(24).nullish() })).min(1).max(500) });
export const Month = obj({ year: z.number().int().min(2000).max(2100).optional(), month: z.number().int().min(1).max(12).optional() });
export const Adjust = obj({ id, bonus: rupees.optional(), penalty: rupees.optional() });
export const Pay = obj({ id, amount: rupees.nullish(), account: z.enum(['cash', 'bank', 'upi']), ...key });
export const Advance = obj({ staff_id: id, amount: rupees, mode: z.enum(['cash', 'upi', 'bank']), deduct_month: z.number().int().min(1).max(12).optional(),
  deduct_year: z.number().int().min(2000).max(2100).optional(), reason: z.string().max(200).optional(), ...key });
