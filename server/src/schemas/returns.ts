// Returns, refunds & replacements: the store's policy per category (founder's spec, 29 Oct 2026, Phase 1 "Policy foundation";
// C:onelocalhosted_returns_policy_2026-10-29.sql). A friendly first check of the shape; the database checks every rule again
// (the template's window and remedies, consent, roles) and answers with the sentence.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const obj = <T extends z.ZodRawShape>(shape: T) => z.object(shape).loose();
const category = z.union([z.string().regex(UUID, 'Not a valid category.'), z.null()]);

export const None = obj({});
export const PolicySave = obj({
  category_ids: z.array(category, { message: 'Choose at least one category.' }).min(1, 'Choose at least one category.').max(100, 'Choose up to 100 categories at a time.'),
  template_id: z.enum(['fresh', 'packaged', 'personal_care', 'electronics', 'fashion', 'home', 'custom'], { message: 'Choose a policy.' }),
  change_of_mind: z.boolean().optional(),
  window_hours: z.number({ message: 'Choose how long customers have.' }).int().min(1).max(720).optional(),
  remedies: z.array(z.enum(['refund', 'replacement', 'exchange', 'repair'], { message: 'Choose how you make it right.' })).min(1, 'Choose at least one way to make it right.').max(4).optional(),
  sealed_only: z.boolean().optional(),
  inspection: z.boolean().optional(),
  preview: z.boolean().optional(),
  agree: z.boolean().optional(),
});
export const History = obj({ category_id: category.optional() });
export const SettingsSave = obj({
  dispatch_photo: z.boolean().optional(),
  bulk_items: z.number({ message: 'Enter how many items make a bulk order.' }).int().min(2, 'A bulk order is at least 2 items.').max(200, 'A bulk order is at most 200 items.').optional(),
});
