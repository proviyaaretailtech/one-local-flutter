// Request shapes for the Menu module (Menu · Recipe · Ingredients; database: migrations/0600_menu_recipes_ingredients.sql). A friendly
// first check of the shape; every rule (business, role, names, prices, quantities, units, duplicates, versions) is checked again in the
// database. Extra keys are kept (`loose`), so the database stays the one judge.
import { z } from 'zod';
import { UUID } from '../validate.ts';

const id = z.string({ message: 'Not a valid id.' }).regex(UUID, 'Not a valid id.');
const obj = <T extends z.ZodRawShape>(shape: T) => z.object(shape).loose();
const name = (max: number, msg: string) => z.string({ message: msg }).trim().min(1, msg).max(max, msg);
const money = z.union([z.number(), z.string().trim().regex(/^\d+(\.\d{1,2})?$/).transform(Number)], { message: 'Enter an amount.' });
const food = z.enum(['veg', 'non_veg', 'egg'], { message: 'Choose veg, non-veg or egg.' });
const unit = z.enum(['kg', 'g', 'l', 'ml', 'pc', 'dozen', 'pack', 'bunch'], { message: 'Choose a unit from the list.' });

// ---- ingredients
export const IngList = obj({ q: z.string().max(80).optional(), category: z.string().max(40).optional(), include_inactive: z.boolean().optional() });
export const IngLibrary = obj({ q: z.string().max(80).optional(), category: z.string().max(40).optional() });
export const IngAdd = obj({ codes: z.array(z.string().max(20)).min(1, 'Choose at least one ingredient.').max(250, 'Up to 250 ingredients at a time.') });
export const IngSave = obj({
  id: id.optional(), name: name(80, 'Enter the ingredient name.'), category: z.string().max(40).nullish(), unit,
  cost_minor: z.number().int().min(0).max(100_000_000).nullish(), reorder_level: z.number().min(0).max(1_000_000).optional(),
  is_veg: z.boolean().optional(), active: z.boolean().optional(),
  // 0632: the ingredient's barcode; '' clears it
  barcode: z.string({ message: 'The barcode is text.' }).trim().max(48, 'A barcode is up to 48 characters.').regex(/^[A-Za-z0-9._-]*$/, 'A barcode is letters and digits.').optional(),
});

// ---- recipes
export const RcpList = obj({ q: z.string().max(80).optional() });
// a dish's recipe, or an add-on's (0626: addon_id instead of menu_item_id)
export const RcpView = obj({ menu_item_id: id.optional(), addon_id: id.optional() }).refine(v => !!(v.menu_item_id || v.addon_id), { message: 'Choose a dish or an add-on.' });
export const RcpSave = obj({
  menu_item_id: id.optional(), addon_id: id.optional(),
  lines: z.array(obj({
    inventory_item_id: id, qty: z.number().positive('Every ingredient needs a quantity above zero.').max(100_000),
    wastage_pct: z.number().min(0).max(90).optional(), is_key: z.boolean().optional(), note: z.string().max(200).nullish(),
  })).max(60, 'Up to 60 ingredients in one recipe.'),
}).refine(v => !!(v.menu_item_id || v.addon_id), { message: 'Choose a dish or an add-on.' });

// ---- dishes and categories
export const CategorySave = obj({ id: id.optional(), name: name(60, 'Enter a category.'), parent_id: id.nullish(), sort_order: z.number().int().optional() });
// 0616: the category list (with parents and dish counts) and deleting an empty category.
export const CategoryList = obj({});
export const CategoryDelete = obj({ id });
export const QuickAdd = obj({
  name: name(120, 'Enter the dish name.'), category: name(60, 'Enter a category.'), price: money,
  food_type: food.optional(), course: z.enum(['eat', 'drink']).optional(),
});
export const ItemSettings = obj({ id });
export const ItemSettingsSave = obj({
  id, version: z.number().int().min(1), name: z.string().max(120).optional(), price: money.optional(),
  category_id: id.optional(), category: z.string().max(60).optional(), sku: z.string().max(40).nullish(),
  food_type: food.optional(), course: z.enum(['eat', 'drink']).optional(), station: z.string().max(30).optional(),
  prep_minutes: z.number().int().min(0).max(240).optional(), is_recommended: z.boolean().optional(), addon_group_ids: z.array(id).max(20).optional(), combo_group_ids: z.array(id).max(20).optional(),
});

// ---- add-ons and combos
export const None = obj({});
export const AddonGroupSave = obj({
  id: id.optional(), name: name(60, 'Enter the group name.'), min_select: z.number().int().min(0).max(20).optional(),
  max_select: z.number().int().min(1).max(20).optional(), active: z.boolean().optional(),
  // 0624: an add-on is an ingredient (its name unless one is typed) with the quantity one add-on uses and its selling price
  addons: z.array(obj({ id: id.optional(), name: z.string().trim().max(60, 'An add-on name is up to 60 characters.').optional(), price: money.optional(), food_type: food.optional(),
    active: z.boolean().optional(), inventory_item_id: id.nullish(), consume_qty: z.number().positive('Enter how much one add-on uses.').max(100000).nullish() }))
    .min(1, 'Add at least one add-on.').max(50, 'Up to 50 add-ons in a group.'),
  menu_item_ids: z.array(id).max(500).optional(),
});
export const ComboSave = obj({
  id: id.optional(), name: name(80, 'Enter the combo name.'), description: z.string().max(300).nullish(), price: money, active: z.boolean().optional(),
  items: z.array(obj({ menu_item_id: id, qty: z.number().int().min(1).max(20).optional() })).max(30),
});
// combo groups (0624): a group of combos offered on a dish, with how many may be chosen
export const ComboGroupSave = obj({
  id: id.optional(), name: name(60, 'Enter the group name.'), min_select: z.number().int().min(0).max(10).optional(), max_select: z.number().int().min(1).max(10).optional(),
  active: z.boolean().optional(), combo_ids: z.array(id).min(1, 'Choose at least one combo.').max(30),
});
// a dish's price on one channel (0627); null clears it (the selling price applies there)
export const ChannelPriceSave = obj({ menu_item_id: id, channel: z.enum(['onelocal', 'zomato', 'swiggy'], { message: 'Choose OneLocal, Zomato or Swiggy.' }), price: money.nullable() });
export const ById = obj({ id });

// Edit a dish's selling price (and each size's) from its recipe (0613).
const price = z.number({ message: 'Enter a selling price.' }).positive('Enter a selling price above zero.').max(1000000, 'That price is too high.');
export const PriceSave = obj({
  id,
  version: z.number().int(),
  price,
  sizes: z.array(obj({ id, price }), { message: 'sizes is a list.' }).max(10).optional(),
});
