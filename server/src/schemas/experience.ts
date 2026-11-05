// Request shapes for the guest experience builder (database 0654; spec specs/guest-experience-builder). A friendly first check only:
// the database cleans the whole page again (gx__clean) and decides what is allowed, so the page itself passes through as an object.
import { z } from 'zod';

const ver = z.number({ message: 'Reload the builder and try again.' }).int().min(0);
const page = z.object({}, { message: 'The page is missing.' }).loose();

export const None = z.object({}).loose();
export const Save = z.object({ expected_draft_version: ver, definition: page }).loose();
export const Publish = z.object({ expected_draft_version: ver.optional() }).loose();
export const Rollback = z.object({ version: z.number({ message: 'Choose a version.' }).int().min(1) }).loose();

// Create with AI and Import menu (spec part 2, contract D). Strict: nothing but the owner's words reaches the AI; the business, the menu
// and the page come from the database as the caller.
export const AiCreate = z.object({
  style: z.string({ message: 'The style is text.' }).max(200, 'Describe the style in up to 200 characters.').optional(),
}).strict();
export const MenuImport = z.object({
  text: z.string({ message: 'Paste your menu.' }).trim().min(20, 'Paste at least a few dishes (20 characters or more).').max(20_000, 'Paste up to 20,000 characters at a time.'),
}).strict();

// What the AI may answer for an imported dish. Each dish is checked on its own: a bad one is left out, the rest stay. The database checks
// the dish again when the owner adds it (menu_item_quick_add: role, name, category, price).
const noMarkup = (s: string) => !/[<>]/.test(s);
const words = (max: number) => z.string().transform(s => s.replace(/\s+/g, ' ').trim()).pipe(z.string().min(1).max(max).refine(noMarkup));
const rupees = z.union([
  z.number(),
  // "₹ 120", "Rs.120/-", "120.50": the first amount in the text
  z.string().transform((s, ctx) => {
    const m = s.replace(/,/g, '').match(/\d+(\.\d{1,2})?/);
    if (!m) { ctx.addIssue({ code: 'custom', message: 'no price' }); return z.NEVER; }
    return Number(m[0]);
  }),
]).pipe(z.number().positive().max(100_000)).transform(n => Math.round(n * 100) / 100);
export const ImportedDish = z.object({
  name: words(60).pipe(z.string().min(2)),
  category: words(40).catch('Other'),
  price: rupees,
  veg: z.union([z.boolean(), z.null()]).catch(null),
  description: words(140).nullable().catch(null),
});
export type ImportedDish = z.infer<typeof ImportedDish>;
