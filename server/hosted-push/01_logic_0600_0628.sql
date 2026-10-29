-- ============================================================================================================================
-- HOSTED PUSH 1 of 2: LOGIC. Migrations 0600-0628 (29 files) in order, as ONE transaction: all of it applies, or none of it.
-- Built from server/migrations by hosted-push/build.sh. Run it in the Supabase SQL editor of project ywylhzcxuoeilygzdonx
-- BEFORE 02_niks_cafe_data.sql and before the server is deployed. Checked on a copy of the hosted DB (dump of 26 Oct 2026):
-- applies without errors and leaves the same tables, functions, triggers, indexes and policies as the local test DB.
-- Run it once. If it stops with an error, nothing has changed; send the error back.
-- ============================================================================================================================
begin;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0600_menu_recipes_ingredients.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0600 Menu module redesign: Menu · Recipe · Ingredients (founder sketch, 26 Oct 2026).
-- Lives in this repo until it is moved into the shared database/migrations repo. Safe to run again.
--
-- Builds on what the database already runs:
--   * ingredients are inventory_items with item_type = 'ingredient' (purchasing, receiving and stock already use them);
--   * a dish's recipe is menu_item_recipes (selling already deducts stock through order_stock_consume);
--   * supplier prices are pos_supplier_prices.material_id = inventory_items.id.
-- Adds: a shared ingredient library (~200, editable once added), an ingredient's own cost, key ingredients on a recipe, recipe
-- cost / food cost / margin, quick add and detailed settings for dishes, categories, add-on groups and combos.
-- Every function finds the business from the signed-in person (current_org_id) and checks the role (has_permission); errors are
-- POS_<REASON>: sentence, which the gateway turns into HTTP statuses. The legacy pos_recipes / pos_raw_materials tables are untouched.


-- ---------------------------------------------------------------- tables

create table if not exists public.ingredient_library (
  code text primary key,
  name text not null check (length(btrim(name)) > 0),
  category text not null,
  unit text not null check (unit in ('kg', 'g', 'l', 'ml', 'pc', 'dozen', 'pack', 'bunch')),
  typical_cost_minor bigint not null default 0 check (typical_cost_minor >= 0),   -- per unit, a starting point the business edits
  is_veg boolean not null default true
);
comment on table public.ingredient_library is 'Shared starting list of ingredients (typical Indian wholesale prices, Oct 2026). A business adds what it uses and edits its own copy.';

create table if not exists public.ingredient_profiles (
  inventory_item_id uuid primary key,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  cost_minor bigint check (cost_minor is null or cost_minor >= 0),   -- the business's own cost per unit (used when there is no purchase yet)
  library_code text references public.ingredient_library(code) on delete set null,
  is_veg boolean not null default true,
  updated_at timestamptz not null default now(),
  foreign key (inventory_item_id, organization_id) references public.inventory_items(id, organization_id) on delete cascade
);
create index if not exists ingredient_profiles_org_idx on public.ingredient_profiles (organization_id);

alter table public.menu_item_recipes add column if not exists is_key boolean not null default false;
alter table public.menu_item_recipes add column if not exists note text check (note is null or char_length(note) <= 200);

create table if not exists public.menu_addon_groups (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  min_select int not null default 0,
  max_select int not null default 1,
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (min_select >= 0 and max_select >= 1 and min_select <= max_select and max_select <= 20),
  unique (id, organization_id)
);
create unique index if not exists menu_addon_groups_name_uq on public.menu_addon_groups (organization_id, lower(btrim(name)));

create table if not exists public.menu_addons (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  group_id uuid not null,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  price numeric(10, 2) not null default 0 check (price >= 0 and price <= 100000),
  food_type text not null default 'veg' check (food_type in ('veg', 'non_veg', 'egg')),
  active boolean not null default true,
  sort_order int not null default 0,
  foreign key (group_id, organization_id) references public.menu_addon_groups(id, organization_id) on delete cascade
);
create index if not exists menu_addons_group_idx on public.menu_addons (group_id);

create table if not exists public.menu_item_addon_groups (
  menu_item_id uuid not null,
  group_id uuid not null,
  organization_id uuid not null,
  primary key (menu_item_id, group_id),
  foreign key (menu_item_id, organization_id) references public.menu_items(id, organization_id) on delete cascade,
  foreign key (group_id, organization_id) references public.menu_addon_groups(id, organization_id) on delete cascade
);

create table if not exists public.menu_combos (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 2 and 80),
  description text check (description is null or char_length(description) <= 300),
  price numeric(10, 2) not null check (price > 0 and price <= 1000000),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organization_id)
);
create unique index if not exists menu_combos_name_uq on public.menu_combos (organization_id, lower(btrim(name)));

create table if not exists public.menu_combo_items (
  combo_id uuid not null,
  menu_item_id uuid not null,
  organization_id uuid not null,
  qty int not null default 1 check (qty between 1 and 20),
  primary key (combo_id, menu_item_id),
  foreign key (combo_id, organization_id) references public.menu_combos(id, organization_id) on delete cascade,
  foreign key (menu_item_id, organization_id) references public.menu_items(id, organization_id) on delete cascade
);

-- Only the functions below touch these tables (security definer); the library is readable by any signed-in person.
alter table public.ingredient_library enable row level security;
alter table public.ingredient_profiles enable row level security;
alter table public.menu_addon_groups enable row level security;
alter table public.menu_addons enable row level security;
alter table public.menu_item_addon_groups enable row level security;
alter table public.menu_combos enable row level security;
alter table public.menu_combo_items enable row level security;
drop policy if exists ingredient_library_read on public.ingredient_library;
create policy ingredient_library_read on public.ingredient_library for select to authenticated using (true);

-- ---------------------------------------------------------------- the library (~200; typical prices per unit, editable once added)

insert into public.ingredient_library (code, name, category, unit, typical_cost_minor, is_veg)
select code, name, category, unit, round(rupees * 100)::bigint, veg from (values
  -- Dairy
  ('DAI-01', 'Full cream milk', 'Dairy', 'l', 68, true), ('DAI-02', 'Toned milk', 'Dairy', 'l', 56, true), ('DAI-03', 'Fresh cream', 'Dairy', 'l', 240, true),
  ('DAI-04', 'Whipping cream', 'Dairy', 'l', 320, true), ('DAI-05', 'Butter (salted)', 'Dairy', 'kg', 520, true), ('DAI-06', 'Butter (unsalted)', 'Dairy', 'kg', 560, true),
  ('DAI-07', 'Ghee', 'Dairy', 'kg', 620, true), ('DAI-08', 'Curd', 'Dairy', 'kg', 80, true), ('DAI-09', 'Greek yogurt', 'Dairy', 'kg', 260, true),
  ('DAI-10', 'Paneer', 'Dairy', 'kg', 380, true), ('DAI-11', 'Khoya', 'Dairy', 'kg', 420, true), ('DAI-12', 'Condensed milk', 'Dairy', 'kg', 310, true),
  ('DAI-13', 'Milk powder', 'Dairy', 'kg', 420, true), ('DAI-14', 'Vanilla ice cream', 'Dairy', 'l', 220, true), ('DAI-15', 'Chocolate ice cream', 'Dairy', 'l', 250, true),
  -- Cheese
  ('CHE-01', 'Mozzarella cheese', 'Cheese', 'kg', 480, true), ('CHE-02', 'Processed cheese', 'Cheese', 'kg', 460, true), ('CHE-03', 'Cheddar cheese', 'Cheese', 'kg', 720, true),
  ('CHE-04', 'Cheese slices', 'Cheese', 'pc', 9, true), ('CHE-05', 'Parmesan cheese', 'Cheese', 'kg', 1800, true), ('CHE-06', 'Cream cheese', 'Cheese', 'kg', 650, true),
  ('CHE-07', 'Cheese sauce', 'Cheese', 'kg', 420, true), ('CHE-08', 'Pizza cheese blend', 'Cheese', 'kg', 440, true),
  -- Coffee & tea
  ('COF-01', 'Espresso coffee beans', 'Coffee & Tea', 'kg', 1400, true), ('COF-02', 'Filter coffee powder', 'Coffee & Tea', 'kg', 700, true),
  ('COF-03', 'Instant coffee', 'Coffee & Tea', 'kg', 1600, true), ('COF-04', 'Cold brew concentrate', 'Coffee & Tea', 'l', 900, true),
  ('COF-05', 'CTC tea leaves', 'Coffee & Tea', 'kg', 420, true), ('COF-06', 'Green tea', 'Coffee & Tea', 'kg', 1200, true),
  ('COF-07', 'Masala chai premix', 'Coffee & Tea', 'kg', 480, true), ('COF-08', 'Cocoa powder', 'Coffee & Tea', 'kg', 900, true),
  ('COF-09', 'Drinking chocolate powder', 'Coffee & Tea', 'kg', 650, true), ('COF-10', 'Matcha powder', 'Coffee & Tea', 'kg', 4500, true),
  -- Syrups & beverages
  ('SYR-01', 'Vanilla syrup', 'Syrups & Beverages', 'l', 650, true), ('SYR-02', 'Hazelnut syrup', 'Syrups & Beverages', 'l', 650, true),
  ('SYR-03', 'Caramel syrup', 'Syrups & Beverages', 'l', 650, true), ('SYR-04', 'Chocolate syrup', 'Syrups & Beverages', 'l', 420, true),
  ('SYR-05', 'Mint syrup', 'Syrups & Beverages', 'l', 600, true), ('SYR-06', 'Blue curacao syrup', 'Syrups & Beverages', 'l', 600, true),
  ('SYR-07', 'Strawberry crush', 'Syrups & Beverages', 'l', 320, true), ('SYR-08', 'Mango pulp', 'Syrups & Beverages', 'kg', 160, true),
  ('SYR-09', 'Lemon juice', 'Syrups & Beverages', 'l', 180, true), ('SYR-10', 'Soda water', 'Syrups & Beverages', 'l', 30, true),
  ('SYR-11', 'Tonic water', 'Syrups & Beverages', 'l', 120, true), ('SYR-12', 'Packaged drinking water', 'Syrups & Beverages', 'l', 15, true),
  ('SYR-13', 'Rose syrup', 'Syrups & Beverages', 'l', 220, true), ('SYR-14', 'Kokum syrup', 'Syrups & Beverages', 'l', 240, true),
  -- Sweeteners
  ('SWE-01', 'Sugar', 'Sweeteners', 'kg', 46, true), ('SWE-02', 'Brown sugar', 'Sweeteners', 'kg', 120, true), ('SWE-03', 'Icing sugar', 'Sweeteners', 'kg', 110, true),
  ('SWE-04', 'Honey', 'Sweeteners', 'kg', 420, true), ('SWE-05', 'Jaggery', 'Sweeteners', 'kg', 70, true), ('SWE-06', 'Maple syrup', 'Sweeteners', 'l', 1600, true),
  ('SWE-07', 'Sugar-free sweetener', 'Sweeteners', 'pack', 180, true),
  -- Bakery
  ('BAK-01', 'Sandwich bread', 'Bakery', 'pc', 2.5, true), ('BAK-02', 'Brown bread', 'Bakery', 'pc', 3, true), ('BAK-03', 'Sub roll (6 inch)', 'Bakery', 'pc', 18, true),
  ('BAK-04', 'Burger bun', 'Bakery', 'pc', 9, true), ('BAK-05', 'Pav', 'Bakery', 'pc', 3, true), ('BAK-06', 'Pizza base (8 inch)', 'Bakery', 'pc', 22, true),
  ('BAK-07', 'Croissant', 'Bakery', 'pc', 35, true), ('BAK-08', 'Garlic bread loaf', 'Bakery', 'pc', 40, true), ('BAK-09', 'Tortilla wrap', 'Bakery', 'pc', 14, true),
  ('BAK-10', 'Brownie slab', 'Bakery', 'kg', 520, true), ('BAK-11', 'Pancake mix', 'Bakery', 'kg', 280, true), ('BAK-12', 'Waffle mix', 'Bakery', 'kg', 300, true),
  ('BAK-13', 'Baking powder', 'Bakery', 'kg', 240, true), ('BAK-14', 'Baking soda', 'Bakery', 'kg', 90, true), ('BAK-15', 'Dry yeast', 'Bakery', 'kg', 600, true),
  ('BAK-16', 'Bread crumbs', 'Bakery', 'kg', 120, true), ('BAK-17', 'Cookies', 'Bakery', 'kg', 300, true), ('BAK-18', 'Dark chocolate compound', 'Bakery', 'kg', 420, true),
  ('BAK-19', 'Milk chocolate compound', 'Bakery', 'kg', 420, true), ('BAK-20', 'Choco chips', 'Bakery', 'kg', 480, true),
  -- Grains, flour & pasta
  ('GRA-01', 'Basmati rice', 'Grains & Pasta', 'kg', 110, true), ('GRA-02', 'Sona masoori rice', 'Grains & Pasta', 'kg', 58, true), ('GRA-03', 'Wheat flour (atta)', 'Grains & Pasta', 'kg', 42, true),
  ('GRA-04', 'Refined flour (maida)', 'Grains & Pasta', 'kg', 40, true), ('GRA-05', 'Gram flour (besan)', 'Grains & Pasta', 'kg', 90, true), ('GRA-06', 'Semolina (rava)', 'Grains & Pasta', 'kg', 48, true),
  ('GRA-07', 'Corn flour', 'Grains & Pasta', 'kg', 80, true), ('GRA-08', 'Rice flour', 'Grains & Pasta', 'kg', 50, true), ('GRA-09', 'Poha', 'Grains & Pasta', 'kg', 60, true),
  ('GRA-10', 'Penne pasta', 'Grains & Pasta', 'kg', 180, true), ('GRA-11', 'Spaghetti', 'Grains & Pasta', 'kg', 180, true), ('GRA-12', 'Macaroni', 'Grains & Pasta', 'kg', 130, true),
  ('GRA-13', 'Hakka noodles', 'Grains & Pasta', 'kg', 140, true), ('GRA-14', 'Oats', 'Grains & Pasta', 'kg', 160, true), ('GRA-15', 'Vermicelli', 'Grains & Pasta', 'kg', 90, true),
  ('GRA-16', 'Sabudana', 'Grains & Pasta', 'kg', 90, true),
  -- Pulses
  ('PUL-01', 'Toor dal', 'Pulses', 'kg', 150, true), ('PUL-02', 'Moong dal', 'Pulses', 'kg', 120, true), ('PUL-03', 'Masoor dal', 'Pulses', 'kg', 100, true),
  ('PUL-04', 'Chana dal', 'Pulses', 'kg', 90, true), ('PUL-05', 'Urad dal', 'Pulses', 'kg', 130, true), ('PUL-06', 'Kabuli chana', 'Pulses', 'kg', 130, true),
  ('PUL-07', 'Rajma', 'Pulses', 'kg', 150, true), ('PUL-08', 'Green moong', 'Pulses', 'kg', 120, true),
  -- Vegetables
  ('VEG-01', 'Potato', 'Vegetables', 'kg', 30, true), ('VEG-02', 'Onion', 'Vegetables', 'kg', 35, true), ('VEG-03', 'Tomato', 'Vegetables', 'kg', 30, true),
  ('VEG-04', 'Capsicum (green)', 'Vegetables', 'kg', 60, true), ('VEG-05', 'Bell pepper (red/yellow)', 'Vegetables', 'kg', 220, true), ('VEG-06', 'Cucumber', 'Vegetables', 'kg', 35, true),
  ('VEG-07', 'Lettuce (iceberg)', 'Vegetables', 'kg', 160, true), ('VEG-08', 'Cabbage', 'Vegetables', 'kg', 25, true), ('VEG-09', 'Carrot', 'Vegetables', 'kg', 45, true),
  ('VEG-10', 'Sweet corn', 'Vegetables', 'kg', 120, true), ('VEG-11', 'Green peas', 'Vegetables', 'kg', 100, true), ('VEG-12', 'Mushroom', 'Vegetables', 'kg', 240, true),
  ('VEG-13', 'Spinach', 'Vegetables', 'bunch', 20, true), ('VEG-14', 'Coriander leaves', 'Vegetables', 'bunch', 10, true), ('VEG-15', 'Mint leaves', 'Vegetables', 'bunch', 10, true),
  ('VEG-16', 'Green chilli', 'Vegetables', 'kg', 80, true), ('VEG-17', 'Ginger', 'Vegetables', 'kg', 140, true), ('VEG-18', 'Garlic', 'Vegetables', 'kg', 220, true),
  ('VEG-19', 'Lemon', 'Vegetables', 'pc', 4, true), ('VEG-20', 'Spring onion', 'Vegetables', 'bunch', 15, true), ('VEG-21', 'Jalapeno (pickled)', 'Vegetables', 'kg', 320, true),
  ('VEG-22', 'Olives (black)', 'Vegetables', 'kg', 420, true), ('VEG-23', 'Broccoli', 'Vegetables', 'kg', 180, true), ('VEG-24', 'Zucchini', 'Vegetables', 'kg', 160, true),
  ('VEG-25', 'Beetroot', 'Vegetables', 'kg', 40, true), ('VEG-26', 'Cauliflower', 'Vegetables', 'kg', 40, true), ('VEG-27', 'French beans', 'Vegetables', 'kg', 70, true),
  ('VEG-28', 'Curry leaves', 'Vegetables', 'bunch', 5, true), ('VEG-29', 'Basil leaves', 'Vegetables', 'bunch', 30, true), ('VEG-30', 'Frozen french fries', 'Vegetables', 'kg', 170, true),
  -- Fruits
  ('FRU-01', 'Banana', 'Fruits', 'dozen', 60, true), ('FRU-02', 'Apple', 'Fruits', 'kg', 160, true), ('FRU-03', 'Mango', 'Fruits', 'kg', 120, true),
  ('FRU-04', 'Strawberry', 'Fruits', 'kg', 400, true), ('FRU-05', 'Pineapple', 'Fruits', 'pc', 60, true), ('FRU-06', 'Watermelon', 'Fruits', 'kg', 25, true),
  ('FRU-07', 'Orange', 'Fruits', 'kg', 90, true), ('FRU-08', 'Pomegranate', 'Fruits', 'kg', 180, true), ('FRU-09', 'Blueberries', 'Fruits', 'kg', 1600, true),
  ('FRU-10', 'Avocado', 'Fruits', 'pc', 120, true),
  -- Eggs, meat & seafood
  ('EGG-01', 'Eggs', 'Eggs', 'pc', 7, false), ('MEA-01', 'Chicken breast (boneless)', 'Meat & Poultry', 'kg', 340, false),
  ('MEA-02', 'Chicken (curry cut)', 'Meat & Poultry', 'kg', 230, false), ('MEA-03', 'Chicken tikka (marinated)', 'Meat & Poultry', 'kg', 420, false),
  ('MEA-04', 'Chicken sausage', 'Meat & Poultry', 'kg', 480, false), ('MEA-05', 'Chicken salami', 'Meat & Poultry', 'kg', 520, false),
  ('MEA-06', 'Mutton (curry cut)', 'Meat & Poultry', 'kg', 780, false), ('MEA-07', 'Chicken keema', 'Meat & Poultry', 'kg', 320, false),
  ('MEA-08', 'Pork bacon', 'Meat & Poultry', 'kg', 900, false), ('SEA-01', 'Fish fillet (basa)', 'Seafood', 'kg', 320, false),
  ('SEA-02', 'Prawns', 'Seafood', 'kg', 620, false), ('SEA-03', 'Surmai', 'Seafood', 'kg', 750, false), ('SEA-04', 'Tuna (canned)', 'Seafood', 'kg', 900, false),
  -- Oils & fats
  ('OIL-01', 'Sunflower oil', 'Oils & Fats', 'l', 140, true), ('OIL-02', 'Groundnut oil', 'Oils & Fats', 'l', 190, true), ('OIL-03', 'Mustard oil', 'Oils & Fats', 'l', 170, true),
  ('OIL-04', 'Olive oil', 'Oils & Fats', 'l', 850, true), ('OIL-05', 'Rice bran oil', 'Oils & Fats', 'l', 150, true), ('OIL-06', 'Vanaspati', 'Oils & Fats', 'kg', 140, true),
  -- Sauces & condiments
  ('SAU-01', 'Tomato ketchup', 'Sauces & Condiments', 'kg', 110, true), ('SAU-02', 'Mayonnaise (veg)', 'Sauces & Condiments', 'kg', 180, true),
  ('SAU-03', 'Tandoori mayonnaise', 'Sauces & Condiments', 'kg', 220, true), ('SAU-04', 'Mustard sauce', 'Sauces & Condiments', 'kg', 260, true),
  ('SAU-05', 'Peri peri sauce', 'Sauces & Condiments', 'kg', 320, true), ('SAU-06', 'Barbecue sauce', 'Sauces & Condiments', 'kg', 300, true),
  ('SAU-07', 'Chipotle sauce', 'Sauces & Condiments', 'kg', 340, true), ('SAU-08', 'Pizza / pasta red sauce', 'Sauces & Condiments', 'kg', 220, true),
  ('SAU-09', 'White sauce base', 'Sauces & Condiments', 'kg', 260, true), ('SAU-10', 'Pesto', 'Sauces & Condiments', 'kg', 900, true),
  ('SAU-11', 'Soy sauce', 'Sauces & Condiments', 'l', 140, true), ('SAU-12', 'Red chilli sauce', 'Sauces & Condiments', 'l', 120, true),
  ('SAU-13', 'Green chilli sauce', 'Sauces & Condiments', 'l', 120, true), ('SAU-14', 'Vinegar', 'Sauces & Condiments', 'l', 60, true),
  ('SAU-15', 'Schezwan sauce', 'Sauces & Condiments', 'kg', 260, true), ('SAU-16', 'Mint chutney', 'Sauces & Condiments', 'kg', 180, true),
  ('SAU-17', 'Tamarind chutney', 'Sauces & Condiments', 'kg', 160, true), ('SAU-18', 'Thousand island dressing', 'Sauces & Condiments', 'kg', 300, true),
  ('SAU-19', 'Honey mustard dressing', 'Sauces & Condiments', 'kg', 340, true), ('SAU-20', 'Nutella / hazelnut spread', 'Sauces & Condiments', 'kg', 950, true),
  ('SAU-21', 'Peanut butter', 'Sauces & Condiments', 'kg', 380, true), ('SAU-22', 'Mixed fruit jam', 'Sauces & Condiments', 'kg', 220, true),
  -- Spices & seasoning
  ('SPI-01', 'Salt', 'Spices & Seasoning', 'kg', 22, true), ('SPI-02', 'Black pepper powder', 'Spices & Seasoning', 'kg', 900, true),
  ('SPI-03', 'Red chilli powder', 'Spices & Seasoning', 'kg', 320, true), ('SPI-04', 'Turmeric powder', 'Spices & Seasoning', 'kg', 260, true),
  ('SPI-05', 'Coriander powder', 'Spices & Seasoning', 'kg', 220, true), ('SPI-06', 'Cumin seeds', 'Spices & Seasoning', 'kg', 480, true),
  ('SPI-07', 'Garam masala', 'Spices & Seasoning', 'kg', 600, true), ('SPI-08', 'Chaat masala', 'Spices & Seasoning', 'kg', 420, true),
  ('SPI-09', 'Peri peri seasoning', 'Spices & Seasoning', 'kg', 650, true), ('SPI-10', 'Oregano', 'Spices & Seasoning', 'kg', 900, true),
  ('SPI-11', 'Chilli flakes', 'Spices & Seasoning', 'kg', 480, true), ('SPI-12', 'Mixed herbs', 'Spices & Seasoning', 'kg', 950, true),
  ('SPI-13', 'Kashmiri chilli powder', 'Spices & Seasoning', 'kg', 520, true), ('SPI-14', 'Mustard seeds', 'Spices & Seasoning', 'kg', 140, true),
  ('SPI-15', 'Kasuri methi', 'Spices & Seasoning', 'kg', 600, true), ('SPI-16', 'Pav bhaji masala', 'Spices & Seasoning', 'kg', 520, true),
  ('SPI-17', 'Cinnamon powder', 'Spices & Seasoning', 'kg', 800, true), ('SPI-18', 'Cardamom', 'Spices & Seasoning', 'kg', 2800, true),
  ('SPI-19', 'Garlic powder', 'Spices & Seasoning', 'kg', 520, true), ('SPI-20', 'Hing (asafoetida)', 'Spices & Seasoning', 'kg', 2400, true),
  -- Nuts & dry fruits
  ('NUT-01', 'Cashew', 'Nuts & Dry Fruits', 'kg', 900, true), ('NUT-02', 'Almonds', 'Nuts & Dry Fruits', 'kg', 850, true), ('NUT-03', 'Raisins', 'Nuts & Dry Fruits', 'kg', 320, true),
  ('NUT-04', 'Walnuts', 'Nuts & Dry Fruits', 'kg', 1100, true), ('NUT-05', 'Pistachio', 'Nuts & Dry Fruits', 'kg', 1800, true), ('NUT-06', 'Peanuts', 'Nuts & Dry Fruits', 'kg', 140, true),
  ('NUT-07', 'Dates', 'Nuts & Dry Fruits', 'kg', 300, true),
  -- Frozen & ready
  ('FRO-01', 'Frozen veg patty', 'Frozen & Ready', 'pc', 14, true), ('FRO-02', 'Frozen chicken patty', 'Frozen & Ready', 'pc', 22, false),
  ('FRO-03', 'Chicken nuggets', 'Frozen & Ready', 'kg', 420, false), ('FRO-04', 'Smileys / potato bites', 'Frozen & Ready', 'kg', 260, true),
  ('FRO-05', 'Frozen momos (veg)', 'Frozen & Ready', 'pc', 6, true), ('FRO-06', 'Frozen momos (chicken)', 'Frozen & Ready', 'pc', 8, false),
  ('FRO-07', 'Cheese corn nuggets', 'Frozen & Ready', 'kg', 380, true), ('FRO-08', 'Hash browns', 'Frozen & Ready', 'pc', 12, true),
  -- Packaging
  ('PAC-01', 'Paper cup (250 ml)', 'Packaging', 'pc', 2.5, true), ('PAC-02', 'Cold cup with lid (400 ml)', 'Packaging', 'pc', 6, true),
  ('PAC-03', 'Straw (paper)', 'Packaging', 'pc', 1, true), ('PAC-04', 'Takeaway box (small)', 'Packaging', 'pc', 5, true),
  ('PAC-05', 'Takeaway box (large)', 'Packaging', 'pc', 9, true), ('PAC-06', 'Butter paper', 'Packaging', 'pc', 0.5, true),
  ('PAC-07', 'Paper bag', 'Packaging', 'pc', 4, true), ('PAC-08', 'Tissue napkins', 'Packaging', 'pack', 30, true),
  ('PAC-09', 'Wooden cutlery set', 'Packaging', 'pc', 3, true), ('PAC-10', 'Sauce dip cup', 'Packaging', 'pc', 1.5, true),
  ('PAC-11', 'Aluminium foil roll', 'Packaging', 'pc', 180, true), ('PAC-12', 'Cling film roll', 'Packaging', 'pc', 220, true)
) as v(code, name, category, unit, rupees, veg)
on conflict (code) do update set name = excluded.name, category = excluded.category, unit = excluded.unit,
  typical_cost_minor = excluded.typical_cost_minor, is_veg = excluded.is_veg;

-- ---------------------------------------------------------------- helpers

create or replace function public.mb_org(p_resource text, p_action text) returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id();
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if not public.has_permission(v_org, p_resource, p_action) then
    raise exception 'POS_FORBIDDEN: your role cannot %', case p_resource when 'menu' then 'change the menu' else 'manage ingredients' end; end if;
  return v_org;
end $$;

create or replace function public.mb_clean(p text) returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g')), '')
$$;

-- An ingredient's cost per unit and where it came from: the last receipt, else the preferred / approved supplier price, else the
-- business's own figure (from the library or typed in). Null when there is none yet.
create or replace function public.mb_ing_cost(p_org uuid, p_item uuid, out cost_minor bigint, out source text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  select m.unit_cost_minor into cost_minor from public.stock_movements m
   where m.organization_id = p_org and m.inventory_item_id = p_item and m.unit_cost_minor > 0 and m.quantity > 0
   order by m.created_at desc, m.id desc limit 1;
  if cost_minor is not null then source := 'last_purchase'; return; end if;
  select round(sp.current_price * 100)::bigint into cost_minor from public.pos_supplier_prices sp
   where sp.organization_id = p_org and sp.material_id = p_item::text and sp.deleted_at is null and sp.current_price > 0
   order by sp.preferred desc nulls last, sp.approved desc nulls last, sp.current_price asc limit 1;
  if cost_minor is not null then source := 'supplier_price'; return; end if;
  select ip.cost_minor into cost_minor from public.ingredient_profiles ip where ip.inventory_item_id = p_item and ip.organization_id = p_org;
  if cost_minor is not null then source := 'set_by_you'; return; end if;
  source := 'none';
end $$;

create or replace function public.mb_on_hand(p_org uuid, p_item uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(public.inv_movement_delta(m.id)), 0) from public.stock_movements m where m.organization_id = p_org and m.inventory_item_id = p_item
$$;

-- One recipe's figures: lines with their cost, and the totals against the dish price (cost, food cost %, margin).
create or replace function public.mb_recipe_json(p_org uuid, p_item uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare m public.menu_items%rowtype; v_lines jsonb := '[]'; v_cost bigint := 0; v_missing int := 0; r record; c record; v_line bigint;
begin
  select * into m from public.menu_items where id = p_item and organization_id = p_org;
  if not found then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  for r in select mr.*, i.name, i.unit, i.category from public.menu_item_recipes mr join public.inventory_items i on i.id = mr.inventory_item_id
            where mr.menu_item_id = p_item and mr.organization_id = p_org order by mr.is_key desc, i.name loop
    select * into c from public.mb_ing_cost(p_org, r.inventory_item_id);
    v_line := case when c.cost_minor is null then null else round(c.cost_minor * r.qty_per_unit * (1 + r.wastage_pct / 100))::bigint end;
    if v_line is null then v_missing := v_missing + 1; else v_cost := v_cost + v_line; end if;
    v_lines := v_lines || jsonb_build_object('inventory_item_id', r.inventory_item_id, 'name', r.name, 'unit', r.unit, 'category', r.category,
      'qty', r.qty_per_unit, 'wastage_pct', r.wastage_pct, 'is_key', r.is_key, 'note', r.note,
      'unit_cost_minor', c.cost_minor, 'cost_source', c.source, 'line_cost_minor', v_line);
  end loop;
  return jsonb_build_object(
    'menu_item_id', m.id, 'name', m.name, 'food_type', m.food_type, 'image_url', m.image_url,
    'category', (select name from public.menu_categories where id = m.category_id),
    'price_minor', round(m.price * 100)::bigint, 'lines', v_lines, 'line_count', jsonb_array_length(v_lines),
    'key_count', (select count(*) from jsonb_array_elements(v_lines) x where (x->>'is_key')::boolean),
    'missing_cost', v_missing, 'cost_minor', v_cost,
    'food_cost_pct', case when m.price > 0 and jsonb_array_length(v_lines) > 0 then round(v_cost / (m.price * 100) * 100, 1) end,
    'margin_minor', case when jsonb_array_length(v_lines) > 0 then round(m.price * 100)::bigint - v_cost end,
    'margin_pct', case when m.price > 0 and jsonb_array_length(v_lines) > 0 then round((m.price * 100 - v_cost) / (m.price * 100) * 100, 1) end);
end $$;

-- ---------------------------------------------------------------- ingredients

create or replace function public.ing_list(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('inventory', 'read'); v_q text := lower(coalesce(public.mb_clean(p->>'q'), '')); v_cat text := public.mb_clean(p->>'category');
  v_items jsonb := '[]'; r record; c record; v_on numeric; v_total int := 0; v_nocost int := 0; v_low int := 0;
begin
  for r in select i.*, ip.is_veg, ip.library_code,
                  (select count(*) from public.menu_item_recipes mr where mr.inventory_item_id = i.id) as used_in
             from public.inventory_items i left join public.ingredient_profiles ip on ip.inventory_item_id = i.id
            where i.organization_id = v_org and i.item_type = 'ingredient' and (i.active or coalesce((p->>'include_inactive')::boolean, false))
            order by i.category nulls last, i.name loop
    select * into c from public.mb_ing_cost(v_org, r.id);
    v_on := public.mb_on_hand(v_org, r.id);
    v_total := v_total + 1;
    if c.cost_minor is null then v_nocost := v_nocost + 1; end if;
    if r.reorder_level > 0 and v_on <= r.reorder_level then v_low := v_low + 1; end if;
    if (v_q = '' or lower(r.name) like '%' || v_q || '%' or lower(coalesce(r.sku, '')) like '%' || v_q || '%')
       and (v_cat is null or r.category = v_cat) then
      v_items := v_items || jsonb_build_object('id', r.id, 'name', r.name, 'sku', r.sku, 'category', r.category, 'unit', r.unit,
        'reorder_level', r.reorder_level, 'active', r.active, 'is_veg', coalesce(r.is_veg, true), 'library_code', r.library_code,
        'cost_minor', c.cost_minor, 'cost_source', c.source, 'on_hand', v_on, 'low', r.reorder_level > 0 and v_on <= r.reorder_level,
        'used_in', r.used_in,
        'supplier', (select jsonb_build_object('id', s.id, 'name', s.name, 'price_minor', round(sp.current_price * 100)::bigint)
                       from public.pos_supplier_prices sp join public.pos_suppliers s on s.id = sp.supplier_id and s.organization_id = sp.organization_id
                      where sp.organization_id = v_org and sp.material_id = r.id::text and sp.deleted_at is null
                      order by sp.preferred desc nulls last, sp.current_price asc limit 1));
    end if;
  end loop;
  return jsonb_build_object('counts', jsonb_build_object('total', v_total, 'no_cost', v_nocost, 'low', v_low),
    'categories', coalesce((select jsonb_agg(distinct i.category order by i.category) from public.inventory_items i
                             where i.organization_id = v_org and i.item_type = 'ingredient' and i.active and i.category is not null), '[]'),
    'units', '["kg","g","l","ml","pc","dozen","pack","bunch"]'::jsonb,
    'can_edit', public.has_permission(v_org, 'inventory', 'record'),
    'items', v_items);
end $$;

create or replace function public.ing_library(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('inventory', 'read'); v_q text := lower(coalesce(public.mb_clean(p->>'q'), '')); v_cat text := public.mb_clean(p->>'category');
begin
  return jsonb_build_object(
    'categories', (select jsonb_agg(distinct category order by category) from public.ingredient_library),
    'items', coalesce((select jsonb_agg(jsonb_build_object('code', l.code, 'name', l.name, 'category', l.category, 'unit', l.unit,
                 'typical_cost_minor', l.typical_cost_minor, 'is_veg', l.is_veg,
                 'added', exists (select 1 from public.inventory_items i where i.organization_id = v_org and i.item_type = 'ingredient'
                                   and lower(i.name) = lower(l.name)))
               order by l.category, l.name)
        from public.ingredient_library l
       where (v_q = '' or lower(l.name) like '%' || v_q || '%') and (v_cat is null or l.category = v_cat)), '[]'));
end $$;

-- Adds library ingredients to the business (its own editable copies, cost = the typical price until a purchase says otherwise).
create or replace function public.ing_add_from_library(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('inventory', 'record'); l public.ingredient_library%rowtype; v_id uuid; v_added int := 0; v_codes text[];
begin
  if jsonb_typeof(p->'codes') <> 'array' or jsonb_array_length(p->'codes') = 0 then raise exception 'POS_BAD_REQUEST: choose at least one ingredient'; end if;
  if jsonb_array_length(p->'codes') > 250 then raise exception 'POS_BAD_REQUEST: up to 250 ingredients at a time'; end if;
  select array_agg(x) into v_codes from jsonb_array_elements_text(p->'codes') x;
  for l in select * from public.ingredient_library where code = any (v_codes) order by category, name loop
    if exists (select 1 from public.inventory_items i where i.organization_id = v_org and i.item_type = 'ingredient' and lower(i.name) = lower(l.name)) then continue; end if;
    insert into public.inventory_items (organization_id, sku, name, unit, reorder_level, active, item_type, category)
    values (v_org, 'ING-' || l.code, l.name, l.unit, 0, true, 'ingredient', l.category)
    on conflict (organization_id, sku) do update set active = true, item_type = 'ingredient'
    returning id into v_id;
    insert into public.ingredient_profiles (inventory_item_id, organization_id, cost_minor, library_code, is_veg)
    values (v_id, v_org, l.typical_cost_minor, l.code, l.is_veg)
    on conflict (inventory_item_id) do nothing;
    v_added := v_added + 1;
  end loop;
  return public.ing_list('{}') || jsonb_build_object('added', v_added);
end $$;

-- Creates or changes one ingredient. Its cost here is "set by you": a purchase recorded later takes over automatically.
create or replace function public.ing_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('inventory', 'record'); v_id uuid := nullif(p->>'id', '')::uuid; i public.inventory_items%rowtype;
  v_name text := public.mb_clean(p->>'name'); v_cat text := public.mb_clean(p->>'category'); v_unit text := coalesce(public.mb_clean(p->>'unit'), 'kg');
  v_reorder numeric := coalesce(nullif(p->>'reorder_level', '')::numeric, 0); v_cost bigint;
begin
  if v_name is null or char_length(v_name) > 80 then raise exception 'POS_BAD_REQUEST: enter the ingredient name (up to 80 characters)'; end if;
  if v_cat is not null and char_length(v_cat) > 40 then raise exception 'POS_BAD_REQUEST: a category is up to 40 characters'; end if;
  if v_unit not in ('kg', 'g', 'l', 'ml', 'pc', 'dozen', 'pack', 'bunch') then raise exception 'POS_BAD_REQUEST: choose a unit from the list'; end if;
  if v_reorder < 0 or v_reorder > 1000000 then raise exception 'POS_BAD_REQUEST: the reorder level cannot be negative'; end if;
  if p ? 'cost_minor' and nullif(p->>'cost_minor', '') is not null then
    v_cost := (p->>'cost_minor')::bigint;
    if v_cost < 0 or v_cost > 100000000 then raise exception 'POS_BAD_REQUEST: enter a cost per unit of zero or more'; end if;
  end if;
  if exists (select 1 from public.inventory_items x where x.organization_id = v_org and x.item_type = 'ingredient' and lower(x.name) = lower(v_name)
               and x.id is distinct from v_id) then raise exception 'POS_CONFLICT: % is already in your ingredients', v_name; end if;
  if v_id is null then
    insert into public.inventory_items (organization_id, sku, name, unit, reorder_level, active, item_type, category)
    values (v_org, 'ING-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)), v_name, v_unit, v_reorder, true, 'ingredient', v_cat)
    returning * into i;
  else
    update public.inventory_items set name = v_name, category = v_cat, unit = v_unit, reorder_level = v_reorder,
           active = coalesce((p->>'active')::boolean, active), updated_at = now()
     where id = v_id and organization_id = v_org and item_type = 'ingredient' returning * into i;
    if not found then raise exception 'POS_NOT_FOUND: ingredient not found'; end if;
  end if;
  insert into public.ingredient_profiles (inventory_item_id, organization_id, cost_minor, is_veg)
  values (i.id, v_org, v_cost, coalesce((p->>'is_veg')::boolean, true))
  on conflict (inventory_item_id) do update set
    cost_minor = case when p ? 'cost_minor' then v_cost else ingredient_profiles.cost_minor end,
    is_veg = coalesce((p->>'is_veg')::boolean, ingredient_profiles.is_veg), updated_at = now();
  return jsonb_build_object('id', i.id) || public.ing_list('{}');
end $$;

-- ---------------------------------------------------------------- recipes

create or replace function public.rcp_list(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); v_q text := lower(coalesce(public.mb_clean(p->>'q'), ''));
  v_items jsonb := '[]'; r record; j jsonb; v_with int := 0; v_sum numeric := 0; v_n int := 0;
begin
  for r in select m.id from public.menu_items m left join public.menu_categories c on c.id = m.category_id
            where m.organization_id = v_org and (v_q = '' or lower(m.name) like '%' || v_q || '%')
            order by c.sort_order nulls last, c.name, m.sort_order, m.name loop
    j := public.mb_recipe_json(v_org, r.id) - 'lines';
    if (j->>'line_count')::int > 0 then
      v_with := v_with + 1;
      if j->>'food_cost_pct' is not null then v_sum := v_sum + (j->>'food_cost_pct')::numeric; v_n := v_n + 1; end if;
    end if;
    v_items := v_items || j;
  end loop;
  return jsonb_build_object('items', v_items,
    'summary', jsonb_build_object('dishes', jsonb_array_length(v_items), 'with_recipe', v_with, 'without_recipe', jsonb_array_length(v_items) - v_with,
                                  'avg_food_cost_pct', case when v_n > 0 then round(v_sum / v_n, 1) end));
end $$;

create or replace function public.rcp_view(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update');
begin
  return public.mb_recipe_json(v_org, nullif(p->>'menu_item_id', '')::uuid);
end $$;

-- Replaces a dish's recipe: every line names one of the business's ingredients, a quantity per serving in the ingredient's unit,
-- a wastage % and whether it is a key ingredient. Selling then deducts exactly these quantities from stock.
create or replace function public.rcp_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); v_item uuid := nullif(p->>'menu_item_id', '')::uuid; l jsonb; v_ing uuid; v_qty numeric; v_w numeric;
begin
  if not exists (select 1 from public.menu_items where id = v_item and organization_id = v_org) then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  if jsonb_typeof(p->'lines') <> 'array' then raise exception 'POS_BAD_REQUEST: lines is a list'; end if;
  if jsonb_array_length(p->'lines') > 60 then raise exception 'POS_BAD_REQUEST: up to 60 ingredients in one recipe'; end if;
  delete from public.menu_item_recipes where menu_item_id = v_item and organization_id = v_org;
  for l in select * from jsonb_array_elements(p->'lines') loop
    v_ing := nullif(l->>'inventory_item_id', '')::uuid;
    if not exists (select 1 from public.inventory_items where id = v_ing and organization_id = v_org) then raise exception 'POS_NOT_FOUND: an ingredient in this recipe was not found'; end if;
    v_qty := nullif(l->>'qty', '')::numeric;
    if v_qty is null or v_qty <= 0 or v_qty > 100000 then raise exception 'POS_BAD_REQUEST: every ingredient needs a quantity above zero'; end if;
    v_w := coalesce(nullif(l->>'wastage_pct', '')::numeric, 0);
    if v_w < 0 or v_w > 90 then raise exception 'POS_BAD_REQUEST: wastage is 0 to 90 percent'; end if;
    insert into public.menu_item_recipes (organization_id, menu_item_id, inventory_item_id, qty_per_unit, wastage_pct, is_key, note)
    values (v_org, v_item, v_ing, v_qty, v_w, coalesce((l->>'is_key')::boolean, false), left(public.mb_clean(l->>'note'), 200))
    on conflict (menu_item_id, inventory_item_id) do update set qty_per_unit = excluded.qty_per_unit + menu_item_recipes.qty_per_unit,
      wastage_pct = excluded.wastage_pct, is_key = excluded.is_key or menu_item_recipes.is_key;
  end loop;
  return public.mb_recipe_json(v_org, v_item);
end $$;

-- ---------------------------------------------------------------- dishes, categories

create or replace function public.mb_category(p_org uuid, p_name text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_name text := public.mb_clean(p_name);
begin
  if v_name is null or char_length(v_name) > 60 then raise exception 'POS_BAD_REQUEST: enter a category (up to 60 characters)'; end if;
  select id into v_id from public.menu_categories where organization_id = p_org and lower(name) = lower(v_name) order by created_at limit 1;
  if v_id is null then
    insert into public.menu_categories (organization_id, name, sort_order)
    values (p_org, v_name, coalesce((select max(sort_order) + 1 from public.menu_categories where organization_id = p_org), 0)) returning id into v_id;
  end if;
  return v_id;
end $$;

create or replace function public.menu_category_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); v_id uuid := nullif(p->>'id', '')::uuid; v_name text := public.mb_clean(p->>'name');
begin
  if v_id is null then v_id := public.mb_category(v_org, v_name);
  else
    if v_name is null or char_length(v_name) > 60 then raise exception 'POS_BAD_REQUEST: enter a category (up to 60 characters)'; end if;
    if exists (select 1 from public.menu_categories where organization_id = v_org and lower(name) = lower(v_name) and id <> v_id) then
      raise exception 'POS_CONFLICT: there is already a category called %', v_name; end if;
    update public.menu_categories set name = v_name, sort_order = coalesce(nullif(p->>'sort_order', '')::int, sort_order)
     where id = v_id and organization_id = v_org;
    if not found then raise exception 'POS_NOT_FOUND: category not found'; end if;
  end if;
  return jsonb_build_object('id', v_id, 'categories', (select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort_order, name)
                                                       from public.menu_categories where organization_id = v_org));
end $$;

-- Quick add: a dish from just its name, category, price and veg / non-veg / egg. The detailed settings come later.
create or replace function public.menu_item_quick_add(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'create'); v_name text := public.mb_clean(p->>'name'); v_cat uuid; v_price numeric;
  v_food text := coalesce(nullif(p->>'food_type', ''), 'veg'); v_course text := coalesce(nullif(p->>'course', ''), 'eat'); v_id uuid;
begin
  if v_name is null or char_length(v_name) not between 2 and 120 then raise exception 'POS_BAD_REQUEST: enter the dish name'; end if;
  begin v_price := round((p->>'price')::numeric, 2); exception when others then v_price := null; end;
  if v_price is null or v_price <= 0 or v_price > 1000000 then raise exception 'POS_BAD_REQUEST: enter a selling price above zero'; end if;
  if v_food not in ('veg', 'non_veg', 'egg') then raise exception 'POS_BAD_REQUEST: choose veg, non-veg or egg'; end if;
  if v_course not in ('eat', 'drink') then raise exception 'POS_BAD_REQUEST: course is eat or drink'; end if;
  v_cat := public.mb_category(v_org, p->>'category');
  if exists (select 1 from public.menu_items where organization_id = v_org and category_id = v_cat and lower(name) = lower(v_name)) then
    raise exception 'POS_CONFLICT: % is already in this category', v_name; end if;
  insert into public.menu_items (organization_id, category_id, name, price, food_type, course,
                                 sort_order)
  values (v_org, v_cat, v_name, v_price, v_food, v_course,
          coalesce((select max(sort_order) + 1 from public.menu_items where organization_id = v_org and category_id = v_cat), 0))
  returning id into v_id;
  return public.menu_item_settings(jsonb_build_object('id', v_id));
end $$;

-- The detailed settings of one dish: what the settings screen shows and edits, plus the lists it picks from.
create or replace function public.menu_item_settings(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); m public.menu_items%rowtype;
begin
  select * into m from public.menu_items where id = nullif(p->>'id', '')::uuid and organization_id = v_org;
  if not found then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  return jsonb_build_object('id', m.id, 'version', m.edit_version, 'name', m.name, 'price_minor', round(m.price * 100)::bigint,
    'category_id', m.category_id, 'category', (select name from public.menu_categories where id = m.category_id),
    'food_type', m.food_type, 'course', m.course, 'station', m.station, 'prep_minutes', m.prep_minutes, 'is_recommended', m.is_recommended,
    'sku', m.sku, 'is_available', m.is_available, 'image_url', m.image_url, 'description', m.description,
    'addon_group_ids', coalesce((select jsonb_agg(group_id) from public.menu_item_addon_groups where menu_item_id = m.id), '[]'),
    'recipe', public.mb_recipe_json(v_org, m.id) - 'lines',
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort_order, name)
                            from public.menu_categories where organization_id = v_org), '[]'),
    'addon_groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name,
                               'addons', (select count(*) from public.menu_addons a where a.group_id = g.id and a.active)) order by g.sort_order, g.name)
                              from public.menu_addon_groups g where g.organization_id = v_org and g.active), '[]'),
    'stations', '["main","grill","beverage","dessert","tandoor","chinese"]'::jsonb);
end $$;

create or replace function public.menu_item_settings_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); m public.menu_items%rowtype; v_name text; v_price numeric; v_cat uuid; v_sku text; g text;
begin
  select * into m from public.menu_items where id = nullif(p->>'id', '')::uuid and organization_id = v_org for update;
  if not found then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  if nullif(p->>'version', '') is null or (p->>'version')::bigint <> m.edit_version then raise exception 'POS_STALE: this dish was changed on another device'; end if;
  v_name := coalesce(public.mb_clean(p->>'name'), m.name);
  if char_length(v_name) not between 2 and 120 then raise exception 'POS_BAD_REQUEST: enter the dish name'; end if;
  v_price := case when p ? 'price' then round((p->>'price')::numeric, 2) else m.price end;
  if v_price is null or v_price <= 0 or v_price > 1000000 then raise exception 'POS_BAD_REQUEST: enter a selling price above zero'; end if;
  v_cat := case when nullif(p->>'category_id', '') is not null then (select id from public.menu_categories where id = (p->>'category_id')::uuid and organization_id = v_org)
                when public.mb_clean(p->>'category') is not null then public.mb_category(v_org, p->>'category') else m.category_id end;
  if v_cat is null then raise exception 'POS_NOT_FOUND: category not found'; end if;
  v_sku := case when p ? 'sku' then public.mb_clean(p->>'sku') else m.sku end;
  if v_sku is not null and exists (select 1 from public.menu_items where organization_id = v_org and lower(sku) = lower(v_sku) and id <> m.id) then
    raise exception 'POS_CONFLICT: another dish already uses the code %', v_sku; end if;
  if p ? 'food_type' and p->>'food_type' not in ('veg', 'non_veg', 'egg') then raise exception 'POS_BAD_REQUEST: choose veg, non-veg or egg'; end if;
  if p ? 'course' and p->>'course' not in ('eat', 'drink') then raise exception 'POS_BAD_REQUEST: course is eat or drink'; end if;
  if p ? 'prep_minutes' and ((p->>'prep_minutes')::int < 0 or (p->>'prep_minutes')::int > 240) then raise exception 'POS_BAD_REQUEST: preparation time is 0 to 240 minutes'; end if;
  if p ? 'station' and coalesce(public.mb_clean(p->>'station'), '') = '' then raise exception 'POS_BAD_REQUEST: choose a kitchen station'; end if;
  if exists (select 1 from public.menu_items where organization_id = v_org and category_id = v_cat and lower(name) = lower(v_name) and id <> m.id) then
    raise exception 'POS_CONFLICT: % is already in this category', v_name; end if;
  update public.menu_items set name = v_name, price = v_price, category_id = v_cat, sku = v_sku,
    food_type = coalesce(p->>'food_type', food_type), course = coalesce(p->>'course', course),
    station = coalesce(public.mb_clean(p->>'station'), station), prep_minutes = coalesce((p->>'prep_minutes')::int, prep_minutes),
    is_recommended = coalesce((p->>'is_recommended')::boolean, is_recommended), updated_at = now()
   where id = m.id;
  if jsonb_typeof(p->'addon_group_ids') = 'array' then
    delete from public.menu_item_addon_groups where menu_item_id = m.id;
    for g in select jsonb_array_elements_text(p->'addon_group_ids') loop
      if not exists (select 1 from public.menu_addon_groups where id = g::uuid and organization_id = v_org) then raise exception 'POS_NOT_FOUND: add-on group not found'; end if;
      insert into public.menu_item_addon_groups (menu_item_id, group_id, organization_id) values (m.id, g::uuid, v_org) on conflict do nothing;
    end loop;
  end if;
  return public.menu_item_settings(jsonb_build_object('id', m.id));
end $$;

-- ---------------------------------------------------------------- add-ons

create or replace function public.menu_addon_list(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update');
begin
  return jsonb_build_object('groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'min_select', g.min_select,
      'max_select', g.max_select, 'active', g.active,
      'dish_count', (select count(*) from public.menu_item_addon_groups x where x.group_id = g.id),
      'addons', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'price_minor', round(a.price * 100)::bigint,
                  'food_type', a.food_type, 'active', a.active) order by a.sort_order, a.name) from public.menu_addons a where a.group_id = g.id), '[]'))
    order by g.sort_order, g.name) from public.menu_addon_groups g where g.organization_id = v_org), '[]'));
end $$;

-- Creates or changes one add-on group and its whole list of add-ons (rows left out are removed).
create or replace function public.menu_addon_group_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); v_id uuid := nullif(p->>'id', '')::uuid; v_name text := public.mb_clean(p->>'name');
  v_min int := coalesce(nullif(p->>'min_select', '')::int, 0); v_max int := coalesce(nullif(p->>'max_select', '')::int, 1); a jsonb; v_keep uuid[] := '{}'; v_aid uuid; v_n int := 0;
  v_price numeric;
begin
  if v_name is null or char_length(v_name) > 60 then raise exception 'POS_BAD_REQUEST: enter the group name (up to 60 characters)'; end if;
  if v_min < 0 or v_max < 1 or v_min > v_max or v_max > 20 then raise exception 'POS_BAD_REQUEST: choose between 0 and 20, the minimum not above the maximum'; end if;
  if jsonb_typeof(p->'addons') <> 'array' or jsonb_array_length(p->'addons') = 0 then raise exception 'POS_BAD_REQUEST: add at least one add-on'; end if;
  if jsonb_array_length(p->'addons') > 50 then raise exception 'POS_BAD_REQUEST: up to 50 add-ons in a group'; end if;
  if exists (select 1 from public.menu_addon_groups where organization_id = v_org and lower(btrim(name)) = lower(v_name) and id is distinct from v_id) then
    raise exception 'POS_CONFLICT: there is already an add-on group called %', v_name; end if;
  if v_id is null then
    insert into public.menu_addon_groups (organization_id, name, min_select, max_select, sort_order)
    values (v_org, v_name, v_min, v_max, coalesce((select max(sort_order) + 1 from public.menu_addon_groups where organization_id = v_org), 0)) returning id into v_id;
  else
    update public.menu_addon_groups set name = v_name, min_select = v_min, max_select = v_max, active = coalesce((p->>'active')::boolean, active), updated_at = now()
     where id = v_id and organization_id = v_org;
    if not found then raise exception 'POS_NOT_FOUND: add-on group not found'; end if;
  end if;
  for a in select * from jsonb_array_elements(p->'addons') loop
    v_n := v_n + 1;
    if public.mb_clean(a->>'name') is null or char_length(public.mb_clean(a->>'name')) > 60 then raise exception 'POS_BAD_REQUEST: every add-on needs a name (up to 60 characters)'; end if;
    v_price := round(coalesce(nullif(a->>'price', '')::numeric, 0), 2);
    if v_price < 0 or v_price > 100000 then raise exception 'POS_BAD_REQUEST: an add-on price is zero or more'; end if;
    if coalesce(a->>'food_type', 'veg') not in ('veg', 'non_veg', 'egg') then raise exception 'POS_BAD_REQUEST: choose veg, non-veg or egg'; end if;
    v_aid := nullif(a->>'id', '')::uuid;
    if v_aid is not null and exists (select 1 from public.menu_addons where id = v_aid and group_id = v_id) then
      update public.menu_addons set name = public.mb_clean(a->>'name'), price = v_price, food_type = coalesce(a->>'food_type', 'veg'),
             active = coalesce((a->>'active')::boolean, true), sort_order = v_n where id = v_aid;
    else
      insert into public.menu_addons (organization_id, group_id, name, price, food_type, active, sort_order)
      values (v_org, v_id, public.mb_clean(a->>'name'), v_price, coalesce(a->>'food_type', 'veg'), coalesce((a->>'active')::boolean, true), v_n) returning id into v_aid;
    end if;
    v_keep := v_keep || v_aid;
  end loop;
  delete from public.menu_addons where group_id = v_id and not (id = any (v_keep));
  if jsonb_typeof(p->'menu_item_ids') = 'array' then
    delete from public.menu_item_addon_groups where group_id = v_id;
    insert into public.menu_item_addon_groups (menu_item_id, group_id, organization_id)
    select m.id, v_id, v_org from public.menu_items m where m.organization_id = v_org and m.id::text in (select jsonb_array_elements_text(p->'menu_item_ids'))
    on conflict do nothing;
  end if;
  return jsonb_build_object('id', v_id) || public.menu_addon_list('{}');
end $$;

create or replace function public.menu_addon_group_delete(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'delete');
begin
  delete from public.menu_addon_groups where id = nullif(p->>'id', '')::uuid and organization_id = v_org;
  if not found then raise exception 'POS_NOT_FOUND: add-on group not found'; end if;
  return public.menu_addon_list('{}');
end $$;

-- ---------------------------------------------------------------- combos

create or replace function public.menu_combo_list(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update');
begin
  return jsonb_build_object('combos', coalesce((select jsonb_agg(x order by x->>'name') from (
    select jsonb_build_object('id', c.id, 'name', c.name, 'description', c.description, 'price_minor', round(c.price * 100)::bigint, 'active', c.active,
      'items', coalesce((select jsonb_agg(jsonb_build_object('menu_item_id', m.id, 'name', m.name, 'qty', ci.qty, 'price_minor', round(m.price * 100)::bigint,
                         'food_type', m.food_type) order by m.name)
                         from public.menu_combo_items ci join public.menu_items m on m.id = ci.menu_item_id where ci.combo_id = c.id), '[]'),
      'separate_minor', coalesce((select sum(round(m.price * 100)::bigint * ci.qty) from public.menu_combo_items ci join public.menu_items m on m.id = ci.menu_item_id
                                   where ci.combo_id = c.id), 0)) as x
      from public.menu_combos c where c.organization_id = v_org) s), '[]'),
    'dishes', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'price_minor', round(m.price * 100)::bigint, 'food_type', m.food_type,
                          'category', c.name) order by c.sort_order nulls last, m.name)
                        from public.menu_items m left join public.menu_categories c on c.id = m.category_id where m.organization_id = v_org), '[]'));
end $$;

create or replace function public.menu_combo_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); v_id uuid := nullif(p->>'id', '')::uuid; v_name text := public.mb_clean(p->>'name'); v_price numeric; i jsonb;
  v_desc text := public.mb_clean(p->>'description'); v_total int := 0;
begin
  if v_name is null or char_length(v_name) not between 2 and 80 then raise exception 'POS_BAD_REQUEST: enter the combo name'; end if;
  if v_desc is not null and char_length(v_desc) > 300 then raise exception 'POS_BAD_REQUEST: a description is up to 300 characters'; end if;
  begin v_price := round((p->>'price')::numeric, 2); exception when others then v_price := null; end;
  if v_price is null or v_price <= 0 or v_price > 1000000 then raise exception 'POS_BAD_REQUEST: enter a combo price above zero'; end if;
  if jsonb_typeof(p->'items') <> 'array' then raise exception 'POS_BAD_REQUEST: choose the dishes in the combo'; end if;
  select coalesce(sum(coalesce(nullif(x->>'qty', '')::int, 1)), 0) into v_total from jsonb_array_elements(p->'items') x;
  if v_total < 2 then raise exception 'POS_BAD_REQUEST: a combo needs at least two dishes'; end if;
  if exists (select 1 from public.menu_combos where organization_id = v_org and lower(btrim(name)) = lower(v_name) and id is distinct from v_id) then
    raise exception 'POS_CONFLICT: there is already a combo called %', v_name; end if;
  if v_id is null then
    insert into public.menu_combos (organization_id, name, description, price) values (v_org, v_name, v_desc, v_price) returning id into v_id;
  else
    update public.menu_combos set name = v_name, description = v_desc, price = v_price, active = coalesce((p->>'active')::boolean, active), updated_at = now()
     where id = v_id and organization_id = v_org;
    if not found then raise exception 'POS_NOT_FOUND: combo not found'; end if;
    delete from public.menu_combo_items where combo_id = v_id;
  end if;
  for i in select * from jsonb_array_elements(p->'items') loop
    if not exists (select 1 from public.menu_items where id = nullif(i->>'menu_item_id', '')::uuid and organization_id = v_org) then
      raise exception 'POS_NOT_FOUND: a dish in this combo was not found'; end if;
    if coalesce(nullif(i->>'qty', '')::int, 1) not between 1 and 20 then raise exception 'POS_BAD_REQUEST: a dish appears 1 to 20 times in a combo'; end if;
    insert into public.menu_combo_items (combo_id, menu_item_id, organization_id, qty)
    values (v_id, (i->>'menu_item_id')::uuid, v_org, coalesce(nullif(i->>'qty', '')::int, 1))
    on conflict (combo_id, menu_item_id) do update set qty = menu_combo_items.qty + excluded.qty;
  end loop;
  return jsonb_build_object('id', v_id) || public.menu_combo_list('{}');
end $$;

create or replace function public.menu_combo_delete(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'delete');
begin
  delete from public.menu_combos where id = nullif(p->>'id', '')::uuid and organization_id = v_org;
  if not found then raise exception 'POS_NOT_FOUND: combo not found'; end if;
  return public.menu_combo_list('{}');
end $$;

-- ---------------------------------------------------------------- grants: signed-in people only (the functions check the role)

do $$
declare f text;
begin
  foreach f in array array['mb_org(text,text)', 'mb_clean(text)', 'mb_ing_cost(uuid,uuid)', 'mb_on_hand(uuid,uuid)', 'mb_recipe_json(uuid,uuid)', 'mb_category(uuid,text)',
    'ing_list(jsonb)', 'ing_library(jsonb)', 'ing_add_from_library(jsonb)', 'ing_save(jsonb)', 'rcp_list(jsonb)', 'rcp_view(jsonb)', 'rcp_save(jsonb)',
    'menu_category_save(jsonb)', 'menu_item_quick_add(jsonb)', 'menu_item_settings(jsonb)', 'menu_item_settings_save(jsonb)',
    'menu_addon_list(jsonb)', 'menu_addon_group_save(jsonb)', 'menu_addon_group_delete(jsonb)',
    'menu_combo_list(jsonb)', 'menu_combo_save(jsonb)', 'menu_combo_delete(jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
  end loop;
  -- helpers stay internal; the gateway-facing ones are for signed-in people
  foreach f in array array['ing_list(jsonb)', 'ing_library(jsonb)', 'ing_add_from_library(jsonb)', 'ing_save(jsonb)', 'rcp_list(jsonb)', 'rcp_view(jsonb)', 'rcp_save(jsonb)',
    'menu_category_save(jsonb)', 'menu_item_quick_add(jsonb)', 'menu_item_settings(jsonb)', 'menu_item_settings_save(jsonb)',
    'menu_addon_list(jsonb)', 'menu_addon_group_save(jsonb)', 'menu_addon_group_delete(jsonb)',
    'menu_combo_list(jsonb)', 'menu_combo_save(jsonb)', 'menu_combo_delete(jsonb)'] loop
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;


-- ----------------------------------------------------------------------------------------------------------------------------
-- 0601_menu_stock_signals.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0601 Stock tags on the Menu (founder, 27 Oct 2026): beside "Available", a dish shows "Out of stock" (red) or "Low in stock" (orange)
-- worked out from its recipe (0600: menu_item_recipes) and its ingredients' stock. Read only. Safe to run again.
--   * out: an ingredient that has been stocked (it has stock movements) has less on hand than one serving needs (with wastage);
--   * low: an ingredient with a reorder level is at or below it.
-- Ingredients never stocked through receiving are not judged (a new business would otherwise see every dish "out").
-- A dish switched off on the menu is "out of stock" from menu_items.is_available already; this only adds what stock says.


create or replace function public.menu_stock_signals(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_items jsonb := '[]'; r record; v_state text; v_ing text; l record; v_on numeric;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  for r in select distinct mr.menu_item_id from public.menu_item_recipes mr where mr.organization_id = v_org loop
    v_state := null; v_ing := null;
    for l in select mr.qty_per_unit, mr.wastage_pct, i.id, i.name, i.reorder_level
               from public.menu_item_recipes mr join public.inventory_items i on i.id = mr.inventory_item_id
              where mr.menu_item_id = r.menu_item_id and mr.organization_id = v_org
                and exists (select 1 from public.stock_movements m where m.organization_id = v_org and m.inventory_item_id = i.id)
              order by mr.is_key desc, i.name loop
      v_on := public.mb_on_hand(v_org, l.id);
      if v_on < l.qty_per_unit * (1 + l.wastage_pct / 100) then
        v_state := 'out'; v_ing := l.name; exit;
      elsif l.reorder_level > 0 and v_on <= l.reorder_level and v_state is null then
        v_state := 'low'; v_ing := l.name;
      end if;
    end loop;
    if v_state is not null then
      v_items := v_items || jsonb_build_object('menu_item_id', r.menu_item_id, 'state', v_state, 'ingredient', v_ing);
    end if;
  end loop;
  return jsonb_build_object('items', v_items);
end $$;

revoke all on function public.menu_stock_signals(jsonb) from public, anon;
grant execute on function public.menu_stock_signals(jsonb) to authenticated, service_role;


-- ----------------------------------------------------------------------------------------------------------------------------
-- 0602_table_manage.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0602 Manage tables in the app (founder, 27 Oct 2026): create, rename, change seats, remove. Until now nothing in the app could make a
-- table (dining_tables had no writer). Safe to run again.
--   * who: tbl_guard(p, 'manage') -> tbl_can_manage (dining_tables:manage, or both order place and order update_status) at that outlet;
--   * a name is unique per outlet; making a name that a removed (hidden) table had brings that table back, with its history;
--   * remove: refused while the table is occupied or has an upcoming reservation; a table that has orders or other history is hidden
--     (is_active = false: the floor no longer shows it, past bills keep pointing at it); a table with no history is deleted.


create or replace function public.tbl_table_list(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'read'); v_org uuid := public.current_org_id();
begin
  return jsonb_build_object(
    'location_id', v_loc,
    'can_manage', public.tbl_can_manage(v_org, v_loc),
    'tables', coalesce((
      select jsonb_agg(jsonb_build_object('id', t.id, 'label', t.label, 'seats', t.seats, 'sort_order', t.sort_order,
               'status', coalesce(s.status, 'available'),
               'has_history', exists (select 1 from public.orders o where o.table_id = t.id))
             order by t.sort_order, t.label)
        from public.dining_tables t left join public.tbl_states(v_org, v_loc) s on s.table_id = t.id
       where t.organization_id = v_org and t.is_active and coalesce(t.location_id, public.tbl_main(v_org)) = v_loc), '[]'));
end $$;

create or replace function public.tbl_table_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'manage'); v_org uuid := public.current_org_id(); v_id uuid := nullif(p->>'id', '')::uuid;
  v_label text := upper(btrim(regexp_replace(coalesce(p->>'label', ''), '\s+', ' ', 'g'))); v_seats int; t public.dining_tables%rowtype; v_hidden uuid;
begin
  if char_length(v_label) not between 1 and 20 then raise exception 'TBL_BAD_REQUEST: give the table a name of up to 20 characters (for example T6)'; end if;
  begin v_seats := (p->>'seats')::int; exception when others then v_seats := null; end;
  if v_seats is null or v_seats not between 1 and 50 then raise exception 'TBL_BAD_REQUEST: seats are 1 to 50'; end if;
  if exists (select 1 from public.dining_tables x where x.organization_id = v_org and x.is_active and coalesce(x.location_id, public.tbl_main(v_org)) = v_loc
               and upper(x.label) = v_label and x.id is distinct from v_id) then
    raise exception 'TBL_CONFLICT: there is already a table called %', v_label; end if;

  if v_id is null then
    -- a removed table with this name comes back (keeps its past bills) instead of clashing with it
    select x.id into v_hidden from public.dining_tables x where x.organization_id = v_org and not x.is_active
       and coalesce(x.location_id, public.tbl_main(v_org)) = v_loc and upper(x.label) = v_label limit 1;
    if v_hidden is not null then
      update public.dining_tables set is_active = true, seats = v_seats, min_capacity = least(min_capacity, v_seats), updated_at = now()
       where id = v_hidden returning * into t;
    else
      insert into public.dining_tables (organization_id, location_id, label, seats, sort_order)
      values (v_org, v_loc, v_label, v_seats,
              coalesce((select max(sort_order) + 1 from public.dining_tables x where x.organization_id = v_org and coalesce(x.location_id, public.tbl_main(v_org)) = v_loc), 1))
      returning * into t;
    end if;
  else
    if exists (select 1 from public.dining_tables x where x.organization_id = v_org and not x.is_active and coalesce(x.location_id, public.tbl_main(v_org)) = v_loc
                 and upper(x.label) = v_label and x.id <> v_id) then
      raise exception 'TBL_CONFLICT: a removed table was called %; add it again instead of renaming', v_label; end if;
    update public.dining_tables set label = v_label, seats = v_seats, min_capacity = least(min_capacity, v_seats), updated_at = now()
     where id = v_id and organization_id = v_org and is_active and coalesce(location_id, public.tbl_main(v_org)) = v_loc returning * into t;
    if not found then raise exception 'TBL_NOT_FOUND: table not found'; end if;
  end if;
  return jsonb_build_object('id', t.id) || public.tbl_table_list(jsonb_build_object('location_id', v_loc));
end $$;

create or replace function public.tbl_table_remove(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'manage'); v_org uuid := public.current_org_id(); v_id uuid := nullif(p->>'id', '')::uuid;
  t public.dining_tables%rowtype; v_state text; v_hidden boolean;
begin
  select * into t from public.dining_tables where id = v_id and organization_id = v_org and is_active and coalesce(location_id, public.tbl_main(v_org)) = v_loc for update;
  if not found then raise exception 'TBL_NOT_FOUND: table not found'; end if;
  select s.status into v_state from public.tbl_states(v_org, v_loc) s where s.table_id = t.id;
  if v_state = 'occupied' then raise exception 'TBL_WRONG_STATE: % has guests; settle its bill before removing it', t.label; end if;
  if v_state = 'reserved' then raise exception 'TBL_WRONG_STATE: % has a reservation; cancel it first', t.label; end if;
  v_hidden := exists (select 1 from public.orders o where o.table_id = t.id)
           or exists (select 1 from public.table_sessions x where x.table_id = t.id)
           or exists (select 1 from public.pos_reservations x where x.table_id = t.id::text)
           or exists (select 1 from public.table_merge_members x where x.table_id = t.id);
  if v_hidden then
    update public.dining_tables set is_active = false, qr_enabled = false, updated_at = now() where id = t.id;
  else
    delete from public.dining_tables where id = t.id;
  end if;
  return jsonb_build_object('removed', t.label, 'hidden', v_hidden) || public.tbl_table_list(jsonb_build_object('location_id', v_loc));
end $$;

revoke all on function public.tbl_table_list(jsonb) from public, anon;
revoke all on function public.tbl_table_save(jsonb) from public, anon;
revoke all on function public.tbl_table_remove(jsonb) from public, anon;
grant execute on function public.tbl_table_list(jsonb) to authenticated, service_role;
grant execute on function public.tbl_table_save(jsonb) to authenticated, service_role;
grant execute on function public.tbl_table_remove(jsonb) to authenticated, service_role;


-- ----------------------------------------------------------------------------------------------------------------------------
-- 0603_table_mark_clean.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0603 "Mark as clean" (founder, 27 Oct 2026): a table shows Cleaning for 10 minutes after its bill is paid or its session closes
-- (tbl_states); floor staff can now end that early. Safe to run again.
--   * dining_tables.cleaned_at: when someone marked the table clean;
--   * tbl_states: a table marked clean after its last bill is not Cleaning (everything else exactly as before);
--   * tbl_mark_clean: only a Cleaning table; joined (merged) tables are one place, so every member is marked; floor staff only
--     (tbl_guard 'read': order place, order update status or table manager).


alter table public.dining_tables add column if not exists cleaned_at timestamptz;

create or replace function public.tbl_states(p_org uuid, p_loc uuid, p_table uuid default null::uuid)
 returns table(table_id uuid, status text, since timestamp with time zone, reserved_at timestamp with time zone, reservation_id uuid, open_orders integer)
 language sql stable security definer set search_path to 'public', 'pg_temp'
as $function$
  with t as (select id, cleaned_at from public.dining_tables
              where organization_id = p_org and is_active and coalesce(location_id, public.tbl_main(p_org)) = p_loc),
  oo as (select o.table_id, count(*)::int n, min(o.created_at) first_at from public.orders o
          where o.organization_id = p_org and o.table_id is not null and public.tbl_order_open(o.status, o.paid_at) group by o.table_id),
  ss as (select s.table_id, min(s.opened_at) first_at from public.table_sessions s where s.organization_id = p_org and s.status in ('open', 'billed') group by s.table_id),
  cl as (select x.table_id, max(x.at) at from (
           select o.table_id, coalesce(o.paid_at, o.updated_at) at from public.orders o
            where o.organization_id = p_org and o.table_id is not null and (o.status = 'paid' or (o.status = 'delivered' and o.paid_at is not null))
           union all select s.table_id, s.closed_at from public.table_sessions s where s.organization_id = p_org and s.status = 'closed' and s.closed_at is not null) x group by x.table_id),
  rv as (select distinct on (r.table_id) r.table_id, r.scheduled_at, r.row_id from public.pos_reservations r
          where r.organization_id = p_org and r.deleted_at is null and lower(r.status) in ('confirmed', 'reserved', 'booked', 'pending')
            and r.scheduled_at between now() - interval '30 minutes' and now() + interval '120 minutes'
          order by r.table_id, r.scheduled_at),
  base as (
    select t.id,
           case when coalesce(oo.n, 0) > 0 or ss.table_id is not null then 'occupied'
                -- 0603: marked clean after the last bill = not Cleaning any more
                when cl.at is not null and cl.at > now() - interval '10 minutes' and (t.cleaned_at is null or t.cleaned_at < cl.at) then 'cleaning'
                when rv.row_id is not null then 'reserved' else 'available' end st,
           case when coalesce(oo.n, 0) > 0 or ss.table_id is not null then least(coalesce(oo.first_at, ss.first_at), coalesce(ss.first_at, oo.first_at)) end sn,
           rv.scheduled_at rat, rv.row_id rid, coalesce(oo.n, 0) n
      from t left join oo on oo.table_id = t.id left join ss on ss.table_id = t.id left join cl on cl.table_id = t.id left join rv on rv.table_id = t.id::text),
  gm as (select m.table_id, m.merge_id from public.table_merge_members m where m.organization_id = p_org and m.released_at is null),
  -- joined tables are one place: occupied if ANY member is, the earliest booking of any member shows, the open orders add up
  agg as (select gm.merge_id, bool_or(b.st = 'occupied') occ, bool_or(b.st = 'cleaning') cln, sum(b.n)::int n, min(b.sn) sn, min(b.rat) rat,
                 (array_agg(b.rid order by b.rat) filter (where b.rid is not null))[1] rid
            from gm join base b on b.id = gm.table_id group by gm.merge_id)
  select b.id,
         case when g.merge_id is null then b.st when a.occ then 'occupied' when a.cln then 'cleaning' when a.rat is not null then 'reserved' else 'available' end,
         case when g.merge_id is null then b.sn when a.occ then a.sn end,
         case when g.merge_id is null then b.rat when not a.occ and not a.cln then a.rat end,
         case when g.merge_id is null then b.rid when not a.occ and not a.cln then a.rid end,
         case when g.merge_id is null then b.n else a.n end
    from base b left join gm g on g.table_id = b.id left join agg a on a.merge_id = g.merge_id
   where p_table is null or b.id = p_table;
$function$;

create or replace function public.tbl_mark_clean(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'read'); v_org uuid := public.current_org_id(); v_id uuid := nullif(p->>'table_id', '')::uuid;
  v_label text; v_state text; v_merge uuid; v_n int;
begin
  select label into v_label from public.dining_tables where id = v_id and organization_id = v_org and is_active and coalesce(location_id, public.tbl_main(v_org)) = v_loc;
  if v_label is null then raise exception 'TBL_NOT_FOUND: table not found'; end if;
  select s.status into v_state from public.tbl_states(v_org, v_loc, v_id) s;
  if coalesce(v_state, '') <> 'cleaning' then
    raise exception 'TBL_WRONG_STATE: % is %, not cleaning', v_label, coalesce(v_state, 'available'); end if;
  select merge_id into v_merge from public.table_merge_members where table_id = v_id and organization_id = v_org and released_at is null limit 1;
  update public.dining_tables d set cleaned_at = now(), updated_at = now()
   where d.organization_id = v_org
     and (d.id = v_id or (v_merge is not null and d.id in (select m.table_id from public.table_merge_members m where m.merge_id = v_merge and m.released_at is null)));
  get diagnostics v_n = row_count;
  select s.status into v_state from public.tbl_states(v_org, v_loc, v_id) s;
  return jsonb_build_object('table_id', v_id, 'label', v_label, 'status', v_state, 'tables_marked', v_n);
end $$;

revoke all on function public.tbl_mark_clean(jsonb) from public, anon;
grant execute on function public.tbl_mark_clean(jsonb) to authenticated, service_role;


-- ----------------------------------------------------------------------------------------------------------------------------
-- 0604_bill_order_types.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0604: the Bill's Dine in / Takeaway / Delivery pills and the veg / non-veg mark on its menu squares.
--   * pos_sell_catalog answers each dish's food_type (veg / non_veg / egg) as well; nothing else changes.
--   * pos_counter_order(p) places a Takeaway (service type pickup) or Delivery order from the Bill without a table:
--     the same pos_place_order as every other order (prices, GST, role), in the outlet the screen looks at, unpaid.
--     send true fires a KOT at once (tbl_kot_fire, the same ticket a table gets); false holds it "in billing".
--     Delivery needs the customer's phone and address; the address is kept on the order's notes.

create or replace function public.pos_sell_catalog(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_q text := nullif(btrim(coalesce(p->>'q', '')), ''); v_cat text := nullif(btrim(coalesce(p->>'category', '')), '');
  v_av boolean; v_sort text := coalesce(nullif(p->>'sort', ''), 'name'); v_like text;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_sort not in ('name', 'price_asc', 'price_desc') then raise exception 'POS_BAD_REQUEST: unknown sort'; end if;
  begin v_av := coalesce((p->>'available')::boolean, false); exception when others then raise exception 'POS_BAD_REQUEST: available is true or false'; end;
  v_like := '%' || regexp_replace(coalesce(v_q, ''), '([%_\\])', '\\\1', 'g') || '%';
  return jsonb_build_object(
    'items', (select coalesce(jsonb_agg(j order by o1, o2 desc, o3), '[]'::jsonb) from (
        select jsonb_build_object('id', i.id, 'name', i.name, 'sku', coalesce(i.sku, ''), 'price', i.price, 'image_url', i.image_url, 'available', i.is_available,
                 'category', coalesce(c.name, ''), 'food_type', coalesce(i.food_type, 'veg')) as j,
               case when v_sort = 'price_asc' then i.price end as o1, case when v_sort = 'price_desc' then i.price end as o2, i.name as o3
        from public.menu_items i left join public.menu_categories c on c.id = i.category_id
        where i.organization_id = v_org and (not v_av or i.is_available)
          and (v_q is null or i.name ilike v_like or coalesce(i.sku, '') ilike v_like)
          and (v_cat is null or lower(coalesce(c.name, '')) = lower(v_cat))
        order by o1 asc, o2 desc, o3 limit 200) s),
    'categories', (select coalesce(jsonb_agg(n order by n), '[]'::jsonb) from (
        select distinct c.name as n from public.menu_items i join public.menu_categories c on c.id = i.category_id where i.organization_id = v_org) k));
end $$;

create or replace function public.pos_counter_order(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_loc uuid := public.tbl_guard(p, 'order'); v_org uuid := public.current_org_id();
  v_type text := coalesce(nullif(p->>'service_type', ''), 'pickup'); v_send boolean; v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), '');
  v_name text := nullif(btrim(coalesce(p->>'customer_name', '')), ''); v_phone text := nullif(regexp_replace(coalesce(p->>'customer_phone', ''), '\D', '', 'g'), '');
  v_addr text := nullif(btrim(coalesce(p->>'address', '')), ''); v_notes text := nullif(btrim(coalesce(p->>'notes', '')), '');
  v_res jsonb; v_id uuid; v_kot jsonb;
begin
  if v_key is null or char_length(v_key) > 100 then raise exception 'POS_BAD_REQUEST: an Idempotency-Key is needed so a retry never places the order twice'; end if;
  if v_type not in ('pickup', 'delivery') then raise exception 'POS_BAD_REQUEST: choose Takeaway or Delivery'; end if;
  begin v_send := coalesce((p->>'send')::boolean, true); exception when others then raise exception 'POS_BAD_REQUEST: send is true or false'; end;
  if v_type = 'delivery' then
    if v_phone is null or char_length(v_phone) < 10 then raise exception 'POS_BAD_REQUEST: enter the customer''s phone number for a delivery'; end if;
    if v_addr is null then raise exception 'POS_BAD_REQUEST: enter the delivery address'; end if;
  end if;
  if char_length(coalesce(v_addr, '')) > 300 then raise exception 'POS_BAD_REQUEST: the address can be up to 300 characters'; end if;

  v_res := public.pos_place_order(jsonb_build_object('organization_id', v_org, 'service_type', v_type, 'placed_by', 'pos', 'fire_kot', false,
    'idempotency_key', v_key, 'lines', p->'lines', 'customer_name', v_name, 'customer_phone', v_phone,
    'notes', nullif(concat_ws(' · ', case when v_addr is not null then 'Deliver to: ' || v_addr end, v_notes), '')));
  v_id := (v_res->>'id')::uuid;
  if coalesce((v_res->>'replayed')::boolean, false) then return jsonb_build_object('order_id', v_id, 'replayed', true, 'order', v_res); end if;
  if v_loc is not null then update public.orders set location_id = v_loc where id = v_id; end if;
  if v_send then v_kot := public.tbl_kot_fire(v_id); end if;
  return jsonb_build_object('order_id', v_id, 'replayed', false, 'held', not v_send, 'service_type', v_type, 'kot', v_kot,
    'order', jsonb_build_object('display_no', v_res->>'display_no', 'total', (v_res->>'total')::numeric, 'status', case when v_send then 'sent_to_kitchen' else 'in_billing' end));
end $$;

revoke all on function public.pos_counter_order(jsonb) from public, anon;
grant execute on function public.pos_counter_order(jsonb) to authenticated, service_role;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0605_menu_can_make.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0605: "200 can be made" on every dish (founder, 27 Oct 2026). How many of a dish the kitchen can still make, from its recipe (0600:
-- menu_item_recipes, with wastage) and each ingredient's stock on hand: the smallest floor(on hand / one serving) over its ingredients.
-- Orders already take their ingredients off stock when they go to the kitchen (order_stock_consume), so the count falls by one per dish
-- sent, and comes back if the order is cancelled. Read only. Safe to run again.
--   * menu_can_make(org, dish): the count; null when the dish has no recipe, or none of its ingredients has ever been stocked
--     (as 0601: a new business would otherwise see every dish at 0). Never below 0.
--   * pos_sell_catalog (the Bill's menu) answers can_make per dish; menu_stock_signals (the Menu tab) answers a can_make list.


create or replace function public.menu_can_make(p_org uuid, p_dish uuid) returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select greatest(0, min(floor(public.mb_on_hand(p_org, mr.inventory_item_id) / (mr.qty_per_unit * (1 + coalesce(mr.wastage_pct, 0) / 100)))))::int
    from public.menu_item_recipes mr
   where mr.organization_id = p_org and mr.menu_item_id = p_dish and mr.qty_per_unit > 0
     and exists (select 1 from public.stock_movements m where m.organization_id = p_org and m.inventory_item_id = mr.inventory_item_id)
$$;
revoke all on function public.menu_can_make(uuid, uuid) from public, anon;

create or replace function public.pos_sell_catalog(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_q text := nullif(btrim(coalesce(p->>'q', '')), ''); v_cat text := nullif(btrim(coalesce(p->>'category', '')), '');
  v_av boolean; v_sort text := coalesce(nullif(p->>'sort', ''), 'name'); v_like text;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_sort not in ('name', 'price_asc', 'price_desc') then raise exception 'POS_BAD_REQUEST: unknown sort'; end if;
  begin v_av := coalesce((p->>'available')::boolean, false); exception when others then raise exception 'POS_BAD_REQUEST: available is true or false'; end;
  v_like := '%' || regexp_replace(coalesce(v_q, ''), '([%_\\])', '\\\1', 'g') || '%';
  return jsonb_build_object(
    'items', (select coalesce(jsonb_agg(j order by o1, o2 desc, o3), '[]'::jsonb) from (
        select jsonb_build_object('id', i.id, 'name', i.name, 'sku', coalesce(i.sku, ''), 'price', i.price, 'image_url', i.image_url, 'available', i.is_available,
                 'category', coalesce(c.name, ''), 'food_type', coalesce(i.food_type, 'veg'),
                 'has_recipe', exists (select 1 from public.menu_item_recipes mr where mr.menu_item_id = i.id and mr.organization_id = v_org),
                 'can_make', public.menu_can_make(v_org, i.id)) as j,
               case when v_sort = 'price_asc' then i.price end as o1, case when v_sort = 'price_desc' then i.price end as o2, i.name as o3
        from public.menu_items i left join public.menu_categories c on c.id = i.category_id
        where i.organization_id = v_org and (not v_av or i.is_available)
          and (v_q is null or i.name ilike v_like or coalesce(i.sku, '') ilike v_like)
          and (v_cat is null or lower(coalesce(c.name, '')) = lower(v_cat))
        order by o1 asc, o2 desc, o3 limit 200) s),
    'categories', (select coalesce(jsonb_agg(n order by n), '[]'::jsonb) from (
        select distinct c.name as n from public.menu_items i join public.menu_categories c on c.id = i.category_id where i.organization_id = v_org) k));
end $$;

create or replace function public.menu_stock_signals(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_items jsonb := '[]'; r record; v_state text; v_ing text; l record; v_on numeric;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  for r in select distinct mr.menu_item_id from public.menu_item_recipes mr where mr.organization_id = v_org loop
    v_state := null; v_ing := null;
    for l in select mr.qty_per_unit, mr.wastage_pct, i.id, i.name, i.reorder_level
               from public.menu_item_recipes mr join public.inventory_items i on i.id = mr.inventory_item_id
              where mr.menu_item_id = r.menu_item_id and mr.organization_id = v_org
                and exists (select 1 from public.stock_movements m where m.organization_id = v_org and m.inventory_item_id = i.id)
              order by mr.is_key desc, i.name loop
      v_on := public.mb_on_hand(v_org, l.id);
      if v_on < l.qty_per_unit * (1 + l.wastage_pct / 100) then
        v_state := 'out'; v_ing := l.name; exit;
      elsif l.reorder_level > 0 and v_on <= l.reorder_level and v_state is null then
        v_state := 'low'; v_ing := l.name;
      end if;
    end loop;
    if v_state is not null then
      v_items := v_items || jsonb_build_object('menu_item_id', r.menu_item_id, 'state', v_state, 'ingredient', v_ing);
    end if;
  end loop;
  return jsonb_build_object('items', v_items,
    'can_make', (select coalesce(jsonb_agg(jsonb_build_object('menu_item_id', d.menu_item_id, 'can_make', public.menu_can_make(v_org, d.menu_item_id))), '[]'::jsonb)
                   from (select distinct mr.menu_item_id from public.menu_item_recipes mr where mr.organization_id = v_org) d));
end $$;

revoke all on function public.menu_stock_signals(jsonb) from public, anon;
grant execute on function public.menu_stock_signals(jsonb) to authenticated, service_role;


-- ----------------------------------------------------------------------------------------------------------------------------
-- 0606_takeaway_lines.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0606: takeaway dishes on a dine-in bill (founder, 27 Oct 2026). Guests eating at a table may also ask for some dishes to take away:
-- those go on the SAME table order (one bill) and each such line is marked takeaway, so the bill, the table's order and the kitchen
-- card say "Takeaway" (the kitchen packs it).
--   * order_items.is_takeaway (default false).
--   * tbl_order_add: a line may carry "takeaway": true. The lines of this call are marked after they are inserted (one row per line,
--     matched on dish and quantity among the rows this call added). Everything else is unchanged.
--   * tbl_order_view, rst_bill_order_json, kds_card_json, pos_order_view: each item also answers "takeaway".
-- The functions below are the live definitions with only those additions. Safe to run again.


alter table public.order_items add column if not exists is_takeaway boolean not null default false;

CREATE OR REPLACE FUNCTION public.tbl_order_add(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_loc uuid := public.tbl_guard(p, 'order'); v_org uuid := public.current_org_id(); t public.dining_tables%rowtype;
  v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), ''); v_hash text; v_prev jsonb; v_send boolean; v_line jsonb; v_qty int;
  v_item public.menu_items%rowtype; o public.orders%rowtype; v_oid uuid; v_kot jsonb; v_res jsonb; v_n int := 0; v_new boolean := false;
begin
  if v_key is null then raise exception 'TBL_BAD_REQUEST: an Idempotency-Key is needed so a retry never adds the dishes twice'; end if;
  begin v_send := coalesce((p->>'send')::boolean, true); exception when others then raise exception 'TBL_BAD_REQUEST: send is true or false'; end;
  v_hash := md5((p - 'idempotency_key')::text);
  v_prev := public.tbl_req_replay(v_org, v_key, 'add', v_hash);
  if v_prev is not null then return v_prev; end if;
  t := public.tbl_get(v_org, v_loc, nullif(p->>'table_id', '')::uuid);
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') not between 1 and 50 then raise exception 'TBL_BAD_REQUEST: add between 1 and 50 dishes'; end if;
  for v_line in select * from jsonb_array_elements(p->'lines') loop
    begin v_qty := (v_line->>'qty')::int; exception when others then v_qty := null; end;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'TBL_BAD_REQUEST: quantities are 1 to 99'; end if;
    if char_length(coalesce(v_line->>'notes', '')) > 200 then raise exception 'TBL_BAD_REQUEST: a note is at most 200 characters'; end if;
    select * into v_item from public.menu_items where id = nullif(v_line->>'menu_item_id', '')::uuid and organization_id = v_org;
    if not found or not v_item.is_available then raise exception 'TBL_ITEM_UNAVAILABLE: % is not available', coalesce(v_item.name, 'a dish'); end if;
    v_n := v_n + 1;
  end loop;

  -- the table's open order (joined tables share one); locked so two phones adding at once queue up
  select o2.* into o from public.orders o2 where o2.organization_id = v_org and o2.table_id = any(public.tbl_group(v_org, t.id))
     and public.tbl_order_open(o2.status, o2.paid_at) order by o2.created_at desc limit 1 for update;
  if not found then
    v_res := public.pos_place_order(jsonb_build_object('organization_id', v_org, 'service_type', 'dine_in', 'table_id', t.id, 'placed_by', 'pos', 'fire_kot', false,
      'guest_count', nullif(p->>'guest_count', ''), 'lines', p->'lines'));
    v_oid := (v_res->>'id')::uuid; v_new := true;
    select * into o from public.orders where id = v_oid for update;
  else
    if o.status not in ('new', 'in_billing', 'sent_to_kitchen', 'ready') then
      raise exception 'TBL_WRONG_STATE: the bill for this table is already %; start a new order after it is settled', replace(o.status, '_', ' '); end if;
    v_oid := o.id;
    insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, notes, station, course)
    select o.id, mi.id, mi.name, (l->>'qty')::int, mi.price, nullif(btrim(coalesce(l->>'notes', '')), ''), coalesce(mi.station, 'main'), coalesce(mi.course, 'eat')
      from jsonb_array_elements(p->'lines') l join public.menu_items mi on mi.id = (l->>'menu_item_id')::uuid and mi.organization_id = v_org;
    perform public.tbl_order_reprice(o.id);
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, o.id, 'items_added', v_n || ' dishes added to ' || o.display_no, 'pos', jsonb_build_object('by', auth.uid(), 'held', not v_send));
  end if;
  -- takeaway lines (0606): mark one of the rows this call added for each line sent with "takeaway": true
  for v_line in select * from jsonb_array_elements(p->'lines') loop
    continue when not coalesce((v_line->>'takeaway')::boolean, false);
    update public.order_items set is_takeaway = true
     where id = (select x.id from public.order_items x where x.order_id = v_oid and x.menu_item_id = (v_line->>'menu_item_id')::uuid
                    and x.qty = (v_line->>'qty')::int and x.created_at = now() and not x.is_takeaway and x.kot_ticket_id is null
                  order by x.id limit 1);
  end loop;
  if v_send then v_kot := public.tbl_kot_fire(v_oid); end if;
  v_res := jsonb_build_object('order_id', v_oid, 'new_order', v_new, 'held', not v_send, 'dishes_added', v_n, 'kot', v_kot,
    'order', (select jsonb_build_object('display_no', x.display_no, 'status', x.status, 'subtotal', x.subtotal, 'total', x.total) from public.orders x where x.id = v_oid),
    'table', jsonb_build_object('id', t.id, 'label', t.label));
  insert into public.table_order_requests (organization_id, idempotency_key, kind, request_hash, order_id, result, created_by)
  values (v_org, v_key, 'add', v_hash, v_oid, v_res, auth.uid());
  return v_res || jsonb_build_object('replayed', false);
end $function$

;

CREATE OR REPLACE FUNCTION public.tbl_order_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_loc uuid := public.tbl_guard(p, 'read'); v_org uuid := public.current_org_id(); t public.dining_tables%rowtype; mg jsonb; v_main uuid; v_grp uuid[]; v_st text; v_area text;
  v_update boolean; v_manage boolean; v_held boolean; v_bill boolean; v_place boolean;
begin
  t := public.tbl_get(v_org, v_loc, (p->>'table_id')::uuid);
  mg := public.tbl_merge_json(v_org, t.id);
  v_main := coalesce((mg->>'primary_table_id')::uuid, t.id);
  v_grp := public.tbl_group(v_org, t.id);
  select a.name into v_area from public.dining_areas a where a.id = t.area_id;
  v_update := public.has_permission(v_org, 'order', 'update_status', v_loc);
  v_place := public.has_permission(v_org, 'order', 'place', v_loc);
  v_manage := public.tbl_can_manage(v_org, v_loc);
  select o.status into v_st from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at) order by o.created_at desc limit 1;
  -- 0485: dishes held (not yet sent) on an order the kitchen can still take
  select exists (select 1 from public.orders o join public.order_items i on i.order_id = o.id where o.organization_id = v_org and o.table_id = any(v_grp)
                  and o.status in ('new', 'in_billing', 'sent_to_kitchen', 'ready') and i.kot_ticket_id is null and i.status = 'pending') into v_held;
  select exists (select 1 from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and o.status in ('in_billing', 'sent_to_kitchen', 'ready', 'delivered') and public.tbl_order_open(o.status, o.paid_at)) into v_bill;
  return jsonb_build_object('table', jsonb_build_object('id', t.id, 'label', t.label, 'seats', coalesce((mg->>'combined_seats')::int, t.seats), 'area_name', v_area, 'main_table_id', v_main),
    'status', case when v_st is null then null else jsonb_build_object('key', v_st, 'label', case v_st
        when 'sent_to_kitchen' then 'ACTIVE IN KITCHEN' when 'new' then 'NOT SENT TO KITCHEN' when 'in_billing' then 'NOT SENT TO KITCHEN'
        when 'ready' then 'READY TO SERVE' when 'delivered' then 'SERVED' when 'awaiting_payment' then 'AWAITING PAYMENT' else upper(v_st) end) end,
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'display_no', o.display_no, 'status', o.status, 'updated_at', o.updated_at, 'total', o.total, 'subtotal', o.subtotal) order by o.created_at), '[]'::jsonb)
                 from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at)),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'takeaway', i.is_takeaway, 'variant', i.variant_name, 'qty', i.qty, 'unit_price', i.unit_price, 'line_total', i.unit_price * i.qty,
                'status', i.status, 'sent', i.kot_ticket_id is not null,
                'status_label', case when i.kot_ticket_id is null and i.status = 'pending' then 'Not sent' else case i.status when 'pending' then 'Pending' when 'preparing' then 'Preparing' when 'ready' then 'Ready' when 'delivered' then 'Served' else initcap(i.status) end end,
                'notes', i.notes) order by o.created_at, i.created_at, i.id), '[]'::jsonb)
                from public.order_items i join public.orders o on o.id = i.order_id
               where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at) and i.status <> 'cancelled'),
    'timeline', (select coalesce(jsonb_agg(jsonb_build_object('at', e.created_at, 'message', e.message) order by e.created_at, e.id), '[]'::jsonb)
                   from (select ev.* from public.order_events ev join public.orders o on o.id = ev.order_id
                          where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at) order by ev.created_at desc limit 30) e),
    'subtotal', (select coalesce(sum(o.subtotal), 0) from public.orders o where o.organization_id = v_org and o.table_id = any(v_grp) and public.tbl_order_open(o.status, o.paid_at)),
    'can', jsonb_build_object('add_items', v_place and (v_st is null or v_st in ('new', 'in_billing', 'sent_to_kitchen', 'ready')),
                              'send_kot', (v_update or v_place) and v_held, 'print_kot', false, 'change_table', v_manage and v_st is not null and (mg is null),
                              'merge_table', v_manage and v_st is not null and (mg is null), 'generate_bill', v_update and v_bill),
    'unavailable', jsonb_build_object('print_kot', 'Printing a KOT is not in this release.'));
end $function$

;

CREATE OR REPLACE FUNCTION public.rst_bill_order_json(p_order uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object('id', o.id, 'display_no', o.display_no, 'status', o.status, 'updated_at', o.updated_at, 'created_at', o.created_at,
    'subtotal', o.subtotal, 'discount', o.discount, 'coupon_code', o.coupon_code, 'gst_pct', o.gst_pct, 'gst_amount', o.gst_amount,
    'service_charge', o.service_charge, 'round_off', o.round_off, 'total', o.total, 'paid', public.rst_paid(o.id),
    'due', greatest(o.total - public.rst_paid(o.id), 0), 'notes', o.notes, 'customer_phone', o.customer_phone,
    'bill_generated', o.status = 'awaiting_payment',
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'takeaway', i.is_takeaway, 'variant', i.variant_name, 'qty', i.qty, 'unit_price', i.unit_price,
                'line_total', i.unit_price * i.qty) order by i.created_at, i.id), '[]'::jsonb)
                from public.order_items i where i.order_id = o.id and i.status <> 'cancelled'),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', y.id, 'method', y.method, 'amount', y.amount, 'at', y.created_at,
                   'tendered', (select t.tendered from public.pos_cash_tenders t where t.payment_id = y.id)) order by y.created_at, y.id), '[]'::jsonb)
                   from public.payments y where y.order_id = o.id),
    'split', (select public.rst_split_json(s.id) from public.rst_bill_splits s where s.order_id = o.id and s.status in ('active', 'completed')
               order by s.created_at desc limit 1))
  from public.orders o where o.id = p_order;
$function$

;

CREATE OR REPLACE FUNCTION public.kds_card_json(p_ticket uuid, p_key text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'card_id', c.ticket_id || ':' || c.queue_key, 'id', c.ticket_id, 'station', c.queue_key,
    'station_name', coalesce((select s.name from public.pos_kitchen_stations s where s.organization_id = t.organization_id and s.key = c.queue_key), 'Unassigned'),
    'kot_no', c.kot_no, 'order_id', c.order_id, 'display_no', c.display_no, 'channel', c.channel, 'chip', c.chip, 'version', c.version,
    'status', case c.chip when 'new' then 'new' when 'in_progress' then 'preparing' when 'ready' then 'ready' else 'delivered' end,
    'priority', c.priority, 'age_minutes', greatest(0, floor(extract(epoch from now() - c.created_at) / 60))::int,
    'delayed', c.chip in ('new', 'in_progress') and c.created_at < now() - interval '15 minutes',
    'created_at', c.created_at, 'started_at', c.started_at, 'ready_at', case when c.chip in ('ready', 'served') then c.ready_at end, 'served_at', c.served_at,
    'table_label', (select d.label from public.dining_tables d where d.id = o.table_id and d.organization_id = o.organization_id),
    'order_note', nullif(btrim(coalesce(o.notes, '')), ''),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'takeaway', i.is_takeaway, 'qty', i.qty, 'status', i.status, 'done', i.status in ('ready', 'delivered'),
                 'station', i.station, 'notes', nullif(btrim(coalesce(i.notes, '')), ''), 'variant', i.variant_name) order by i.created_at, i.name)
               from public.order_items i where i.kot_ticket_id = t.id and i.status <> 'cancelled' and public.kitchen_queue_key(t.organization_id, i.station) = c.queue_key), '[]'::jsonb),
    'item_count', c.n_total, 'done_count', c.n_done,
    'stations', jsonb_build_array(coalesce((select s.name from public.pos_kitchen_stations s where s.organization_id = t.organization_id and s.key = c.queue_key), 'Unassigned')))
  from public.kot_tickets t join public.orders o on o.id = t.order_id
  join lateral public.kds_cards(t.organization_id, t.id) c on c.queue_key = p_key
  where t.id = p_ticket;
$function$

;

CREATE OR REPLACE FUNCTION public.pos_order_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_o public.orders%rowtype; v_res jsonb;
begin
  select * into v_o from public.orders where id = nullif(p->>'order_id', '')::uuid;
  if not found or auth.uid() is null or v_o.organization_id is distinct from public.current_org_id()
     or not public.location_is_allowed(v_o.organization_id, v_o.location_id) then raise exception 'POS_NOT_FOUND: order not found'; end if;
  select jsonb_build_object(
    'order', to_jsonb(v_o) - 'external_ref' - 'idempotency_key' - 'created_by',
    'table_label', (select t.label from public.dining_tables t where t.id = v_o.table_id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('order_item_id', i.id, 'menu_item_id', i.menu_item_id, 'name', i.name, 'takeaway', i.is_takeaway, 'qty', i.qty,
                'unit_price', i.unit_price, 'status', i.status, 'picked_qty', l.picked_qty, 'missing_qty', l.missing_qty) order by i.created_at, i.id), '[]'::jsonb)
              from public.order_items i left join public.pos_fulfilment_lines l on l.order_item_id = i.id where i.order_id = v_o.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', y.method, 'amount', y.amount, 'tendered', c.tendered, 'created_at', y.created_at) order by y.created_at), '[]'::jsonb)
                 from public.payments y left join public.pos_cash_tenders c on c.payment_id = y.id where y.order_id = v_o.id),
    'paid', (select coalesce(sum(amount), 0) from public.payments where order_id = v_o.id),
    'fulfilment', (select to_jsonb(f) - 'organization_id' from public.pos_fulfilments f where f.order_id = v_o.id),
    'next_events', (select coalesce(jsonb_agg(t.event order by t.event), '[]'::jsonb) from public.order_transitions t join public.pos_fulfilments f on f.order_id = v_o.id
                    where t.entity = 'pos_fulfilments' and t.from_status = f.stage and t.event <> 'cancel'),
    'online', (select jsonb_build_object('id', x.id, 'status', x.status, 'payment_method', x.payment_method, 'payment_status', x.payment_status,
                 'address', x.delivery_address, 'cancel_reason', x.cancel_reason, 'rider_name', x.rider_name, 'eta_minutes', x.eta_minutes)
               from public.ol_orders x where x.pos_order_id = v_o.id limit 1),
    'refunded', (select coalesce(sum(r.amount), 0) from public.ol_refunds r join public.ol_orders x on x.id = r.order_id where x.pos_order_id = v_o.id and r.status = 'processed'),
    'cancel_reason', (select e.meta->>'reason' from public.order_events e where e.order_id = v_o.id and e.kind = 'status_cancelled' order by e.created_at desc limit 1),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('kind', e.kind, 'message', e.message, 'at', e.created_at) order by e.created_at), '[]'::jsonb)
               from public.order_events e where e.order_id = v_o.id)
  ) into v_res;
  return v_res;
end $function$

;


-- ----------------------------------------------------------------------------------------------------------------------------
-- 0607_channel_orders.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0607: the restaurant Orders tab's channel cards (founder, 27 Oct 2026): today's delivery orders by where they came from, each source a
-- card (count, total, who), and its orders. Read only. Safe to run again.
--   * onelocal  - ordered in the OneLocal app (an ol_orders row, or channel 'online')
--   * swiggy / zomato - from the aggregators (channel)
--   * on_call  - a phone order taken at the counter for delivery (channel 'delivery', not from the app)
-- Dine-in and takeaway are not here (the Bill and the live board have them). Cancelled orders are only counted.
-- Each order gets one plain status: new · preparing · ready · on_way · delivered, from the app order's status when there is one,
-- else from the POS order: new/in billing = new, sent to kitchen = preparing, ready = ready, awaiting payment = on the way
-- (cash to collect), paid/delivered = delivered.

create or replace function public.rst_channel_orders(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(p->>'location_id', '')::uuid; v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.created_at, o.total, o.status as pos_status, o.external_ref, o.customer_phone,
             coalesce(nullif(o.customer_name, ''), 'Guest') as customer,
             case when x.id is not null or o.channel = 'online' then 'onelocal' when o.channel in ('swiggy', 'zomato') then o.channel
                  when o.channel = 'delivery' then 'on_call' end as source,
             case
               when o.status = 'cancelled' or x.status = 'cancelled' then 'cancelled'
               when x.id is not null then case x.status when 'placed' then 'new' when 'accepted' then 'preparing' when 'packed' then 'ready'
                                                        when 'out' then 'on_way' else 'delivered' end
               else case o.status when 'new' then 'new' when 'in_billing' then 'new' when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready'
                                  when 'awaiting_payment' then 'on_way' else 'delivered' end
             end as stage,
             (select string_agg(i.qty || ' × ' || i.name, ', ' order by i.created_at) from public.order_items i where i.order_id = o.id and i.status <> 'cancelled') as items
        from public.orders o
        left join public.ol_orders x on x.pos_order_id = o.id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc)
         and o.created_at >= v_since
         and (x.id is not null or o.channel in ('online', 'swiggy', 'zomato', 'delivery'))
    ), s(key, label, sort) as (values ('onelocal', 'OneLocal', 1), ('swiggy', 'Swiggy', 2), ('zomato', 'Zomato', 3), ('on_call', 'On call delivery', 4))
    select jsonb_build_object(
      'channels', (select jsonb_agg(jsonb_build_object(
          'key', s.key, 'label', s.label,
          'count', (select count(*) from o where o.source = s.key and o.stage <> 'cancelled'),
          'open', (select count(*) from o where o.source = s.key and o.stage not in ('cancelled', 'delivered')),
          'new', (select count(*) from o where o.source = s.key and o.stage = 'new'),
          'total', (select coalesce(sum(o.total), 0) from o where o.source = s.key and o.stage <> 'cancelled'),
          'names', (select coalesce(jsonb_agg(n.customer), '[]') from (select o.customer from o where o.source = s.key and o.stage <> 'cancelled' order by o.created_at desc limit 3) n)
        ) order by s.sort) from s),
      'cancelled', (select count(*) from o where o.stage = 'cancelled' and o.source is not null),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', o.id, 'display_no', o.display_no, 'placed_at', o.created_at, 'customer', o.customer, 'phone', o.customer_phone,
          'total', o.total, 'source', o.source, 'stage', o.stage, 'items', coalesce(o.items, ''),
          'ref', nullif(regexp_replace(coalesce(o.external_ref, ''), '^[a-z]+:', ''), '')
        ) order by case o.stage when 'new' then 0 when 'preparing' then 1 when 'ready' then 2 when 'on_way' then 3 else 4 end, o.created_at desc), '[]')
        from o where o.source is not null and o.stage <> 'cancelled')
    )
  );
end $$;

revoke all on function public.rst_channel_orders(jsonb) from public, anon;
grant execute on function public.rst_channel_orders(jsonb) to authenticated, service_role;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0608_home_insights.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0608: more on the restaurant Home (founder, 27 Oct 2026): what the day's data already says, in one read. Read only. Safe to run again.
--   * mix:      today's orders by how they were served (dine in, takeaway, delivery), with sales and the average bill
--   * payments: today's money by method (cash, card, UPI, …)
--   * top:      today's five best-selling dishes, by quantity, with what they brought in
--   * menu:     how the menu stands: dishes with few left to make (from 0605's "can be made"), out of stock, average food cost and the dishes
--               over 45% (the Recipe tab's own figure, mb_recipe_json), and dishes missing a recipe, photo or description
--   * ready:    dishes the kitchen has made that are waiting to be served
-- "Today" is the store's day (its time zone). Cancelled orders and lines are left out.

create or replace function public.rst_home_insights(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(nullif(p->>'location_id', ''), 'all')::uuid; v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.total, o.channel,
             case when o.channel = 'dine_in' then 'dine_in' when o.channel = 'pickup' then 'takeaway' else 'delivery' end as served
        from public.orders o
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc) and o.created_at >= v_since and o.status <> 'cancelled'
    ), li as (
      select i.menu_item_id, i.name, i.qty, i.unit_price from public.order_items i join o on o.id = i.order_id where i.status <> 'cancelled'
    ), dishes as materialized (
      select m.id, m.name, m.is_available, m.image_url, m.description,
             public.menu_can_make(v_org, m.id) as can_make,
             exists (select 1 from public.menu_item_recipes r where r.menu_item_id = m.id and r.organization_id = v_org) as has_recipe,
             (public.mb_recipe_json(v_org, m.id)->>'food_cost_pct')::numeric as food_pct
        from public.menu_items m where m.organization_id = v_org
    )
    select jsonb_build_object(
      'mix', jsonb_build_object(
        'orders', (select count(*) from o),
        'sales', (select coalesce(sum(total), 0) from o),
        'avg_bill', (select coalesce(round(avg(total), 2), 0) from o),
        'by', (select jsonb_agg(jsonb_build_object('key', k.key, 'label', k.label,
                  'orders', (select count(*) from o where o.served = k.key), 'sales', (select coalesce(sum(o.total), 0) from o where o.served = k.key)) order by k.sort)
               from (values ('dine_in', 'Dine in', 1), ('takeaway', 'Takeaway', 2), ('delivery', 'Delivery', 3)) k(key, label, sort))),
      'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', x.method, 'amount', x.amount, 'count', x.n) order by x.amount desc), '[]')
                     from (select pm.method, sum(pm.amount) as amount, count(*) as n from public.payments pm
                            where pm.organization_id = v_org and pm.created_at >= v_since and pm.amount > 0
                              and (v_loc is null or exists (select 1 from public.orders x where x.id = pm.order_id and x.location_id = v_loc))
                            group by pm.method) x),
      'top', (select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'qty', t.qty, 'sales', t.sales) order by t.qty desc, t.sales desc), '[]')
                from (select li.name, sum(li.qty) as qty, sum(li.qty * li.unit_price) as sales from li group by li.name order by 2 desc, 3 desc limit 5) t),
      'menu', jsonb_build_object(
        'dishes', (select count(*) from dishes),
        'low', (select coalesce(jsonb_agg(jsonb_build_object('name', d.name, 'can_make', d.can_make) order by d.can_make, d.name), '[]')
                  from (select * from dishes where can_make is not null and can_make < 10 order by can_make, name limit 5) d),
        'out', (select count(*) from dishes where not is_available or can_make = 0),
        'food_cost_avg', (select round(avg(food_pct), 1) from dishes where food_pct is not null),
        'high_cost', (select coalesce(jsonb_agg(jsonb_build_object('name', d.name, 'pct', round(d.food_pct, 1)) order by d.food_pct desc), '[]')
                        from (select * from dishes where food_pct > 45 order by food_pct desc limit 5) d),
        'no_recipe', (select count(*) from dishes where not has_recipe),
        'no_photo', (select count(*) from dishes where coalesce(btrim(image_url), '') = ''),
        'no_description', (select count(*) from dishes where coalesce(btrim(description), '') = '')),
      'ready', (select count(*) from public.order_items i join o on o.id = i.order_id where i.status = 'ready')
    )
  );
end $$;

revoke all on function public.rst_home_insights(jsonb) from public, anon;
grant execute on function public.rst_home_insights(jsonb) to authenticated, service_role;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0609_kot_orders.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0609: the KOT view (founder, 27 Oct 2026): today's orders that went to the kitchen, one card each: its status, total, table or source,
-- dishes and how many are ready, the captain and whether it is paid, every KOT in order (KOT 1 › KOT 2 › …) with its own progress, and the
-- stations with a tick when they are done. Read only. Safe to run again.
--   stage: new (nothing started) · preparing · ready (every dish ready or served, not paid) · completed (paid or delivered)
--   [status] filters: all, preparing (new + preparing), ready, completed.
-- A dish counts as ready when it is, or when its KOT is (the kitchen may close a whole ticket).
-- ready_item_ids are the dishes Serve hands over (tbl_mark_served); latest_ticket is the newest KOT (for Print).

create or replace function public.rst_kot_orders(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(nullif(p->>'location_id', ''), 'all')::uuid;
  v_st text := coalesce(nullif(p->>'status', ''), 'all'); v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_st not in ('all', 'preparing', 'ready', 'completed') then raise exception 'POS_BAD_REQUEST: unknown status'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.total, o.status, o.channel, o.created_at, o.paid_at, o.table_id, o.captain_name,
             t.label as table_label,
             (select count(*) from public.order_items i where i.order_id = o.id and i.status <> 'cancelled') as items,
             (select count(*) from public.order_items i where i.order_id = o.id and (i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered')))) as ready,
             (select count(*) from public.order_items i where i.order_id = o.id and i.status = 'pending' and i.started_at is null) as untouched
        from public.orders o left join public.dining_tables t on t.id = o.table_id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc) and o.created_at >= v_since and o.status <> 'cancelled'
         and exists (select 1 from public.kot_tickets k where k.order_id = o.id)
    ), s as (
      select o.*,
             case when o.paid_at is not null or o.status in ('paid', 'delivered') then 'completed'
                  when o.items > 0 and o.ready = o.items then 'ready'
                  when o.untouched = o.items then 'new' else 'preparing' end as stage
        from o
    )
    select jsonb_build_object(
      'counts', jsonb_build_object('all', (select count(*) from s), 'preparing', (select count(*) from s where stage in ('new', 'preparing')),
                                   'ready', (select count(*) from s where stage = 'ready'), 'completed', (select count(*) from s where stage = 'completed')),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', s.id, 'display_no', s.display_no, 'total', s.total, 'stage', s.stage, 'channel', s.channel, 'table_id', s.table_id, 'table_label', s.table_label,
          'captain', s.captain_name, 'paid', s.paid_at is not null, 'created_at', s.created_at,
          'minutes', floor(extract(epoch from (now() - s.created_at)) / 60)::int, 'items', s.items, 'ready', s.ready,
          'kots', (select jsonb_agg(jsonb_build_object('id', k.id, 'kot_no', k.kot_no, 'status', k.status,
                      'items', (select count(*) from public.order_items i where i.kot_ticket_id = k.id and i.status <> 'cancelled'),
                      'ready', (select count(*) from public.order_items i where i.kot_ticket_id = k.id and (i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered'))))) order by k.kot_no)
                   from public.kot_tickets k where k.order_id = s.id),
          'stations', (select coalesce(jsonb_agg(jsonb_build_object('name', public.tbl_station_label(v_org, x.station), 'done', x.done) order by x.station), '[]')
                         from (select i.station, bool_and((i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered')))) as done from public.order_items i
                                where i.order_id = s.id and i.status <> 'cancelled' group by i.station) x),
          'ready_item_ids', (select coalesce(jsonb_agg(i.id), '[]') from public.order_items i where i.order_id = s.id and i.status = 'ready'),
          'latest_ticket', (select k.id from public.kot_tickets k where k.order_id = s.id order by k.kot_no desc limit 1)
        ) order by case s.stage when 'ready' then 0 when 'preparing' then 1 when 'new' then 2 else 3 end, s.created_at desc), '[]')
        from s where v_st = 'all' or (v_st = 'preparing' and s.stage in ('new', 'preparing')) or s.stage = v_st)
    )
  );
end $$;

revoke all on function public.rst_kot_orders(jsonb) from public, anon;
grant execute on function public.rst_kot_orders(jsonb) to authenticated, service_role;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0610_accept_orders.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0610: accept delivery orders within a minute, and auto-accept (founder, 28 Oct 2026). Safe to run again.
--   * ol_merchant_channels.auto_accept (default off): when on, the Orders screen accepts each new order as it arrives.
--     The accept window is the existing accept_window_seconds (60 by default).
--   * rst_channel_accept({order_id}): accepts one new delivery order. A held POS order is sent to the kitchen (tbl_kot_fire, its KOT);
--     a OneLocal app order is also marked accepted (the customer's order moves on through the status gate). Safe to repeat.
--   * rst_auto_accept_set({on}): turns auto-accept on or off (a manager or owner).
--   * rst_channel_orders (0607) also answers accept_window and auto_accept.


alter table public.ol_merchant_channels add column if not exists auto_accept boolean not null default false;

create or replace function public.rst_channel_accept(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); o public.orders%rowtype; x public.ol_orders%rowtype; v_kot jsonb; v_done boolean := false;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  select * into o from public.orders where id = nullif(p->>'order_id', '')::uuid and organization_id = v_org for update;
  if not found or not public.location_is_allowed(o.organization_id, o.location_id) then raise exception 'POS_NOT_FOUND: order not found'; end if;
  if not public.has_permission(v_org, 'order', 'update_status', o.location_id) then raise exception 'POS_FORBIDDEN: your role cannot accept orders'; end if;
  if o.status = 'cancelled' then raise exception 'POS_WRONG_STATE: this order was cancelled'; end if;
  select * into x from public.ol_orders where pos_order_id = o.id for update;
  -- the kitchen gets it (a held order has no KOT yet)
  if o.status in ('new', 'in_billing') then
    v_kot := public.tbl_kot_fire(o.id);
    v_done := true;
  end if;
  -- a OneLocal app order: the customer's order is accepted too
  if x.id is not null and x.status = 'placed' then
    perform public.status_gate('ol_orders', x.id, 'restaurant_accept');
    update public.ol_orders set status = 'accepted', prep_minutes = coalesce(x.prep_minutes, 20), eta_minutes = coalesce(x.prep_minutes, 20) + 15 where id = x.id;
    v_done := true;
  end if;
  if v_done then
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, o.id, 'accepted', o.display_no || ' accepted' || case when coalesce((p->>'auto')::boolean, false) then ' automatically' else '' end, 'pos',
            jsonb_build_object('by', auth.uid(), 'auto', coalesce((p->>'auto')::boolean, false)));
  end if;
  return jsonb_build_object('order_id', o.id, 'accepted', true, 'already', not v_done, 'kot', v_kot);
end $$;

create or replace function public.rst_auto_accept_set(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_on boolean;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if not public.has_org_role(array['org_owner', 'org_admin', 'manager', 'business_manager', 'location_manager']) then
    raise exception 'POS_FORBIDDEN: only a manager can change auto-accept'; end if;
  begin v_on := (p->>'on')::boolean; exception when others then v_on := null; end;
  if v_on is null then raise exception 'POS_BAD_REQUEST: on is true or false'; end if;
  insert into public.ol_merchant_channels (organization_id, auto_accept, updated_by, updated_at) values (v_org, v_on, auth.uid(), now())
  on conflict (organization_id) do update set auto_accept = excluded.auto_accept, updated_by = excluded.updated_by, updated_at = now();
  return jsonb_build_object('auto_accept', v_on);
end $$;

revoke all on function public.rst_channel_accept(jsonb) from public, anon;
grant execute on function public.rst_channel_accept(jsonb) to authenticated, service_role;
revoke all on function public.rst_auto_accept_set(jsonb) from public, anon;
grant execute on function public.rst_auto_accept_set(jsonb) to authenticated, service_role;

create or replace function public.rst_channel_orders(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(p->>'location_id', '')::uuid; v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.created_at, o.total, o.status as pos_status, o.external_ref, o.customer_phone,
             coalesce(nullif(o.customer_name, ''), 'Guest') as customer,
             case when x.id is not null or o.channel = 'online' then 'onelocal' when o.channel in ('swiggy', 'zomato') then o.channel
                  when o.channel = 'delivery' then 'on_call' end as source,
             case
               when o.status = 'cancelled' or x.status = 'cancelled' then 'cancelled'
               when x.id is not null then case x.status when 'placed' then 'new' when 'accepted' then 'preparing' when 'packed' then 'ready'
                                                        when 'out' then 'on_way' else 'delivered' end
               else case o.status when 'new' then 'new' when 'in_billing' then 'new' when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready'
                                  when 'awaiting_payment' then 'on_way' else 'delivered' end
             end as stage,
             (select string_agg(i.qty || ' × ' || i.name, ', ' order by i.created_at) from public.order_items i where i.order_id = o.id and i.status <> 'cancelled') as items
        from public.orders o
        left join public.ol_orders x on x.pos_order_id = o.id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc)
         and o.created_at >= v_since
         and (x.id is not null or o.channel in ('online', 'swiggy', 'zomato', 'delivery'))
    ), s(key, label, sort) as (values ('onelocal', 'OneLocal', 1), ('swiggy', 'Swiggy', 2), ('zomato', 'Zomato', 3), ('on_call', 'On call delivery', 4))
    select jsonb_build_object(
      'channels', (select jsonb_agg(jsonb_build_object(
          'key', s.key, 'label', s.label,
          'count', (select count(*) from o where o.source = s.key and o.stage <> 'cancelled'),
          'open', (select count(*) from o where o.source = s.key and o.stage not in ('cancelled', 'delivered')),
          'new', (select count(*) from o where o.source = s.key and o.stage = 'new'),
          'total', (select coalesce(sum(o.total), 0) from o where o.source = s.key and o.stage <> 'cancelled'),
          'names', (select coalesce(jsonb_agg(n.customer), '[]') from (select o.customer from o where o.source = s.key and o.stage <> 'cancelled' order by o.created_at desc limit 3) n)
        ) order by s.sort) from s),
      'accept_window', coalesce((select c.accept_window_seconds from public.ol_merchant_channels c where c.organization_id = v_org), 60),
      'auto_accept', coalesce((select c.auto_accept from public.ol_merchant_channels c where c.organization_id = v_org), false),
      'cancelled', (select count(*) from o where o.stage = 'cancelled' and o.source is not null),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', o.id, 'display_no', o.display_no, 'placed_at', o.created_at, 'customer', o.customer, 'phone', o.customer_phone,
          'total', o.total, 'source', o.source, 'stage', o.stage, 'items', coalesce(o.items, ''),
          'ref', nullif(regexp_replace(coalesce(o.external_ref, ''), '^[a-z]+:', ''), '')
        ) order by case o.stage when 'new' then 0 when 'preparing' then 1 when 'ready' then 2 when 'on_way' then 3 else 4 end, o.created_at desc), '[]')
        from o where o.source is not null and o.stage <> 'cancelled')
    )
  );
end $$;


-- ----------------------------------------------------------------------------------------------------------------------------
-- 0611_dish_sizes.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0611: sizes for dishes (founder, 28 Oct 2026): Small, Medium and Large for the beverages, each with its own price, shown on the menu and
-- carried through every order. Sizes live in menu_item_variants (name, price, is_default, sort_order), which the menu already counted.
--   * pos_place_order / tbl_order_add: a line may carry "variant_id"; the line is priced at that size and keeps its name (order_items.variant_name).
--     A size that is not the dish's is refused. Without a size, a dish is priced as before.
--   * pos_sell_catalog (the Bill's menu): each dish answers its sizes.
--   * rst_menu (the Menu tab): each dish answers its sizes with prices.
--   * pos_order_view, pos_order_json, rst_channel_orders: a dish reads "Americano (Large)".
-- The kitchen card, the table's order and the bill already show the size (they read variant_name). The functions below are the live
-- definitions with only those changes. Safe to run again.


CREATE OR REPLACE FUNCTION public.pos_place_order(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_org uuid := (p->>'organization_id')::uuid; v_key text := nullif(p->>'idempotency_key','');
  v_channel text := p->>'service_type'; v_placed_by text := coalesce(nullif(p->>'placed_by',''),'pos');
  v_qty int; v_line jsonb; v_item public.menu_items%rowtype; v_sub numeric(10,2) := 0; v_n int := 0;
  v_cfg public.org_bill_settings%rowtype; v_gst_pct numeric; v_gst numeric(10,2); v_sc numeric(10,2) := 0; v_waived numeric(10,2) := 0;
  v_raw numeric(10,2); v_total numeric(10,2); v_round numeric(10,2) := 0; v_disc numeric(10,2) := 0;
  v_table public.dining_tables%rowtype; v_loc uuid; v_no bigint; v_display text; v_id uuid; v_status text; v_kot uuid; v_ex uuid;
  v_waive boolean := coalesce((p->>'waive_service_charge')::boolean, false);
  v_code text; v_cp public.sell_coupons%rowtype; v_ckey text;
begin
  if auth.uid() is null or v_org is null or v_org is distinct from public.current_org_id() then raise exception 'POS_FORBIDDEN: not your organization'; end if;
  if not public.has_org_role(array['org_owner','org_admin','manager','biller','captain','business_manager','location_manager','operations_manager']) then
    raise exception 'POS_FORBIDDEN: your role cannot place orders'; end if;
  if v_channel not in ('dine_in','pickup','delivery') then raise exception 'POS_BAD_REQUEST: unknown service type'; end if;
  if v_placed_by not in ('pos','captain','guest','integration') then raise exception 'POS_BAD_REQUEST: unknown placed_by'; end if;
  if v_key is not null then
    select id into v_ex from public.orders where organization_id = v_org and idempotency_key = v_key;
    if found then return public.pos_order_json(v_ex) || jsonb_build_object('replayed', true); end if;
  end if;
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') not between 1 and 50 then raise exception 'POS_EMPTY: add between 1 and 50 lines'; end if;
  v_code := upper(nullif(btrim(coalesce(p->>'coupon_code', '')), ''));

  if nullif(p->>'table_id','') is not null then
    select * into v_table from public.dining_tables where id = (p->>'table_id')::uuid and organization_id = v_org and is_active;
    if not found then raise exception 'POS_BAD_TABLE: table not found'; end if;
    v_loc := v_table.location_id;
  elsif v_channel = 'dine_in' then raise exception 'POS_BAD_TABLE: choose a table for a dine-in order'; end if;
  if v_loc is null then select id into v_loc from public.locations where organization_id = v_org order by (code = 'MAIN') desc, created_at limit 1; end if;

  select * into v_cfg from public.org_bill_settings where organization_id = v_org;
  if not found then v_cfg.sgst_pct := 2.5; v_cfg.cgst_pct := 2.5; v_cfg.service_charge_pct := 0; v_cfg.round_off_enabled := true; end if;

  for v_line in select * from jsonb_array_elements(p->'lines') loop
    v_qty := (v_line->>'qty')::int;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'POS_BAD_QTY: quantities must be 1 to 99'; end if;
    select * into v_item from public.menu_items where id = (v_line->>'menu_item_id')::uuid and organization_id = v_org;
    if not found or not v_item.is_available then raise exception 'POS_ITEM_UNAVAILABLE: % is not available', coalesce(v_item.name,'an item'); end if;
    if nullif(v_line->>'variant_id', '') is not null and not exists (select 1 from public.menu_item_variants mv where mv.id = (v_line->>'variant_id')::uuid and mv.menu_item_id = v_item.id) then
      raise exception 'POS_BAD_VARIANT: choose a size of %', v_item.name; end if;
    v_sub := v_sub + coalesce((select mv.price from public.menu_item_variants mv where mv.id = nullif(v_line->>'variant_id', '')::uuid and mv.menu_item_id = v_item.id), v_item.price) * v_qty; v_n := v_n + v_qty;
  end loop;

  -- 0380: a coupon code takes money off the bill. The rules live in sell_coupons; the discount is worked out here, never by the app.
  if v_code is not null then
    select * into v_cp from public.sell_coupons where organization_id = v_org and upper(code) = v_code and active
      and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now()) for update;
    if not found then raise exception 'POS_COUPON_UNKNOWN: this coupon code is not valid'; end if;
    if v_sub < v_cp.min_order then raise exception 'POS_COUPON_MIN: this coupon needs a bill of at least %', v_cp.min_order; end if;
    v_disc := case v_cp.kind when 'percent' then round(v_sub * v_cp.value / 100, 2) else v_cp.value end;
    if v_cp.max_discount is not null then v_disc := least(v_disc, v_cp.max_discount); end if;
    v_disc := least(v_disc, v_sub);
    -- use limits, counted under the coupon row's lock (the select above), so two tills cannot both take the last use
    v_ckey := nullif(right(regexp_replace(coalesce(p->>'customer_phone', ''), '\D', '', 'g'), 10), '');   -- the last 10 digits, so +91 and 0 prefixes do not make a second customer
    if v_cp.max_uses is not null and (select count(*) from public.sell_coupon_redemptions where coupon_id = v_cp.id and released_at is null) >= v_cp.max_uses then
      raise exception 'POS_COUPON_LIMIT: this coupon has been used up'; end if;
    if v_cp.max_uses_per_customer is not null then
      if v_ckey is null then raise exception 'POS_COUPON_CUSTOMER: this coupon is limited per customer; enter the customer''s mobile number'; end if;
      if (select count(*) from public.sell_coupon_redemptions where coupon_id = v_cp.id and customer_key = v_ckey and released_at is null) >= v_cp.max_uses_per_customer then
        raise exception 'POS_COUPON_LIMIT: this customer has already used this coupon'; end if;
    end if;
    update public.sell_coupons set used_count = used_count + 1, updated_at = now() where id = v_cp.id;
  end if;

  -- 0371: a shop that is not GST-registered charges no GST; when menu prices already include GST, the tax is taken out of them, not added on top
  v_gst_pct := case when v_cfg.gst_registered is false then 0 else v_cfg.sgst_pct + v_cfg.cgst_pct end;
  if coalesce(v_cfg.prices_include_tax, false) and v_gst_pct > 0 then
    v_gst := round((v_sub - v_disc) * v_gst_pct / (100 + v_gst_pct), 2);
    v_sub := v_sub - v_gst;   -- subtotal is stored before tax, so subtotal + GST still equals what the menu showed
  else
    v_gst := round((v_sub - v_disc) * v_gst_pct / 100, 2);
  end if;
  v_sc := round((v_sub - v_disc) * v_cfg.service_charge_pct / 100, 2);
  if v_waive then
    if not public.has_org_role(array['org_owner','org_admin','manager','business_manager','location_manager']) then raise exception 'POS_FORBIDDEN: only a manager can remove the service charge'; end if;
    if coalesce(btrim(p->>'waive_reason'),'') = '' then raise exception 'POS_BAD_REQUEST: a reason is needed to remove the service charge'; end if;
    v_waived := v_sc; v_sc := 0;
  end if;
  v_raw := v_sub - v_disc + v_gst + v_sc;
  v_total := case when v_cfg.round_off_enabled then round(v_raw) else v_raw end; v_round := v_total - v_raw;

  -- a coupon that makes the bill free is refused: a bill with nothing to pay cannot be completed at the counter
  if v_code is not null and v_total <= 0 then raise exception 'POS_COUPON_ZERO: this coupon would make the bill free; use a smaller discount'; end if;

  v_no := public.next_org_seq(v_org, 'order'); v_display := 'P-' || lpad(v_no::text, 5, '0');
  v_status := case when coalesce((p->>'fire_kot')::boolean, true) then 'sent_to_kitchen' else 'in_billing' end;
  insert into public.orders (organization_id, location_id, order_no, display_no, channel, status, table_id, customer_name, customer_phone, captain_name,
      subtotal, discount, gst_pct, gst_amount, service_charge, round_off, total, placed_by, guest_count, notes, idempotency_key,
      service_charge_waived, service_charge_waived_amount, waive_reason, created_by, coupon_code)
  values (v_org, v_loc, v_no, v_display, v_channel, v_status, v_table.id, nullif(p->>'customer_name',''), nullif(p->>'customer_phone',''), null,
      v_sub, v_disc, v_gst_pct, v_gst, v_sc, v_round, v_total, v_placed_by, coalesce(nullif(p->>'guest_count','')::int, 1), nullif(p->>'notes',''), v_key,
      v_waive, v_waived, case when v_waive then p->>'waive_reason' end, auth.uid(), case when v_disc > 0 then v_cp.code end)
  returning id into v_id;
  if v_code is not null and v_disc > 0 then
    insert into public.sell_coupon_redemptions (organization_id, coupon_id, order_id, customer_key) values (v_org, v_cp.id, v_id, v_ckey);
  end if;
  insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, notes, station, course, variant_name)
  select v_id, mi.id, mi.name, (l->>'qty')::int, coalesce(mv.price, mi.price), nullif(l->>'notes',''), coalesce(mi.station,'main'), coalesce(mi.course,'eat'), mv.name
  from jsonb_array_elements(p->'lines') l join public.menu_items mi on mi.id = (l->>'menu_item_id')::uuid
  left join public.menu_item_variants mv on mv.id = nullif(l->>'variant_id', '')::uuid and mv.menu_item_id = mi.id;
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta) values
    (v_org, v_id, 'placed', 'Order ' || v_display || ' placed - ' || v_n || ' items', v_placed_by, jsonb_build_object('by', auth.uid()));
  if v_status = 'sent_to_kitchen' then
    insert into public.kot_tickets (organization_id, order_id, kot_no, station, status) values (v_org, v_id, public.next_org_seq(v_org,'kot'), 'main', 'new') returning id into v_kot;
    update public.order_items set kot_ticket_id = v_kot where order_id = v_id;
    insert into public.order_events (organization_id, order_id, kind, message, actor) values (v_org, v_id, 'kot_fired', 'KOT fired for ' || v_display, v_placed_by);
  end if;
  if v_waive then insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, v_id, 'service_charge_waived', 'Service charge removed: ' || (p->>'waive_reason'), v_placed_by, jsonb_build_object('amount', v_waived, 'by', auth.uid())); end if;
  return public.pos_order_json(v_id) || jsonb_build_object('replayed', false);
end $function$

;

CREATE OR REPLACE FUNCTION public.tbl_order_add(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_loc uuid := public.tbl_guard(p, 'order'); v_org uuid := public.current_org_id(); t public.dining_tables%rowtype;
  v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), ''); v_hash text; v_prev jsonb; v_send boolean; v_line jsonb; v_qty int;
  v_item public.menu_items%rowtype; o public.orders%rowtype; v_oid uuid; v_kot jsonb; v_res jsonb; v_n int := 0; v_new boolean := false;
begin
  if v_key is null then raise exception 'TBL_BAD_REQUEST: an Idempotency-Key is needed so a retry never adds the dishes twice'; end if;
  begin v_send := coalesce((p->>'send')::boolean, true); exception when others then raise exception 'TBL_BAD_REQUEST: send is true or false'; end;
  v_hash := md5((p - 'idempotency_key')::text);
  v_prev := public.tbl_req_replay(v_org, v_key, 'add', v_hash);
  if v_prev is not null then return v_prev; end if;
  t := public.tbl_get(v_org, v_loc, nullif(p->>'table_id', '')::uuid);
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') not between 1 and 50 then raise exception 'TBL_BAD_REQUEST: add between 1 and 50 dishes'; end if;
  for v_line in select * from jsonb_array_elements(p->'lines') loop
    begin v_qty := (v_line->>'qty')::int; exception when others then v_qty := null; end;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'TBL_BAD_REQUEST: quantities are 1 to 99'; end if;
    if char_length(coalesce(v_line->>'notes', '')) > 200 then raise exception 'TBL_BAD_REQUEST: a note is at most 200 characters'; end if;
    select * into v_item from public.menu_items where id = nullif(v_line->>'menu_item_id', '')::uuid and organization_id = v_org;
    if not found or not v_item.is_available then raise exception 'TBL_ITEM_UNAVAILABLE: % is not available', coalesce(v_item.name, 'a dish'); end if;
    if nullif(v_line->>'variant_id', '') is not null and not exists (select 1 from public.menu_item_variants mv where mv.id = (v_line->>'variant_id')::uuid and mv.menu_item_id = v_item.id) then
      raise exception 'TBL_BAD_REQUEST: choose a size of %', v_item.name; end if;
    v_n := v_n + 1;
  end loop;

  -- the table's open order (joined tables share one); locked so two phones adding at once queue up
  select o2.* into o from public.orders o2 where o2.organization_id = v_org and o2.table_id = any(public.tbl_group(v_org, t.id))
     and public.tbl_order_open(o2.status, o2.paid_at) order by o2.created_at desc limit 1 for update;
  if not found then
    v_res := public.pos_place_order(jsonb_build_object('organization_id', v_org, 'service_type', 'dine_in', 'table_id', t.id, 'placed_by', 'pos', 'fire_kot', false,
      'guest_count', nullif(p->>'guest_count', ''), 'lines', p->'lines'));
    v_oid := (v_res->>'id')::uuid; v_new := true;
    select * into o from public.orders where id = v_oid for update;
  else
    if o.status not in ('new', 'in_billing', 'sent_to_kitchen', 'ready') then
      raise exception 'TBL_WRONG_STATE: the bill for this table is already %; start a new order after it is settled', replace(o.status, '_', ' '); end if;
    v_oid := o.id;
    insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, notes, station, course, variant_name)
    select o.id, mi.id, mi.name, (l->>'qty')::int, coalesce(mv.price, mi.price), nullif(btrim(coalesce(l->>'notes', '')), ''), coalesce(mi.station, 'main'), coalesce(mi.course, 'eat'), mv.name
      from jsonb_array_elements(p->'lines') l join public.menu_items mi on mi.id = (l->>'menu_item_id')::uuid and mi.organization_id = v_org
      left join public.menu_item_variants mv on mv.id = nullif(l->>'variant_id', '')::uuid and mv.menu_item_id = mi.id;
    perform public.tbl_order_reprice(o.id);
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, o.id, 'items_added', v_n || ' dishes added to ' || o.display_no, 'pos', jsonb_build_object('by', auth.uid(), 'held', not v_send));
  end if;
  -- takeaway lines (0606): mark one of the rows this call added for each line sent with "takeaway": true
  for v_line in select * from jsonb_array_elements(p->'lines') loop
    continue when not coalesce((v_line->>'takeaway')::boolean, false);
    update public.order_items set is_takeaway = true
     where id = (select x.id from public.order_items x where x.order_id = v_oid and x.menu_item_id = (v_line->>'menu_item_id')::uuid
                    and x.qty = (v_line->>'qty')::int and x.created_at = now() and not x.is_takeaway and x.kot_ticket_id is null
                  order by x.id limit 1);
  end loop;
  if v_send then v_kot := public.tbl_kot_fire(v_oid); end if;
  v_res := jsonb_build_object('order_id', v_oid, 'new_order', v_new, 'held', not v_send, 'dishes_added', v_n, 'kot', v_kot,
    'order', (select jsonb_build_object('display_no', x.display_no, 'status', x.status, 'subtotal', x.subtotal, 'total', x.total) from public.orders x where x.id = v_oid),
    'table', jsonb_build_object('id', t.id, 'label', t.label));
  insert into public.table_order_requests (organization_id, idempotency_key, kind, request_hash, order_id, result, created_by)
  values (v_org, v_key, 'add', v_hash, v_oid, v_res, auth.uid());
  return v_res || jsonb_build_object('replayed', false);
end $function$

;

CREATE OR REPLACE FUNCTION public.pos_sell_catalog(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_q text := nullif(btrim(coalesce(p->>'q', '')), ''); v_cat text := nullif(btrim(coalesce(p->>'category', '')), '');
  v_av boolean; v_sort text := coalesce(nullif(p->>'sort', ''), 'name'); v_like text;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_sort not in ('name', 'price_asc', 'price_desc') then raise exception 'POS_BAD_REQUEST: unknown sort'; end if;
  begin v_av := coalesce((p->>'available')::boolean, false); exception when others then raise exception 'POS_BAD_REQUEST: available is true or false'; end;
  v_like := '%' || regexp_replace(coalesce(v_q, ''), '([%_\\])', '\\\1', 'g') || '%';
  return jsonb_build_object(
    'items', (select coalesce(jsonb_agg(j order by o1, o2 desc, o3), '[]'::jsonb) from (
        select jsonb_build_object('id', i.id, 'name', i.name, 'sku', coalesce(i.sku, ''), 'price', i.price, 'image_url', i.image_url, 'available', i.is_available,
                 'category', coalesce(c.name, ''), 'food_type', coalesce(i.food_type, 'veg'),
                 'has_recipe', exists (select 1 from public.menu_item_recipes mr where mr.menu_item_id = i.id and mr.organization_id = v_org),
                 'can_make', public.menu_can_make(v_org, i.id),
                 'variants', (select coalesce(jsonb_agg(jsonb_build_object('id', mv.id, 'name', mv.name, 'price', mv.price, 'is_default', mv.is_default) order by mv.sort_order, mv.price), '[]'::jsonb)
                                from public.menu_item_variants mv where mv.menu_item_id = i.id)) as j,
               case when v_sort = 'price_asc' then i.price end as o1, case when v_sort = 'price_desc' then i.price end as o2, i.name as o3
        from public.menu_items i left join public.menu_categories c on c.id = i.category_id
        where i.organization_id = v_org and (not v_av or i.is_available)
          and (v_q is null or i.name ilike v_like or coalesce(i.sku, '') ilike v_like)
          and (v_cat is null or lower(coalesce(c.name, '')) = lower(v_cat))
        order by o1 asc, o2 desc, o3 limit 200) s),
    'categories', (select coalesce(jsonb_agg(n order by n), '[]'::jsonb) from (
        select distinct c.name as n from public.menu_items i join public.menu_categories c on c.id = i.category_id where i.organization_id = v_org) k));
end $function$

;

CREATE OR REPLACE FUNCTION public.rst_menu(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_loc uuid; v_tz text; v_q text := nullif(btrim(coalesce(p->>'q', '')), '');
  v_filter text := coalesce(nullif(p->>'filter', ''), 'all'); v_out jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_filter not in ('all', 'in_stock', 'out_of_stock', 'needs_image') then raise exception 'POS_BAD_REQUEST: unknown filter'; end if;
  if v_q is not null and char_length(v_q) > 60 then raise exception 'POS_BAD_REQUEST: search text is too long'; end if;
  v_loc := public.rst_menu_outlet(v_org, p);
  v_tz := public.menu_outlet_tz(v_org, v_loc);
  with base as (
    select m.*, c.name as cat_name, c.sort_order as cat_sort,
           coalesce(m.price_minor, round(m.price * 100)::bigint) as pminor,
           (select count(*) from public.menu_item_variants v where v.menu_item_id = m.id) as n_variants,
           exists (select 1 from public.menu_item_availability a where a.menu_item_id = m.id) as has_windows
      from public.menu_items m left join public.menu_categories c on c.id = m.category_id
     where m.organization_id = v_org),
  shown as (
    select * from base b
     where (v_q is null or b.name ilike '%' || v_q || '%' or coalesce(b.description, '') ilike '%' || v_q || '%')
       and case v_filter when 'all' then true when 'in_stock' then b.is_available when 'out_of_stock' then not b.is_available
                         else nullif(btrim(coalesce(b.image_url, '')), '') is null end),
  cats as (
    select b.category_id, coalesce(b.cat_name, 'Other') as name, min(coalesce(b.cat_sort, 2147483647)) as srt, count(*) as n,
           count(*) filter (where b.is_available) as n_in
      from base b group by b.category_id, coalesce(b.cat_name, 'Other'))
  select jsonb_build_object(
    'business', (select o.name from public.organizations o where o.id = v_org),
    'location', jsonb_build_object('id', v_loc, 'name', (select l.name from public.locations l where l.id = v_loc)),
    'outlets', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by (l.code = 'MAIN') desc, l.created_at), '[]'::jsonb)
                  from public.locations l where l.organization_id = v_org and l.status = 'active' and public.location_is_allowed(v_org, l.id)),
    'can_edit', public.has_permission(v_org, 'menu', 'update'),
    'counts', (select jsonb_build_object('total', count(*), 'in_stock', count(*) filter (where is_available),
                 'out_of_stock', count(*) filter (where not is_available),
                 'needs_image', count(*) filter (where nullif(btrim(coalesce(image_url, '')), '') is null),
                 'with_image', count(*) filter (where nullif(btrim(coalesce(image_url, '')), '') is not null),
                 'missing_description', count(*) filter (where nullif(btrim(coalesce(description, '')), '') is null)) from base),
    'filter', v_filter,
    'categories', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.category_id, 'name', c.name, 'count', c.n, 'in_stock', c.n_in, 'all_in_stock', c.n_in = c.n,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', s.id, 'name', s.name, 'price_minor', s.pminor, 'description', s.description, 'food_type', s.food_type, 'course', s.course,
                    'image_url', s.image_url, 'in_stock', s.is_available, 'variants', s.n_variants, 'sizes', (select coalesce(jsonb_agg(jsonb_build_object('name', mv.name, 'price', mv.price) order by mv.sort_order, mv.price), '[]'::jsonb) from public.menu_item_variants mv where mv.menu_item_id = s.id), 'has_windows', s.has_windows,
                    'orderable_now', public.menu_item_orderable_at(s.id, now(), v_tz)) order by s.sort_order, lower(s.name), s.id), '[]'::jsonb)
                    from shown s where s.category_id is not distinct from c.category_id))
        order by c.srt, lower(c.name)), '[]'::jsonb)
      from cats c where exists (select 1 from shown s where s.category_id is not distinct from c.category_id))
  ) into v_out;
  return v_out;
end $function$

;

CREATE OR REPLACE FUNCTION public.pos_order_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_o public.orders%rowtype; v_res jsonb;
begin
  select * into v_o from public.orders where id = nullif(p->>'order_id', '')::uuid;
  if not found or auth.uid() is null or v_o.organization_id is distinct from public.current_org_id()
     or not public.location_is_allowed(v_o.organization_id, v_o.location_id) then raise exception 'POS_NOT_FOUND: order not found'; end if;
  select jsonb_build_object(
    'order', to_jsonb(v_o) - 'external_ref' - 'idempotency_key' - 'created_by',
    'table_label', (select t.label from public.dining_tables t where t.id = v_o.table_id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('order_item_id', i.id, 'menu_item_id', i.menu_item_id, 'name', i.name || coalesce(' (' || i.variant_name || ')', ''), 'takeaway', i.is_takeaway, 'qty', i.qty,
                'unit_price', i.unit_price, 'status', i.status, 'picked_qty', l.picked_qty, 'missing_qty', l.missing_qty) order by i.created_at, i.id), '[]'::jsonb)
              from public.order_items i left join public.pos_fulfilment_lines l on l.order_item_id = i.id where i.order_id = v_o.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', y.method, 'amount', y.amount, 'tendered', c.tendered, 'created_at', y.created_at) order by y.created_at), '[]'::jsonb)
                 from public.payments y left join public.pos_cash_tenders c on c.payment_id = y.id where y.order_id = v_o.id),
    'paid', (select coalesce(sum(amount), 0) from public.payments where order_id = v_o.id),
    'fulfilment', (select to_jsonb(f) - 'organization_id' from public.pos_fulfilments f where f.order_id = v_o.id),
    'next_events', (select coalesce(jsonb_agg(t.event order by t.event), '[]'::jsonb) from public.order_transitions t join public.pos_fulfilments f on f.order_id = v_o.id
                    where t.entity = 'pos_fulfilments' and t.from_status = f.stage and t.event <> 'cancel'),
    'online', (select jsonb_build_object('id', x.id, 'status', x.status, 'payment_method', x.payment_method, 'payment_status', x.payment_status,
                 'address', x.delivery_address, 'cancel_reason', x.cancel_reason, 'rider_name', x.rider_name, 'eta_minutes', x.eta_minutes)
               from public.ol_orders x where x.pos_order_id = v_o.id limit 1),
    'refunded', (select coalesce(sum(r.amount), 0) from public.ol_refunds r join public.ol_orders x on x.id = r.order_id where x.pos_order_id = v_o.id and r.status = 'processed'),
    'cancel_reason', (select e.meta->>'reason' from public.order_events e where e.order_id = v_o.id and e.kind = 'status_cancelled' order by e.created_at desc limit 1),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('kind', e.kind, 'message', e.message, 'at', e.created_at) order by e.created_at), '[]'::jsonb)
               from public.order_events e where e.order_id = v_o.id)
  ) into v_res;
  return v_res;
end $function$

;

CREATE OR REPLACE FUNCTION public.pos_order_json(p_order uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select to_jsonb(o) - 'external_ref' - 'idempotency_key'
    || jsonb_build_object(
      'table', (select jsonb_build_object('id', t.id, 'label', t.label, 'seats', t.seats) from public.dining_tables t where t.id = o.table_id),
      'order_items', (select coalesce(jsonb_agg(jsonb_build_object('menu_item_id', i.menu_item_id, 'name', i.name || coalesce(' (' || i.variant_name || ')', ''), 'qty', i.qty,
                       'unit_price', i.unit_price, 'notes', i.notes, 'status', i.status) order by i.created_at), '[]'::jsonb) from public.order_items i where i.order_id = o.id),
      'payments', (select coalesce(jsonb_agg(jsonb_build_object('amount', p.amount, 'method', p.method)), '[]'::jsonb) from public.payments p where p.order_id = o.id),
      'paid', (select coalesce(sum(p.amount), 0) from public.payments p where p.order_id = o.id))
  from public.orders o where o.id = p_order;
$function$

;

CREATE OR REPLACE FUNCTION public.rst_channel_orders(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(p->>'location_id', '')::uuid; v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.created_at, o.total, o.status as pos_status, o.external_ref, o.customer_phone,
             coalesce(nullif(o.customer_name, ''), 'Guest') as customer,
             case when x.id is not null or o.channel = 'online' then 'onelocal' when o.channel in ('swiggy', 'zomato') then o.channel
                  when o.channel = 'delivery' then 'on_call' end as source,
             case
               when o.status = 'cancelled' or x.status = 'cancelled' then 'cancelled'
               when x.id is not null then case x.status when 'placed' then 'new' when 'accepted' then 'preparing' when 'packed' then 'ready'
                                                        when 'out' then 'on_way' else 'delivered' end
               else case o.status when 'new' then 'new' when 'in_billing' then 'new' when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready'
                                  when 'awaiting_payment' then 'on_way' else 'delivered' end
             end as stage,
             (select string_agg(i.qty || ' × ' || i.name || coalesce(' (' || i.variant_name || ')', ''), ', ' order by i.created_at) from public.order_items i where i.order_id = o.id and i.status <> 'cancelled') as items
        from public.orders o
        left join public.ol_orders x on x.pos_order_id = o.id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc)
         and o.created_at >= v_since
         and (x.id is not null or o.channel in ('online', 'swiggy', 'zomato', 'delivery'))
    ), s(key, label, sort) as (values ('onelocal', 'OneLocal', 1), ('swiggy', 'Swiggy', 2), ('zomato', 'Zomato', 3), ('on_call', 'On call delivery', 4))
    select jsonb_build_object(
      'channels', (select jsonb_agg(jsonb_build_object(
          'key', s.key, 'label', s.label,
          'count', (select count(*) from o where o.source = s.key and o.stage <> 'cancelled'),
          'open', (select count(*) from o where o.source = s.key and o.stage not in ('cancelled', 'delivered')),
          'new', (select count(*) from o where o.source = s.key and o.stage = 'new'),
          'total', (select coalesce(sum(o.total), 0) from o where o.source = s.key and o.stage <> 'cancelled'),
          'names', (select coalesce(jsonb_agg(n.customer), '[]') from (select o.customer from o where o.source = s.key and o.stage <> 'cancelled' order by o.created_at desc limit 3) n)
        ) order by s.sort) from s),
      'accept_window', coalesce((select c.accept_window_seconds from public.ol_merchant_channels c where c.organization_id = v_org), 60),
      'auto_accept', coalesce((select c.auto_accept from public.ol_merchant_channels c where c.organization_id = v_org), false),
      'cancelled', (select count(*) from o where o.stage = 'cancelled' and o.source is not null),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', o.id, 'display_no', o.display_no, 'placed_at', o.created_at, 'customer', o.customer, 'phone', o.customer_phone,
          'total', o.total, 'source', o.source, 'stage', o.stage, 'items', coalesce(o.items, ''),
          'ref', nullif(regexp_replace(coalesce(o.external_ref, ''), '^[a-z]+:', ''), '')
        ) order by case o.stage when 'new' then 0 when 'preparing' then 1 when 'ready' then 2 when 'on_way' then 3 else 4 end, o.created_at desc), '[]')
        from o where o.source is not null and o.stage <> 'cancelled')
    )
  );
end $function$

;


-- ----------------------------------------------------------------------------------------------------------------------------
-- 0612_size_recipes.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0612: a size uses its recipe that many times (founder, 28 Oct 2026). The recipe on a dish is its Small; a size carries recipe_factor,
-- e.g. Small 1, Medium 2 (two Smalls), Large 3 (three Smalls). Safe to run again.
--   * menu_item_variants.recipe_factor (default 1, 0 to 20).
--   * order_stock_consume: a line of a size takes recipe x factor from stock when it goes to the kitchen (the line keeps its size's name).
--   * sell_return_restock: a returned line of a size puts recipe x factor back.
--   * pos_sell_catalog: each size answers its factor and how many of it can be made (the dish's count / factor, rounded down).
--   * rst_menu: each size answers its factor.
-- The functions below are the live definitions with only those changes.


alter table public.menu_item_variants add column if not exists recipe_factor numeric(6,2) not null default 1;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'menu_item_variants_recipe_factor_check') then
    alter table public.menu_item_variants add constraint menu_item_variants_recipe_factor_check check (recipe_factor > 0 and recipe_factor <= 20);
  end if;
end $$;

CREATE OR REPLACE FUNCTION public.order_stock_consume(p_order uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.orders%rowtype; r record; v_done numeric; v_seq integer; v_n integer := 0; v_k integer;
begin
  select * into o from public.orders where id = p_order;
  if not found or o.status not in ('sent_to_kitchen', 'ready', 'paid', 'delivered') then return 0; end if;
  -- an order already reversed (cancelled earlier in this transaction) never consumes again
  if exists (select 1 from public.stock_movements where ref_type = 'orders' and (ref_id = p_order::text or ref_id like p_order::text || '#%') and kind = 'sale_reversal') then return 0; end if;
  -- one consumer per order at a time
  perform pg_advisory_xact_lock(hashtextextended('order_stock:' || p_order::text, 400));
  -- What the order needs per stock item, against what the ledger already took for it. The first consumption writes one row per item
  -- (ref_id = the order id); a line added or increased later is consumed as a further row for just the difference (ref_id = order id#n), so
  -- it is consumed once and a repeat run adds nothing (H-06). Cancel puts back every row, whichever consumption wrote it.
  for r in
    select rc.inventory_item_id, round(sum(oi.qty * coalesce((select mv.recipe_factor from public.menu_item_variants mv where mv.menu_item_id = oi.menu_item_id and mv.name = oi.variant_name limit 1), 1) * rc.qty_per_unit * (1 + rc.wastage_pct / 100)), 3) as need
      from public.order_items oi
      join public.menu_item_recipes rc on rc.menu_item_id = oi.menu_item_id and rc.organization_id = o.organization_id
     where oi.order_id = o.id and oi.status <> 'cancelled'
     group by rc.inventory_item_id
  loop
    select coalesce(-sum(quantity), 0), count(*) into v_done, v_seq from public.stock_movements
     where ref_type = 'orders' and kind = 'sale' and inventory_item_id = r.inventory_item_id and (ref_id = o.id::text or ref_id like o.id::text || '#%');
    continue when r.need - v_done <= 0;
    insert into public.stock_movements (organization_id, location_id, inventory_item_id, kind, quantity, ref_type, ref_id, note, created_by)
    values (o.organization_id, o.location_id, r.inventory_item_id, 'sale', -(r.need - v_done), 'orders',
            case when v_seq = 0 then o.id::text else o.id::text || '#' || v_seq end, o.display_no, o.created_by)
    on conflict do nothing;
    get diagnostics v_k = row_count;
    v_n := v_n + v_k;
  end loop;
  return v_n;
end $function$

;

CREATE OR REPLACE FUNCTION public.sell_return_restock(p_return uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.sell_returns%rowtype; o public.orders%rowtype; l record; rc record; v_sold numeric; v_back numeric; v_qty numeric; v_left numeric; v_take numeric;
  v_mid bigint; a record; v_bin uuid; v_n int := 0; v_expired boolean;
begin
  select * into r from public.sell_returns where id = p_return;
  select * into o from public.orders where id = r.order_id;
  if not found or o.location_id is null then return 0; end if;
  for l in select sl.id, sl.qty, i.menu_item_id, coalesce((select mv.recipe_factor from public.menu_item_variants mv where mv.menu_item_id = i.menu_item_id and mv.name = i.variant_name limit 1), 1) as factor from public.sell_return_lines sl join public.order_items i on i.id = sl.order_item_id where sl.return_id = r.id and sl.restock loop
    for rc in select inventory_item_id, qty_per_unit from public.menu_item_recipes where menu_item_id = l.menu_item_id and organization_id = r.organization_id loop
      select coalesce(-sum(quantity), 0) into v_sold from public.stock_movements
       where ref_type = 'orders' and kind = 'sale' and inventory_item_id = rc.inventory_item_id and (ref_id = o.id::text or ref_id like o.id::text || '#%');
      continue when v_sold <= 0;
      select coalesce(sum(m.quantity), 0) into v_back from public.stock_movements m
       where m.ref_type = 'sell_returns' and m.kind = 'sale_reversal' and m.inventory_item_id = rc.inventory_item_id
         and m.ref_id in (select x.id::text from public.sell_return_lines x join public.sell_returns y on y.id = x.return_id where y.order_id = o.id);
      v_qty := least(round(l.qty * l.factor * rc.qty_per_unit, 3), v_sold - v_back);
      continue when v_qty <= 0;
      insert into public.stock_movements (organization_id, location_id, inventory_item_id, kind, quantity, ref_type, ref_id, note, created_by)
      values (r.organization_id, o.location_id, rc.inventory_item_id, 'sale_reversal', v_qty, 'sell_returns', l.id::text, 'return ' || r.return_no, auth.uid())
      on conflict do nothing returning id into v_mid;
      continue when v_mid is null;
      v_left := v_qty;
      for a in select al.bin_id, al.lot_id, -sum(al.quantity) as taken from public.stock_allocations al join public.stock_movements s on s.id = al.movement_id
                where s.ref_type = 'orders' and s.kind = 'sale' and s.inventory_item_id = rc.inventory_item_id and (s.ref_id = o.id::text or s.ref_id like o.id::text || '#%')
                group by al.bin_id, al.lot_id having -sum(al.quantity) > 0 order by -sum(al.quantity) desc loop
        exit when v_left <= 0;
        v_take := least(v_left, a.taken);
        v_expired := a.lot_id is not null and exists (select 1 from public.inventory_lots lt where lt.id = a.lot_id and lt.expiry_date < current_date);
        v_bin := case when v_expired then public.inv_default_bin(r.organization_id, o.location_id, 'quarantine') else a.bin_id end;
        insert into public.stock_allocations (organization_id, movement_id, bin_id, lot_id, quantity) values (r.organization_id, v_mid, v_bin, a.lot_id, v_take);
        v_left := v_left - v_take;
      end loop;
      if v_left > 0 then
        insert into public.stock_allocations (organization_id, movement_id, bin_id, quantity) values (r.organization_id, v_mid, public.inv_default_bin(r.organization_id, o.location_id), v_left);
      end if;
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end $function$

;

CREATE OR REPLACE FUNCTION public.pos_sell_catalog(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_q text := nullif(btrim(coalesce(p->>'q', '')), ''); v_cat text := nullif(btrim(coalesce(p->>'category', '')), '');
  v_av boolean; v_sort text := coalesce(nullif(p->>'sort', ''), 'name'); v_like text;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_sort not in ('name', 'price_asc', 'price_desc') then raise exception 'POS_BAD_REQUEST: unknown sort'; end if;
  begin v_av := coalesce((p->>'available')::boolean, false); exception when others then raise exception 'POS_BAD_REQUEST: available is true or false'; end;
  v_like := '%' || regexp_replace(coalesce(v_q, ''), '([%_\\])', '\\\1', 'g') || '%';
  return jsonb_build_object(
    'items', (select coalesce(jsonb_agg(j order by o1, o2 desc, o3), '[]'::jsonb) from (
        select jsonb_build_object('id', i.id, 'name', i.name, 'sku', coalesce(i.sku, ''), 'price', i.price, 'image_url', i.image_url, 'available', i.is_available,
                 'category', coalesce(c.name, ''), 'food_type', coalesce(i.food_type, 'veg'),
                 'has_recipe', exists (select 1 from public.menu_item_recipes mr where mr.menu_item_id = i.id and mr.organization_id = v_org),
                 'can_make', public.menu_can_make(v_org, i.id),
                 'variants', (select coalesce(jsonb_agg(jsonb_build_object('id', mv.id, 'name', mv.name, 'price', mv.price, 'is_default', mv.is_default, 'recipe_factor', mv.recipe_factor,
                                  'can_make', floor(public.menu_can_make(v_org, i.id) / mv.recipe_factor)::int) order by mv.sort_order, mv.price), '[]'::jsonb)
                                from public.menu_item_variants mv where mv.menu_item_id = i.id)) as j,
               case when v_sort = 'price_asc' then i.price end as o1, case when v_sort = 'price_desc' then i.price end as o2, i.name as o3
        from public.menu_items i left join public.menu_categories c on c.id = i.category_id
        where i.organization_id = v_org and (not v_av or i.is_available)
          and (v_q is null or i.name ilike v_like or coalesce(i.sku, '') ilike v_like)
          and (v_cat is null or lower(coalesce(c.name, '')) = lower(v_cat))
        order by o1 asc, o2 desc, o3 limit 200) s),
    'categories', (select coalesce(jsonb_agg(n order by n), '[]'::jsonb) from (
        select distinct c.name as n from public.menu_items i join public.menu_categories c on c.id = i.category_id where i.organization_id = v_org) k));
end $function$

;

CREATE OR REPLACE FUNCTION public.rst_menu(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.current_org_id(); v_loc uuid; v_tz text; v_q text := nullif(btrim(coalesce(p->>'q', '')), '');
  v_filter text := coalesce(nullif(p->>'filter', ''), 'all'); v_out jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_filter not in ('all', 'in_stock', 'out_of_stock', 'needs_image') then raise exception 'POS_BAD_REQUEST: unknown filter'; end if;
  if v_q is not null and char_length(v_q) > 60 then raise exception 'POS_BAD_REQUEST: search text is too long'; end if;
  v_loc := public.rst_menu_outlet(v_org, p);
  v_tz := public.menu_outlet_tz(v_org, v_loc);
  with base as (
    select m.*, c.name as cat_name, c.sort_order as cat_sort,
           coalesce(m.price_minor, round(m.price * 100)::bigint) as pminor,
           (select count(*) from public.menu_item_variants v where v.menu_item_id = m.id) as n_variants,
           exists (select 1 from public.menu_item_availability a where a.menu_item_id = m.id) as has_windows
      from public.menu_items m left join public.menu_categories c on c.id = m.category_id
     where m.organization_id = v_org),
  shown as (
    select * from base b
     where (v_q is null or b.name ilike '%' || v_q || '%' or coalesce(b.description, '') ilike '%' || v_q || '%')
       and case v_filter when 'all' then true when 'in_stock' then b.is_available when 'out_of_stock' then not b.is_available
                         else nullif(btrim(coalesce(b.image_url, '')), '') is null end),
  cats as (
    select b.category_id, coalesce(b.cat_name, 'Other') as name, min(coalesce(b.cat_sort, 2147483647)) as srt, count(*) as n,
           count(*) filter (where b.is_available) as n_in
      from base b group by b.category_id, coalesce(b.cat_name, 'Other'))
  select jsonb_build_object(
    'business', (select o.name from public.organizations o where o.id = v_org),
    'location', jsonb_build_object('id', v_loc, 'name', (select l.name from public.locations l where l.id = v_loc)),
    'outlets', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by (l.code = 'MAIN') desc, l.created_at), '[]'::jsonb)
                  from public.locations l where l.organization_id = v_org and l.status = 'active' and public.location_is_allowed(v_org, l.id)),
    'can_edit', public.has_permission(v_org, 'menu', 'update'),
    'counts', (select jsonb_build_object('total', count(*), 'in_stock', count(*) filter (where is_available),
                 'out_of_stock', count(*) filter (where not is_available),
                 'needs_image', count(*) filter (where nullif(btrim(coalesce(image_url, '')), '') is null),
                 'with_image', count(*) filter (where nullif(btrim(coalesce(image_url, '')), '') is not null),
                 'missing_description', count(*) filter (where nullif(btrim(coalesce(description, '')), '') is null)) from base),
    'filter', v_filter,
    'categories', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.category_id, 'name', c.name, 'count', c.n, 'in_stock', c.n_in, 'all_in_stock', c.n_in = c.n,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', s.id, 'name', s.name, 'price_minor', s.pminor, 'description', s.description, 'food_type', s.food_type, 'course', s.course,
                    'image_url', s.image_url, 'in_stock', s.is_available, 'variants', s.n_variants, 'sizes', (select coalesce(jsonb_agg(jsonb_build_object('name', mv.name, 'price', mv.price, 'recipe_factor', mv.recipe_factor) order by mv.sort_order, mv.price), '[]'::jsonb) from public.menu_item_variants mv where mv.menu_item_id = s.id), 'has_windows', s.has_windows,
                    'orderable_now', public.menu_item_orderable_at(s.id, now(), v_tz)) order by s.sort_order, lower(s.name), s.id), '[]'::jsonb)
                    from shown s where s.category_id is not distinct from c.category_id))
        order by c.srt, lower(c.name)), '[]'::jsonb)
      from cats c where exists (select 1 from shown s where s.category_id is not distinct from c.category_id))
  ) into v_out;
  return v_out;
end $function$

;


-- ----------------------------------------------------------------------------------------------------------------------------
-- 0613_menu_price_save.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0613: edit a dish's selling price from its recipe (founder, 28 Oct 2026), and, for a dish with sizes, each size's price. Safe to run again.
--   * menu_price_save({id, version, price, sizes?: [{id, price}]}): the dish's price, and each listed size's. The dish's version guards
--     against a change made on another phone (the same rule as menu_item_settings_save). A size must be the dish's; prices are above zero.
--     The default size (Small) always keeps the dish's price, so the Bill and the Menu agree.
--   * menu_item_settings answers the dish's sizes (id, name, price, recipe_factor) as well.


create or replace function public.menu_price_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); m public.menu_items%rowtype; v_price numeric; s jsonb; v_sp numeric;
begin
  select * into m from public.menu_items where id = nullif(p->>'id', '')::uuid and organization_id = v_org for update;
  if not found then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  if nullif(p->>'version', '') is null or (p->>'version')::bigint <> m.edit_version then raise exception 'POS_STALE: this dish was changed on another device'; end if;
  begin v_price := round((p->>'price')::numeric, 2); exception when others then v_price := null; end;
  if v_price is null or v_price <= 0 or v_price > 1000000 then raise exception 'POS_BAD_REQUEST: enter a selling price above zero'; end if;
  if p ? 'sizes' and jsonb_typeof(p->'sizes') <> 'array' then raise exception 'POS_BAD_REQUEST: sizes is a list'; end if;
  for s in select * from jsonb_array_elements(coalesce(p->'sizes', '[]'::jsonb)) loop
    if not exists (select 1 from public.menu_item_variants v where v.id = nullif(s->>'id', '')::uuid and v.menu_item_id = m.id) then
      raise exception 'POS_BAD_REQUEST: that size is not on %', m.name; end if;
    begin v_sp := round((s->>'price')::numeric, 2); exception when others then v_sp := null; end;
    if v_sp is null or v_sp <= 0 or v_sp > 1000000 then raise exception 'POS_BAD_REQUEST: enter a price above zero for every size'; end if;
    update public.menu_item_variants set price = v_sp where id = (s->>'id')::uuid;
  end loop;
  update public.menu_items set price = v_price, updated_at = now() where id = m.id;
  update public.menu_item_variants set price = v_price where menu_item_id = m.id and is_default;   -- Small = the dish's price
  return public.menu_item_settings(jsonb_build_object('id', m.id));
end $$;
revoke all on function public.menu_price_save(jsonb) from public, anon;
grant execute on function public.menu_price_save(jsonb) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.menu_item_settings(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_org uuid := public.mb_org('menu', 'update'); m public.menu_items%rowtype;
begin
  select * into m from public.menu_items where id = nullif(p->>'id', '')::uuid and organization_id = v_org;
  if not found then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  return jsonb_build_object('id', m.id, 'version', m.edit_version, 'name', m.name, 'price_minor', round(m.price * 100)::bigint,
    'sizes', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'price', v.price, 'recipe_factor', v.recipe_factor, 'is_default', v.is_default) order by v.sort_order, v.price), '[]'::jsonb)
              from public.menu_item_variants v where v.menu_item_id = m.id),
    'category_id', m.category_id, 'category', (select name from public.menu_categories where id = m.category_id),
    'food_type', m.food_type, 'course', m.course, 'station', m.station, 'prep_minutes', m.prep_minutes, 'is_recommended', m.is_recommended,
    'sku', m.sku, 'is_available', m.is_available, 'image_url', m.image_url, 'description', m.description,
    'addon_group_ids', coalesce((select jsonb_agg(group_id) from public.menu_item_addon_groups where menu_item_id = m.id), '[]'),
    'recipe', public.mb_recipe_json(v_org, m.id) - 'lines',
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort_order, name)
                            from public.menu_categories where organization_id = v_org), '[]'),
    'addon_groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name,
                               'addons', (select count(*) from public.menu_addons a where a.group_id = g.id and a.active)) order by g.sort_order, g.name)
                              from public.menu_addon_groups g where g.organization_id = v_org and g.active), '[]'),
    'stations', '["main","grill","beverage","dessert","tandoor","chinese"]'::jsonb);
end $function$

;


-- ----------------------------------------------------------------------------------------------------------------------------
-- 0614_activity_log.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0614: the Activity log in Settings (founder, 28 Oct 2026): the operational timeline that used to sit on the table order page, for every order of
-- the business in one place, newest first. Read only. Safe to run again.
--   p: location_id (optional; null or 'all' = every outlet the user may see), before (optional cursor: the 'at' of the last entry shown),
--      limit (1-100, default 50).
--   answer: entries [{id, at, kind, message, actor, order_id, display_no, table_label, location_name}], more (true when older entries exist).

create or replace function public.rst_activity_log(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(nullif(p->>'location_id', ''), 'all')::uuid;
  v_before timestamptz := nullif(p->>'before', '')::timestamptz; v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 100); v_rows jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'at', x.created_at, 'kind', x.kind, 'message', x.message, 'actor', x.actor, 'order_id', x.order_id,
           'display_no', x.display_no, 'table_label', x.table_label, 'location_name', x.location_name) order by x.created_at desc, x.id desc), '[]'::jsonb)
    into v_rows
    from (select ev.id, ev.created_at, ev.kind, ev.message, ev.actor, ev.order_id, o.display_no, t.label as table_label, l.name as location_name
            from public.order_events ev
            join public.orders o on o.id = ev.order_id and o.organization_id = v_org
            left join public.dining_tables t on t.id = o.table_id
            left join public.locations l on l.id = o.location_id
           where ev.organization_id = v_org
             and (v_loc is null or o.location_id = v_loc)
             and (o.location_id is null or public.location_is_allowed(v_org, o.location_id))
             and (v_before is null or ev.created_at < v_before)
           order by ev.created_at desc, ev.id desc
           limit v_limit + 1) x;
  return jsonb_build_object('entries', coalesce((select jsonb_agg(e order by ord) from jsonb_array_elements(v_rows) with ordinality as a(e, ord) where ord <= v_limit), '[]'::jsonb),
                            'more', jsonb_array_length(v_rows) > v_limit);
end $$;

revoke all on function public.rst_activity_log(jsonb) from public, anon;
grant execute on function public.rst_activity_log(jsonb) to authenticated, service_role;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0615_po_send.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0615: send a purchase order to the supplier (founder, 28 Oct 2026). The app opens WhatsApp or SMS on the phone with the order; the database
-- records that it was sent (when, how, the number masked) so the order shows "Sent to supplier". Safe to run again.
--   * pur_po_json: the supplier's phone, 'sent' (the last send, and how many), and the 'send' action on an Approved / Partially Received order
--     for whoever may record purchases.
--   * pur_po_send({id, channel: whatsapp | sms, to}): checks the order and the number (10-digit Indian mobile, or +91 / 91 and 10 digits), logs
--     purchase_events 'po_sent', and saves the number on the supplier when the supplier had none. Returns the order.

CREATE OR REPLACE FUNCTION public.pur_po_json(po pos_purchase_orders)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare r record; v_lines jsonb := '[]'::jsonb; v_est bigint := 0; v_sub bigint := 0; v_tax bigint := 0; v_otax bigint := 0; v_ordered bigint; v_acc bigint; v_t bigint; v_ot bigint; v_tag text;
  v_item jsonb; v_rc record; v_sup jsonb; v_received_at timestamptz; v_doc uuid; v_doc_status text; v_doc_no text; v_header_rate boolean; v_rate numeric; v_over numeric; v_cost bigint;
  v_acts jsonb := '[]'::jsonb; v_total bigint; v_mine boolean; v_can_rec boolean; v_can_po boolean; v_can_appr boolean; v_creator uuid;
begin
  v_header_rate := not exists (select 1 from public.pos_purchase_order_lines l where l.organization_id = po.organization_id and l.po_number = po.number
                                  and l.location_id is not distinct from po.location_id and l.deleted_at is null and l.gst_pct > 0) and coalesce(po.tax_pct, 0) > 0;
  for r in select * from public.pos_purchase_order_lines l
            where l.organization_id = po.organization_id and l.po_number = po.number and l.deleted_at is null
              and l.location_id is not distinct from po.location_id order by l.id loop
    v_cost := coalesce(r.unit_cost_minor, public.pur_minor(r.unit_cost));
    v_rate := case when v_header_rate then po.tax_pct::numeric else r.gst_pct end;
    v_ordered := round(r.ordered_qty::numeric * v_cost)::bigint;
    v_acc := round(r.received_qty::numeric * v_cost)::bigint;
    v_t := round(v_acc * v_rate / 100)::bigint;
    v_ot := round(v_ordered * v_rate / 100)::bigint;
    v_est := v_est + v_ordered; v_sub := v_sub + v_acc; v_tax := v_tax + v_t; v_otax := v_otax + v_ot;
    select coalesce(sum(x.over_qty), 0) into v_over from public.purchase_receipt_lines x where x.po_line_row_id = r.row_id;
    v_tag := case when r.received_qty = 0 and r.rejected_qty = 0 and v_over = 0 then null
                  when r.rejected_qty > 0 or v_over > 0 or (po.status = 'Received' and r.received_qty < r.ordered_qty) then 'discrepancy'
                  when r.received_qty >= r.ordered_qty then 'approved' else null end;
    v_item := null;
    if r.material_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      select jsonb_build_object('id', i.id, 'name', i.name, 'sku', i.sku, 'unit', i.unit) into v_item
        from public.inventory_items i where i.id = r.material_id::uuid and i.organization_id = po.organization_id;
    end if;
    select x.lot_code, x.expiry_date into v_rc from public.purchase_receipt_lines x
     where x.po_line_row_id = r.row_id order by x.posted_at desc, x.id desc limit 1;
    v_lines := v_lines || jsonb_build_object(
      'id', r.row_id, 'line_no', r.id, 'item', v_item, 'material_id', r.material_id, 'name', r.material_name, 'code', r.code, 'unit', r.unit,
      'ordered_qty', r.ordered_qty, 'received_qty', r.received_qty, 'accepted_qty', r.received_qty, 'rejected_qty', r.rejected_qty, 'over_qty', v_over,
      'unit_cost_minor', v_cost, 'gst_pct', v_rate,
      'ordered_minor', v_ordered, 'accepted_minor', v_acc, 'tax_minor', v_t, 'tag', v_tag,
      'lot_code', nullif(v_rc.lot_code, ''), 'expiry_date', v_rc.expiry_date);
  end loop;
  v_total := v_est + v_otax;
  select max(x.posted_at) into v_received_at from public.purchase_receipt_lines x where x.po_row_id = po.row_id;
  select jsonb_build_object('id', s.id, 'name', s.name, 'rating', s.rating, 'payment_terms', s.payment_terms, 'phone', nullif(btrim(s.phone), '')) into v_sup
    from public.pos_suppliers s where s.organization_id = po.organization_id and s.id = po.supplier_id and s.deleted_at is null
   order by (s.location_id is not distinct from po.location_id) desc limit 1;
  select d.id, d.status, d.doc_no into v_doc, v_doc_status, v_doc_no from public.inventory_documents d
   where d.organization_id = po.organization_id and d.doc_type = 'receipt' and d.po_ref = po.number and d.location_id is not distinct from po.location_id and d.status in ('draft', 'review')
   order by d.created_at limit 1;
  v_can_po := public.has_permission(po.organization_id, 'purchasing', 'record', po.location_id);
  v_can_appr := public.has_permission(po.organization_id, 'purchasing', 'approve_po', po.location_id);
  v_mine := po.created_by = auth.uid()::text;
  v_can_rec := po.status in ('Approved', 'Partially Received') and v_can_po and public.has_permission(po.organization_id, 'inventory', 'record', po.location_id);
  if po.status = 'Draft' and v_can_po then v_acts := v_acts || '["submit", "cancel"]'::jsonb; end if;
  if po.status = 'Pending' then
    if v_can_appr and (not v_mine or (v_total <= public.pur_self_approval_limit_minor()
         and public.pur_self_approved_today(po.organization_id, auth.uid(), po.supplier_id) + v_total <= public.pur_self_approval_limit_minor())) then v_acts := v_acts || '["approve"]'::jsonb; end if;
    if v_can_appr then v_acts := v_acts || '["reject"]'::jsonb; end if;
    if v_can_po or v_can_appr then v_acts := v_acts || '["cancel"]'::jsonb; end if;
  end if;
  if po.status in ('Approved', 'Partially Received') and v_can_appr then v_acts := v_acts || '["cancel"]'::jsonb; end if;
  if v_can_rec then v_acts := v_acts || '["receive"]'::jsonb; end if;
  -- 0615: an approved order can be sent to the supplier (WhatsApp / SMS) by whoever may record purchases
  if po.status in ('Approved', 'Partially Received') and v_can_po then v_acts := v_acts || '["send"]'::jsonb; end if;
  begin v_creator := po.created_by::uuid; exception when others then v_creator := null; end;
  return jsonb_build_object(
    'id', po.row_id, 'number', po.number, 'status', po.status, 'order_date', po.order_date, 'expected_delivery', po.expected_delivery,
    'overdue', po.status in ('Approved', 'Partially Received') and po.expected_delivery < now(), 'received_at', v_received_at, 'notes', po.notes,
    'location_id', po.location_id, 'supplier', coalesce(v_sup, jsonb_build_object('id', po.supplier_id, 'name', po.supplier_id)),
    'created_by', public.inv_person(po.organization_id, v_creator), 'tax_pct', po.tax_pct,
    'lines', v_lines,
    'totals', jsonb_build_object('estimated_minor', v_est, 'ordered_tax_minor', v_otax, 'ordered_total_minor', v_total,
                                 'subtotal_minor', v_sub, 'tax_minor', v_tax, 'total_minor', v_sub + v_tax),
    'self_approval_limit_minor', public.pur_self_approval_limit_minor(),
    'open_receipt', case when v_doc is null then null else jsonb_build_object('id', v_doc, 'status', v_doc_status, 'doc_no', v_doc_no) end,
    'sent', (select jsonb_build_object('at', e.created_at, 'channel', e.meta->>'channel', 'to', e.meta->>'to', 'times', (select count(*) from public.purchase_events c where c.po_row_id = po.row_id and c.action = 'po_sent'))
               from public.purchase_events e where e.po_row_id = po.row_id and e.action = 'po_sent' order by e.created_at desc, e.id desc limit 1),
    'allowed_actions', v_acts);
end $$

;

create or replace function public.pur_po_send(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); po public.pos_purchase_orders%rowtype; v_ch text := p->>'channel';
  v_digits text := regexp_replace(coalesce(p->>'to', ''), '\D', '', 'g');
begin
  if auth.uid() is null or v_org is null then raise exception 'PUR_FORBIDDEN: sign in to a business first'; end if;
  select * into po from public.pos_purchase_orders o where o.row_id = nullif(p->>'id', '')::uuid and o.organization_id = v_org and o.deleted_at is null for update;
  if not found or not public.location_is_allowed(v_org, po.location_id) then raise exception 'PUR_NOT_FOUND: purchase order not found'; end if;
  if not public.has_permission(v_org, 'purchasing', 'record', po.location_id) then raise exception 'PUR_FORBIDDEN: your role cannot send purchase orders'; end if;
  if v_ch is null or v_ch not in ('whatsapp', 'sms') then raise exception 'PUR_BAD_REQUEST: send by whatsapp or sms'; end if;
  if po.status not in ('Approved', 'Partially Received') then raise exception 'PUR_WRONG_STATE: % is % and cannot be sent; send it once it is approved', po.number, po.status; end if;
  if length(v_digits) = 12 and left(v_digits, 2) = '91' then v_digits := right(v_digits, 10); end if;
  if v_digits !~ '^[6-9][0-9]{9}$' then raise exception 'PUR_BAD_REQUEST: enter the supplier''s 10-digit mobile number'; end if;
  update public.pos_suppliers s set phone = v_digits, server_updated_at = now(), updated_by = auth.uid()
   where s.organization_id = v_org and s.id = po.supplier_id and s.deleted_at is null and coalesce(btrim(s.phone), '') = '';
  insert into public.purchase_events (organization_id, location_id, po_row_id, action, actor, meta)
  values (v_org, po.location_id, po.row_id, 'po_sent', auth.uid(),
          jsonb_build_object('number', po.number, 'channel', v_ch, 'to', repeat('*', 6) || right(v_digits, 4), 'supplier_id', po.supplier_id));
  return public.pur_po_json(po);
end $$;

revoke all on function public.pur_po_send(jsonb) from public, anon;
grant execute on function public.pur_po_send(jsonb) to authenticated, service_role;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0616_menu_subcategories.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0616: menu categories and subcategories (founder, 28 Oct 2026). A category may have subcategories, one level deep (Beverages › Cold
-- coffee). Dishes sit in a category or a subcategory. Names stay unique in the business, so a dish's category is still found by name.
--   * menu_categories.parent_id (null = a top category)
--   * menu_category_list(): every category with its parent, order and dish count, and whether this person may edit
--   * menu_category_save({id?, name, parent_id?, sort_order?}): add or rename; set or clear the parent (a parent must be a top category,
--     never itself, and a category that has subcategories stays a top category)
--   * menu_category_delete({id}): only an empty one (no dishes, no subcategories)
--   * rst_menu: each category also says parent_id and parent_name
-- Safe to run again.

alter table public.menu_categories add column if not exists parent_id uuid references public.menu_categories(id) on delete set null;
create index if not exists menu_categories_parent_idx on public.menu_categories (parent_id);

create or replace function public.menu_category_list(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id();
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  return jsonb_build_object(
    'can_edit', public.has_permission(v_org, 'menu', 'update'),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'parent_id', c.parent_id, 'sort_order', c.sort_order,
                      'dishes', (select count(*) from public.menu_items i where i.category_id = c.id)) order by c.sort_order, lower(c.name)), '[]'::jsonb)
                   from public.menu_categories c where c.organization_id = v_org));
end $$;

create or replace function public.menu_category_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); v_id uuid := nullif(p->>'id', '')::uuid; v_name text := public.mb_clean(p->>'name');
  v_parent uuid := nullif(p->>'parent_id', '')::uuid; v_set_parent boolean := p ? 'parent_id';
begin
  if v_name is null or char_length(v_name) > 60 then raise exception 'POS_BAD_REQUEST: enter a category (up to 60 characters)'; end if;
  if v_parent is not null then
    if not exists (select 1 from public.menu_categories where id = v_parent and organization_id = v_org) then raise exception 'POS_NOT_FOUND: parent category not found'; end if;
    if exists (select 1 from public.menu_categories where id = v_parent and parent_id is not null) then
      raise exception 'POS_BAD_REQUEST: a subcategory cannot have its own subcategories'; end if;
    if v_parent = v_id then raise exception 'POS_BAD_REQUEST: a category cannot sit under itself'; end if;
    if v_id is not null and exists (select 1 from public.menu_categories where parent_id = v_id) then
      raise exception 'POS_BAD_REQUEST: this category has subcategories, so it stays a main category'; end if;
  end if;
  if exists (select 1 from public.menu_categories where organization_id = v_org and lower(name) = lower(v_name) and id is distinct from v_id) then
    raise exception 'POS_CONFLICT: there is already a category called %', v_name; end if;
  if v_id is null then
    insert into public.menu_categories (organization_id, name, parent_id, sort_order)
    values (v_org, v_name, v_parent, coalesce(nullif(p->>'sort_order', '')::int, (select max(sort_order) + 1 from public.menu_categories where organization_id = v_org), 0))
    returning id into v_id;
  else
    update public.menu_categories set name = v_name, parent_id = case when v_set_parent then v_parent else parent_id end,
           sort_order = coalesce(nullif(p->>'sort_order', '')::int, sort_order)
     where id = v_id and organization_id = v_org;
    if not found then raise exception 'POS_NOT_FOUND: category not found'; end if;
  end if;
  return jsonb_build_object('id', v_id) || public.menu_category_list('{}'::jsonb);
end $$;

create or replace function public.menu_category_delete(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); v_id uuid := nullif(p->>'id', '')::uuid; v_n int;
begin
  if not exists (select 1 from public.menu_categories where id = v_id and organization_id = v_org) then raise exception 'POS_NOT_FOUND: category not found'; end if;
  select count(*) into v_n from public.menu_items where category_id = v_id;
  if v_n > 0 then raise exception 'POS_CONFLICT: move its % dish% to another category first', v_n, case when v_n = 1 then '' else 'es' end; end if;
  if exists (select 1 from public.menu_categories where parent_id = v_id) then raise exception 'POS_CONFLICT: delete or move its subcategories first'; end if;
  delete from public.menu_categories where id = v_id and organization_id = v_org;
  return public.menu_category_list('{}'::jsonb);
end $$;

revoke all on function public.menu_category_list(jsonb) from public, anon;
revoke all on function public.menu_category_delete(jsonb) from public, anon;
grant execute on function public.menu_category_list(jsonb) to authenticated, service_role;
grant execute on function public.menu_category_delete(jsonb) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rst_menu(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.current_org_id(); v_loc uuid; v_tz text; v_q text := nullif(btrim(coalesce(p->>'q', '')), '');
  v_filter text := coalesce(nullif(p->>'filter', ''), 'all'); v_out jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_filter not in ('all', 'in_stock', 'out_of_stock', 'needs_image') then raise exception 'POS_BAD_REQUEST: unknown filter'; end if;
  if v_q is not null and char_length(v_q) > 60 then raise exception 'POS_BAD_REQUEST: search text is too long'; end if;
  v_loc := public.rst_menu_outlet(v_org, p);
  v_tz := public.menu_outlet_tz(v_org, v_loc);
  with base as (
    select m.*, c.name as cat_name, c.sort_order as cat_sort,
           coalesce(m.price_minor, round(m.price * 100)::bigint) as pminor,
           (select count(*) from public.menu_item_variants v where v.menu_item_id = m.id) as n_variants,
           exists (select 1 from public.menu_item_availability a where a.menu_item_id = m.id) as has_windows
      from public.menu_items m left join public.menu_categories c on c.id = m.category_id
     where m.organization_id = v_org),
  shown as (
    select * from base b
     where (v_q is null or b.name ilike '%' || v_q || '%' or coalesce(b.description, '') ilike '%' || v_q || '%')
       and case v_filter when 'all' then true when 'in_stock' then b.is_available when 'out_of_stock' then not b.is_available
                         else nullif(btrim(coalesce(b.image_url, '')), '') is null end),
  cats as (
    select b.category_id, coalesce(b.cat_name, 'Other') as name, min(coalesce(b.cat_sort, 2147483647)) as srt, count(*) as n,
           count(*) filter (where b.is_available) as n_in
      from base b group by b.category_id, coalesce(b.cat_name, 'Other'))
  select jsonb_build_object(
    'business', (select o.name from public.organizations o where o.id = v_org),
    'location', jsonb_build_object('id', v_loc, 'name', (select l.name from public.locations l where l.id = v_loc)),
    'outlets', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by (l.code = 'MAIN') desc, l.created_at), '[]'::jsonb)
                  from public.locations l where l.organization_id = v_org and l.status = 'active' and public.location_is_allowed(v_org, l.id)),
    'can_edit', public.has_permission(v_org, 'menu', 'update'),
    'counts', (select jsonb_build_object('total', count(*), 'in_stock', count(*) filter (where is_available),
                 'out_of_stock', count(*) filter (where not is_available),
                 'needs_image', count(*) filter (where nullif(btrim(coalesce(image_url, '')), '') is null),
                 'with_image', count(*) filter (where nullif(btrim(coalesce(image_url, '')), '') is not null),
                 'missing_description', count(*) filter (where nullif(btrim(coalesce(description, '')), '') is null)) from base),
    'filter', v_filter,
    'categories', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.category_id, 'name', c.name, 'count', c.n, 'in_stock', c.n_in, 'all_in_stock', c.n_in = c.n,
        -- 0616: a subcategory names its parent, so the Menu tab can group it under the parent's pill
        'parent_id', (select pc.parent_id from public.menu_categories pc where pc.id = c.category_id),
        'parent_name', (select pp.name from public.menu_categories pc join public.menu_categories pp on pp.id = pc.parent_id where pc.id = c.category_id),
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', s.id, 'name', s.name, 'price_minor', s.pminor, 'description', s.description, 'food_type', s.food_type, 'course', s.course,
                    'image_url', s.image_url, 'in_stock', s.is_available, 'variants', s.n_variants, 'sizes', (select coalesce(jsonb_agg(jsonb_build_object('name', mv.name, 'price', mv.price, 'recipe_factor', mv.recipe_factor) order by mv.sort_order, mv.price), '[]'::jsonb) from public.menu_item_variants mv where mv.menu_item_id = s.id), 'has_windows', s.has_windows,
                    'orderable_now', public.menu_item_orderable_at(s.id, now(), v_tz)) order by s.sort_order, lower(s.name), s.id), '[]'::jsonb)
                    from shown s where s.category_id is not distinct from c.category_id))
        order by c.srt, lower(c.name)), '[]'::jsonb)
      from cats c where exists (select 1 from shown s where s.category_id is not distinct from c.category_id))
  ) into v_out;
  return v_out;
end $$

;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0617_kot_table_moved.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0617: a table transfer shows on the kitchen tickets (founder, 28 Oct 2026). The KDS and KOT views already read the table from the order,
-- so a moved order shows its new table; now each ticket also says it moved ("T2 → T5", when), so the kitchen and the pass notice.
--   * order_table_move(order): the order's last transfer {from, to, at}, or null
--   * kds_card_json and rst_kot_orders: 'moved'
-- Read only. Safe to run again.

create or replace function public.order_table_move(p_order uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('from', coalesce(f.label, '?'), 'to', coalesce(t.label, '?'), 'at', e.created_at)
    from public.order_events e
    left join public.dining_tables f on f.id = nullif(e.meta->>'from', '')::uuid
    left join public.dining_tables t on t.id = nullif(e.meta->>'to', '')::uuid
   where e.order_id = p_order and e.kind = 'table_transferred'
   order by e.created_at desc, e.id desc limit 1
$$;
revoke all on function public.order_table_move(uuid) from public, anon;

CREATE OR REPLACE FUNCTION public.kds_card_json(p_ticket uuid, p_key text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
  select jsonb_build_object(
    'card_id', c.ticket_id || ':' || c.queue_key, 'id', c.ticket_id, 'station', c.queue_key,
    'station_name', coalesce((select s.name from public.pos_kitchen_stations s where s.organization_id = t.organization_id and s.key = c.queue_key), 'Unassigned'),
    'kot_no', c.kot_no, 'order_id', c.order_id, 'display_no', c.display_no, 'channel', c.channel, 'chip', c.chip, 'version', c.version,
    'status', case c.chip when 'new' then 'new' when 'in_progress' then 'preparing' when 'ready' then 'ready' else 'delivered' end,
    'priority', c.priority, 'age_minutes', greatest(0, floor(extract(epoch from now() - c.created_at) / 60))::int,
    'delayed', c.chip in ('new', 'in_progress') and c.created_at < now() - interval '15 minutes',
    'created_at', c.created_at, 'started_at', c.started_at, 'ready_at', case when c.chip in ('ready', 'served') then c.ready_at end, 'served_at', c.served_at,
    'table_label', (select d.label from public.dining_tables d where d.id = o.table_id and d.organization_id = o.organization_id),
    'moved', public.order_table_move(o.id),
    'order_note', nullif(btrim(coalesce(o.notes, '')), ''),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'takeaway', i.is_takeaway, 'qty', i.qty, 'status', i.status, 'done', i.status in ('ready', 'delivered'),
                 'station', i.station, 'notes', nullif(btrim(coalesce(i.notes, '')), ''), 'variant', i.variant_name) order by i.created_at, i.name)
               from public.order_items i where i.kot_ticket_id = t.id and i.status <> 'cancelled' and public.kitchen_queue_key(t.organization_id, i.station) = c.queue_key), '[]'::jsonb),
    'item_count', c.n_total, 'done_count', c.n_done,
    'stations', jsonb_build_array(coalesce((select s.name from public.pos_kitchen_stations s where s.organization_id = t.organization_id and s.key = c.queue_key), 'Unassigned')))
  from public.kot_tickets t join public.orders o on o.id = t.order_id
  join lateral public.kds_cards(t.organization_id, t.id) c on c.queue_key = p_key
  where t.id = p_ticket;
$$

;

CREATE OR REPLACE FUNCTION public.rst_kot_orders(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(nullif(p->>'location_id', ''), 'all')::uuid;
  v_st text := coalesce(nullif(p->>'status', ''), 'all'); v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_st not in ('all', 'preparing', 'ready', 'completed') then raise exception 'POS_BAD_REQUEST: unknown status'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.total, o.status, o.channel, o.created_at, o.paid_at, o.table_id, o.captain_name,
             t.label as table_label,
             (select count(*) from public.order_items i where i.order_id = o.id and i.status <> 'cancelled') as items,
             (select count(*) from public.order_items i where i.order_id = o.id and (i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered')))) as ready,
             (select count(*) from public.order_items i where i.order_id = o.id and i.status = 'pending' and i.started_at is null) as untouched
        from public.orders o left join public.dining_tables t on t.id = o.table_id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc) and o.created_at >= v_since and o.status <> 'cancelled'
         and exists (select 1 from public.kot_tickets k where k.order_id = o.id)
    ), s as (
      select o.*,
             case when o.paid_at is not null or o.status in ('paid', 'delivered') then 'completed'
                  when o.items > 0 and o.ready = o.items then 'ready'
                  when o.untouched = o.items then 'new' else 'preparing' end as stage
        from o
    )
    select jsonb_build_object(
      'counts', jsonb_build_object('all', (select count(*) from s), 'preparing', (select count(*) from s where stage in ('new', 'preparing')),
                                   'ready', (select count(*) from s where stage = 'ready'), 'completed', (select count(*) from s where stage = 'completed')),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', s.id, 'display_no', s.display_no, 'total', s.total, 'stage', s.stage, 'channel', s.channel, 'table_id', s.table_id, 'table_label', s.table_label,
          'moved', public.order_table_move(s.id),
          'captain', s.captain_name, 'paid', s.paid_at is not null, 'created_at', s.created_at,
          'minutes', floor(extract(epoch from (now() - s.created_at)) / 60)::int, 'items', s.items, 'ready', s.ready,
          'kots', (select jsonb_agg(jsonb_build_object('id', k.id, 'kot_no', k.kot_no, 'status', k.status,
                      'items', (select count(*) from public.order_items i where i.kot_ticket_id = k.id and i.status <> 'cancelled'),
                      'ready', (select count(*) from public.order_items i where i.kot_ticket_id = k.id and (i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered'))))) order by k.kot_no)
                   from public.kot_tickets k where k.order_id = s.id),
          'stations', (select coalesce(jsonb_agg(jsonb_build_object('name', public.tbl_station_label(v_org, x.station), 'done', x.done) order by x.station), '[]')
                         from (select i.station, bool_and((i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered')))) as done from public.order_items i
                                where i.order_id = s.id and i.status <> 'cancelled' group by i.station) x),
          'ready_item_ids', (select coalesce(jsonb_agg(i.id), '[]') from public.order_items i where i.order_id = s.id and i.status = 'ready'),
          'latest_ticket', (select k.id from public.kot_tickets k where k.order_id = s.id order by k.kot_no desc limit 1)
        ) order by case s.stage when 'ready' then 0 when 'preparing' then 1 when 'new' then 2 else 3 end, s.created_at desc), '[]')
        from s where v_st = 'all' or (v_st = 'preparing' and s.stage in ('new', 'preparing')) or s.stage = v_st)
    )
  );
end $$

;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0618_kds_cancelled.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0618: a cancelled order buzzes the KDS (founder, 28 Oct 2026). A ticket used to vanish from the kitchen display without a word when its
-- order was cancelled. kds_queue now also lists the orders cancelled in the last hour that had already gone to the kitchen: number, where
-- it was going, its KOTs and dishes, and when; the KDS sounds an alarm once for each and shows "Stop cooking" until it is dismissed.
--   * kds_cancelled(org, outlet)
--   * kds_queue: 'cancelled'
-- Read only. Safe to run again.

create or replace function public.kds_cancelled(p_org uuid, p_loc uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'order_id', o.id, 'display_no', o.display_no, 'channel', o.channel, 'at', o.updated_at,
           'table_label', (select d.label from public.dining_tables d where d.id = o.table_id),
           'kots', (select jsonb_agg(k.kot_no order by k.kot_no) from public.kot_tickets k where k.order_id = o.id),
           'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'qty', i.qty, 'variant', i.variant_name) order by i.created_at), '[]'::jsonb)
                       from public.order_items i where i.order_id = o.id and i.kot_ticket_id is not null))
         order by o.updated_at desc), '[]'::jsonb)
    from public.orders o
   where o.organization_id = p_org and o.status = 'cancelled' and o.updated_at > now() - interval '60 minutes'
     and (p_loc is null or o.location_id = p_loc)
     and exists (select 1 from public.kot_tickets k where k.order_id = o.id)
$$;
revoke all on function public.kds_cancelled(uuid, uuid) from public, anon;

CREATE OR REPLACE FUNCTION public.kds_queue(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.current_org_id(); v_station text := nullif(btrim(coalesce(p->>'station', '')), ''); v_loc uuid := nullif(p->>'location_id', '')::uuid;
  v_status text := coalesce(nullif(p->>'status', ''), 'all'); v_q text := nullif(lower(btrim(coalesce(p->>'q', ''))), '');
  v_day timestamptz := date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  v_stats jsonb; v_counts jsonb; v_cards jsonb; v_chips jsonb;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_NOT_FOUND: sign in to a business first'; end if;
  if not public.kitchen_can(v_org, 'view') then raise exception 'POS_FORBIDDEN: your role cannot see the kitchen display'; end if;
  if v_status not in ('all', 'new', 'in_progress', 'ready', 'served') then raise exception 'POS_BAD_REQUEST: unknown status'; end if;
  if v_station is not null and v_station <> 'unassigned' and not exists (select 1 from public.pos_kitchen_stations where organization_id = v_org and key = v_station) then
    raise exception 'POS_NOT_FOUND: station not found'; end if;
  -- one statement, no scratch tables
  with cards as (select * from public.kds_cards(v_org) c where v_loc is null or c.location_id = v_loc),
  vis_all as (select * from cards c where public.kds_visible(c.chip, c.order_status, c.created_at, c.served_at)),
  vis as (select * from vis_all c where v_station is null or c.queue_key = v_station),
  done as (select count(*) n from cards c where c.chip = 'served' and c.served_at >= v_day and (v_station is null or c.queue_key = v_station)),
  shown as (
    select b.ticket_id, b.queue_key, b.chip, b.priority, b.created_at from vis b
     where (v_status = 'all' or b.chip = v_status)
       and (v_q is null or lower(b.display_no) like '%' || v_q || '%' or exists (select 1 from public.order_items i where i.kot_ticket_id = b.ticket_id and i.status <> 'cancelled'
              and public.kitchen_queue_key(v_org, i.station) = b.queue_key and position(v_q in lower(i.name)) > 0))
     order by (b.chip = 'served'), (b.priority = 'urgent') desc, b.created_at limit 100)
  select jsonb_build_object(
           'queue_critical', count(*) filter (where chip in ('new', 'in_progress') and priority = 'urgent'),
           'pending', count(*) filter (where chip in ('new', 'in_progress')),
           'dine_in', count(*) filter (where chip in ('new', 'in_progress') and channel = 'dine_in'),
           'online_delivery', count(*) filter (where chip in ('new', 'in_progress') and channel in ('delivery', 'online', 'swiggy', 'zomato')),
           'delayed', count(*) filter (where chip in ('new', 'in_progress') and created_at < now() - interval '15 minutes'),
           'completed_today', (select n from done)),
         jsonb_build_object('all', count(*), 'new', count(*) filter (where chip = 'new'), 'in_progress', count(*) filter (where chip = 'in_progress'),
           'ready', count(*) filter (where chip = 'ready'), 'served', count(*) filter (where chip = 'served')),
         coalesce((select jsonb_agg(public.kds_card_json(sh.ticket_id, sh.queue_key) order by (sh.chip = 'served'), (sh.priority = 'urgent') desc, sh.created_at) from shown sh), '[]'),
         -- chips: active stations, a station that was switched off but still has cards, and Unassigned when some card has no station
         coalesce((select jsonb_agg(jsonb_build_object('key', x.key, 'name', x.name) order by x.ord, x.name) from (
              select s.key, s.name, s.sort_order ord from public.pos_kitchen_stations s
               where s.organization_id = v_org and (s.active or s.key in (select queue_key from vis_all))
              union all select 'unassigned', 'Unassigned', 1000000 where exists (select 1 from vis_all where queue_key = 'unassigned')) x), '[]')
    into v_stats, v_counts, v_cards, v_chips from vis;
  return jsonb_build_object('live', (v_counts->>'all')::int, 'station', v_station, 'stats', v_stats, 'counts', v_counts, 'tickets', v_cards, 'stations', v_chips,
    'delayed_after_minutes', 15, 'can', jsonb_build_object('act', public.has_permission(v_org, 'order', 'update_status')),
    -- 0618: orders cancelled in the last hour after they reached the kitchen, so the KDS buzzes and says stop cooking
    'cancelled', public.kds_cancelled(v_org, v_loc));
end $$

;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0619_channel_delivery.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0619: delivery updates on online orders (founder, 29 Oct 2026). For an order in progress or out for delivery, the restaurant moves it on:
--   ready      the food is packed and waiting (OneLocal: accepted → packed; the kitchen's dishes are ready)
--   out        out for delivery, with the rider's name and number and how long it will take (OneLocal and phone orders; Swiggy and Zomato
--              riders are theirs)
--   delivered  handed to the customer, or for Swiggy / Zomato picked up by their rider
-- Each update is recorded on the order (order_events: the Activity log) and the online orders list shows it with the rider.
--   * pos_order_delivery: the delivery's stage, rider and time, one row per order
--   * rst_channel_delivery({order_id, step, rider_name?, rider_phone?, eta_minutes?})
--   * rst_channel_orders: stage follows the delivery; each order says 'delivery'
-- Safe to run again.

create table if not exists public.pos_order_delivery (
  order_id uuid primary key references public.orders(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  stage text not null check (stage in ('out', 'delivered')),
  rider_name text check (rider_name is null or char_length(rider_name) <= 60),
  rider_phone text check (rider_phone is null or rider_phone ~ '^[6-9][0-9]{9}$'),
  eta_minutes int check (eta_minutes is null or eta_minutes between 1 and 240),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.pos_order_delivery enable row level security;
revoke all on public.pos_order_delivery from public, anon, authenticated;

create or replace function public.rst_channel_delivery(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); o public.orders%rowtype; x public.ol_orders%rowtype; d public.pos_order_delivery%rowtype;
  v_step text := p->>'step'; v_src text; v_stage text; v_rider text := nullif(btrim(coalesce(p->>'rider_name', '')), '');
  v_phone text := nullif(regexp_replace(coalesce(p->>'rider_phone', ''), '\D', '', 'g'), ''); v_eta int := nullif(p->>'eta_minutes', '')::int; v_msg text;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_step is null or v_step not in ('ready', 'out', 'delivered') then raise exception 'POS_BAD_REQUEST: unknown step'; end if;
  select * into o from public.orders where id = nullif(p->>'order_id', '')::uuid and organization_id = v_org for update;
  if not found or not public.location_is_allowed(o.organization_id, o.location_id) then raise exception 'POS_NOT_FOUND: order not found'; end if;
  if not public.has_permission(v_org, 'order', 'update_status', o.location_id) then raise exception 'POS_FORBIDDEN: your role cannot update orders'; end if;
  select * into x from public.ol_orders where pos_order_id = o.id for update;
  select * into d from public.pos_order_delivery where order_id = o.id for update;
  v_src := case when x.id is not null or o.channel = 'online' then 'onelocal' when o.channel in ('swiggy', 'zomato') then o.channel when o.channel = 'delivery' then 'on_call' end;
  if v_src is null then raise exception 'POS_BAD_REQUEST: this is not an online or delivery order'; end if;
  if o.status = 'cancelled' or x.status = 'cancelled' then raise exception 'POS_WRONG_STATE: this order was cancelled'; end if;
  -- where it stands now, as the online orders list says it
  v_stage := case when d.stage = 'delivered' then 'delivered' when d.stage = 'out' then 'on_way'
                  when x.id is not null then case x.status when 'placed' then 'new' when 'accepted' then 'preparing' when 'packed' then 'ready' when 'out' then 'on_way' else 'delivered' end
                  else case o.status when 'new' then 'new' when 'in_billing' then 'new' when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready'
                                     when 'awaiting_payment' then 'on_way' else 'delivered' end end;
  if v_stage = 'new' then raise exception 'POS_WRONG_STATE: accept the order first'; end if;
  if v_stage = 'delivered' then raise exception 'POS_WRONG_STATE: this order is already delivered'; end if;
  if v_rider is not null and char_length(v_rider) > 60 then raise exception 'POS_BAD_REQUEST: the rider''s name is too long'; end if;
  if v_phone is not null then
    if length(v_phone) = 12 and left(v_phone, 2) = '91' then v_phone := right(v_phone, 10); end if;
    if v_phone !~ '^[6-9][0-9]{9}$' then raise exception 'POS_BAD_REQUEST: enter the rider''s 10-digit mobile number'; end if;
  end if;
  if v_eta is not null and (v_eta < 1 or v_eta > 240) then raise exception 'POS_BAD_REQUEST: give the time in minutes, 1 to 240'; end if;

  if v_step = 'ready' then
    if v_stage <> 'preparing' then raise exception 'POS_WRONG_STATE: only an order in the kitchen can be marked ready'; end if;
    if x.id is not null and x.status = 'accepted' then
      perform public.status_gate('ol_orders', x.id, 'kitchen_ready');
      update public.ol_orders set status = 'packed' where id = x.id;
    end if;
    v_msg := o.display_no || ' packed and ready' || case when v_src in ('swiggy', 'zomato') then ' for the rider' else '' end;
  elsif v_step = 'out' then
    if v_src in ('swiggy', 'zomato') then raise exception 'POS_BAD_REQUEST: % riders deliver % orders; mark it picked up instead', initcap(v_src), initcap(v_src); end if;
    if v_stage not in ('preparing', 'ready', 'on_way') then raise exception 'POS_WRONG_STATE: this order cannot go out now'; end if;
    if x.id is not null and x.status in ('accepted', 'packed') then
      perform public.status_gate('ol_orders', x.id, case x.status when 'packed' then 'hand_out' else 'delivery_sync_out' end);
      update public.ol_orders set status = 'out' where id = x.id;
    end if;
    insert into public.pos_order_delivery (order_id, organization_id, stage, rider_name, rider_phone, eta_minutes, updated_at, updated_by)
    values (o.id, v_org, 'out', v_rider, v_phone, v_eta, now(), auth.uid())
    on conflict (order_id) do update set stage = 'out', rider_name = coalesce(excluded.rider_name, pos_order_delivery.rider_name),
      rider_phone = coalesce(excluded.rider_phone, pos_order_delivery.rider_phone), eta_minutes = coalesce(excluded.eta_minutes, pos_order_delivery.eta_minutes),
      updated_at = now(), updated_by = auth.uid();
    v_msg := o.display_no || ' out for delivery' || coalesce(' with ' || v_rider, '') || coalesce(', about ' || v_eta || ' min', '');
  else
    if v_src in ('swiggy', 'zomato') and v_stage <> 'ready' then raise exception 'POS_WRONG_STATE: mark it ready first, then picked up by the rider'; end if;
    if x.id is not null and x.status in ('accepted', 'packed', 'out') then
      perform public.status_gate('ol_orders', x.id, case x.status when 'out' then 'delivered' else 'delivery_sync_delivered' end);
      update public.ol_orders set status = 'delivered' where id = x.id;
    end if;
    insert into public.pos_order_delivery (order_id, organization_id, stage, updated_at, updated_by) values (o.id, v_org, 'delivered', now(), auth.uid())
    on conflict (order_id) do update set stage = 'delivered', updated_at = now(), updated_by = auth.uid();
    v_msg := o.display_no || case when v_src in ('swiggy', 'zomato') then ' picked up by the ' || initcap(v_src) || ' rider' else ' delivered' end;
  end if;
  -- the kitchen's part is done once it is packed: its dishes are ready
  if o.status in ('new', 'in_billing', 'sent_to_kitchen') then
    update public.kot_tickets set status = 'ready', updated_at = now() where order_id = o.id and status in ('new', 'preparing');
    update public.order_items set status = 'ready' where order_id = o.id and status in ('pending', 'preparing');
    perform public.status_gate('orders', o.id, 'set_ready');
    update public.orders set status = 'ready', updated_at = now() where id = o.id;
  else
    update public.orders set updated_at = now() where id = o.id;
  end if;
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
  values (v_org, o.id, 'delivery_' || v_step, v_msg, 'pos', jsonb_build_object('by', auth.uid(), 'step', v_step, 'rider', v_rider, 'eta_minutes', v_eta));
  return jsonb_build_object('order_id', o.id, 'step', v_step, 'message', v_msg);
end $$;

revoke all on function public.rst_channel_delivery(jsonb) from public, anon;
grant execute on function public.rst_channel_delivery(jsonb) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rst_channel_orders(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(p->>'location_id', '')::uuid; v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.created_at, o.total, o.status as pos_status, o.external_ref, o.customer_phone,
             d.stage as dstage, d.rider_name, d.rider_phone, d.eta_minutes, d.updated_at as d_at,
             coalesce(nullif(o.customer_name, ''), 'Guest') as customer,
             case when x.id is not null or o.channel = 'online' then 'onelocal' when o.channel in ('swiggy', 'zomato') then o.channel
                  when o.channel = 'delivery' then 'on_call' end as source,
             case
               when o.status = 'cancelled' or x.status = 'cancelled' then 'cancelled'
               -- 0619: the restaurant's own delivery updates
               when d.stage = 'delivered' then 'delivered' when d.stage = 'out' then 'on_way'
               when x.id is not null then case x.status when 'placed' then 'new' when 'accepted' then 'preparing' when 'packed' then 'ready'
                                                        when 'out' then 'on_way' else 'delivered' end
               else case o.status when 'new' then 'new' when 'in_billing' then 'new' when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready'
                                  when 'awaiting_payment' then 'on_way' else 'delivered' end
             end as stage,
             (select string_agg(i.qty || ' × ' || i.name || coalesce(' (' || i.variant_name || ')', ''), ', ' order by i.created_at) from public.order_items i where i.order_id = o.id and i.status <> 'cancelled') as items
        from public.orders o
        left join public.ol_orders x on x.pos_order_id = o.id
        left join public.pos_order_delivery d on d.order_id = o.id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc)
         and o.created_at >= v_since
         and (x.id is not null or o.channel in ('online', 'swiggy', 'zomato', 'delivery'))
    ), s(key, label, sort) as (values ('onelocal', 'OneLocal', 1), ('swiggy', 'Swiggy', 2), ('zomato', 'Zomato', 3), ('on_call', 'On call delivery', 4))
    select jsonb_build_object(
      'channels', (select jsonb_agg(jsonb_build_object(
          'key', s.key, 'label', s.label,
          'count', (select count(*) from o where o.source = s.key and o.stage <> 'cancelled'),
          'open', (select count(*) from o where o.source = s.key and o.stage not in ('cancelled', 'delivered')),
          'new', (select count(*) from o where o.source = s.key and o.stage = 'new'),
          'total', (select coalesce(sum(o.total), 0) from o where o.source = s.key and o.stage <> 'cancelled'),
          'names', (select coalesce(jsonb_agg(n.customer), '[]') from (select o.customer from o where o.source = s.key and o.stage <> 'cancelled' order by o.created_at desc limit 3) n)
        ) order by s.sort) from s),
      'accept_window', coalesce((select c.accept_window_seconds from public.ol_merchant_channels c where c.organization_id = v_org), 60),
      'auto_accept', coalesce((select c.auto_accept from public.ol_merchant_channels c where c.organization_id = v_org), false),
      'cancelled', (select count(*) from o where o.stage = 'cancelled' and o.source is not null),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', o.id, 'display_no', o.display_no, 'placed_at', o.created_at, 'customer', o.customer, 'phone', o.customer_phone,
          'total', o.total, 'source', o.source, 'stage', o.stage, 'items', coalesce(o.items, ''),
          'ref', nullif(regexp_replace(coalesce(o.external_ref, ''), '^[a-z]+:', ''), ''),
          'delivery', case when o.dstage is null then null else jsonb_build_object('stage', o.dstage, 'rider_name', o.rider_name, 'rider_phone', o.rider_phone, 'eta_minutes', o.eta_minutes, 'at', o.d_at) end
        ) order by case o.stage when 'new' then 0 when 'preparing' then 1 when 'ready' then 2 when 'on_way' then 3 else 4 end, o.created_at desc), '[]')
        from o where o.source is not null and o.stage <> 'cancelled')
    )
  );
end $$

;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0620_delivery_completes.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0620: Delivered completes an online order (founder, 29 Oct 2026: "check the complete order process"). Before this, a delivered order
-- stayed open on the POS side: no payment, no paid time, so it still counted as live, stayed in the KOT view and never reached Sales.
-- Now the Delivered / Picked up step records what is still due and closes the order (and its KOTs):
--   Swiggy / Zomato   settled by the aggregator (method other, reference Swiggy / Zomato)
--   OneLocal, paid    paid in the app (method other, reference OneLocal app) when its online payment is not on the order yet
--   at the door       cash, UPI or card, which the restaurant chooses (asked when anything is due: POS_PAYMENT_NEEDED)
-- An order already paid in full is simply closed. rst_channel_orders says each order's 'due' and 'prepaid'.
-- Safe to run again.

create or replace function public.rst_channel_delivery(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); o public.orders%rowtype; x public.ol_orders%rowtype; d public.pos_order_delivery%rowtype;
  v_step text := p->>'step'; v_src text; v_stage text; v_rider text := nullif(btrim(coalesce(p->>'rider_name', '')), '');
  v_phone text := nullif(regexp_replace(coalesce(p->>'rider_phone', ''), '\D', '', 'g'), ''); v_eta int := nullif(p->>'eta_minutes', '')::int; v_msg text;
  v_pay text := nullif(p->>'payment_method', ''); v_paid numeric; v_due numeric := 0; v_prepaid boolean;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_step is null or v_step not in ('ready', 'out', 'delivered') then raise exception 'POS_BAD_REQUEST: unknown step'; end if;
  select * into o from public.orders where id = nullif(p->>'order_id', '')::uuid and organization_id = v_org for update;
  if not found or not public.location_is_allowed(o.organization_id, o.location_id) then raise exception 'POS_NOT_FOUND: order not found'; end if;
  if not public.has_permission(v_org, 'order', 'update_status', o.location_id) then raise exception 'POS_FORBIDDEN: your role cannot update orders'; end if;
  select * into x from public.ol_orders where pos_order_id = o.id for update;
  select * into d from public.pos_order_delivery where order_id = o.id for update;
  v_src := case when x.id is not null or o.channel = 'online' then 'onelocal' when o.channel in ('swiggy', 'zomato') then o.channel when o.channel = 'delivery' then 'on_call' end;
  if v_src is null then raise exception 'POS_BAD_REQUEST: this is not an online or delivery order'; end if;
  if o.status = 'cancelled' or x.status = 'cancelled' then raise exception 'POS_WRONG_STATE: this order was cancelled'; end if;
  -- where it stands now, as the online orders list says it
  v_stage := case when d.stage = 'delivered' then 'delivered' when d.stage = 'out' then 'on_way'
                  when x.id is not null then case x.status when 'placed' then 'new' when 'accepted' then 'preparing' when 'packed' then 'ready' when 'out' then 'on_way' else 'delivered' end
                  else case o.status when 'new' then 'new' when 'in_billing' then 'new' when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready'
                                     when 'awaiting_payment' then 'on_way' else 'delivered' end end;
  if v_stage = 'new' then raise exception 'POS_WRONG_STATE: accept the order first'; end if;
  if v_stage = 'delivered' then raise exception 'POS_WRONG_STATE: this order is already delivered'; end if;
  if v_rider is not null and char_length(v_rider) > 60 then raise exception 'POS_BAD_REQUEST: the rider''s name is too long'; end if;
  if v_phone is not null then
    if length(v_phone) = 12 and left(v_phone, 2) = '91' then v_phone := right(v_phone, 10); end if;
    if v_phone !~ '^[6-9][0-9]{9}$' then raise exception 'POS_BAD_REQUEST: enter the rider''s 10-digit mobile number'; end if;
  end if;
  if v_eta is not null and (v_eta < 1 or v_eta > 240) then raise exception 'POS_BAD_REQUEST: give the time in minutes, 1 to 240'; end if;

  if v_step = 'ready' then
    if v_stage <> 'preparing' then raise exception 'POS_WRONG_STATE: only an order in the kitchen can be marked ready'; end if;
    if x.id is not null and x.status = 'accepted' then
      perform public.status_gate('ol_orders', x.id, 'kitchen_ready');
      update public.ol_orders set status = 'packed' where id = x.id;
    end if;
    v_msg := o.display_no || ' packed and ready' || case when v_src in ('swiggy', 'zomato') then ' for the rider' else '' end;
  elsif v_step = 'out' then
    if v_src in ('swiggy', 'zomato') then raise exception 'POS_BAD_REQUEST: % riders deliver % orders; mark it picked up instead', initcap(v_src), initcap(v_src); end if;
    if v_stage not in ('preparing', 'ready', 'on_way') then raise exception 'POS_WRONG_STATE: this order cannot go out now'; end if;
    if x.id is not null and x.status in ('accepted', 'packed') then
      perform public.status_gate('ol_orders', x.id, case x.status when 'packed' then 'hand_out' else 'delivery_sync_out' end);
      update public.ol_orders set status = 'out' where id = x.id;
    end if;
    insert into public.pos_order_delivery (order_id, organization_id, stage, rider_name, rider_phone, eta_minutes, updated_at, updated_by)
    values (o.id, v_org, 'out', v_rider, v_phone, v_eta, now(), auth.uid())
    on conflict (order_id) do update set stage = 'out', rider_name = coalesce(excluded.rider_name, pos_order_delivery.rider_name),
      rider_phone = coalesce(excluded.rider_phone, pos_order_delivery.rider_phone), eta_minutes = coalesce(excluded.eta_minutes, pos_order_delivery.eta_minutes),
      updated_at = now(), updated_by = auth.uid();
    v_msg := o.display_no || ' out for delivery' || coalesce(' with ' || v_rider, '') || coalesce(', about ' || v_eta || ' min', '');
  else
    if v_src in ('swiggy', 'zomato') and v_stage <> 'ready' then raise exception 'POS_WRONG_STATE: mark it ready first, then picked up by the rider'; end if;
    -- 0620: delivered completes the order. What is still due is paid: by the aggregator (Swiggy / Zomato), already in the app (OneLocal paid
    -- online), or collected at the door, which the restaurant says (cash, UPI or card)
    select coalesce(sum(amount), 0) into v_paid from public.payments where order_id = o.id;
    v_due := greatest(o.total - v_paid, 0);
    v_prepaid := x.id is not null and x.payment_status = 'paid' and coalesce(x.payment_method, '') <> 'cod';
    if v_due > 0.005 and v_src not in ('swiggy', 'zomato') and not v_prepaid then
      if v_pay is null then raise exception 'POS_PAYMENT_NEEDED: ₹% to collect: was it paid by cash, UPI or card?', v_due; end if;
      if v_pay not in ('cash', 'upi', 'card') then raise exception 'POS_BAD_REQUEST: paid by cash, UPI or card'; end if;
    end if;
    if x.id is not null and x.status in ('accepted', 'packed', 'out') then
      perform public.status_gate('ol_orders', x.id, case x.status when 'out' then 'delivered' else 'delivery_sync_delivered' end);
      update public.ol_orders set status = 'delivered' where id = x.id;
    end if;
    insert into public.pos_order_delivery (order_id, organization_id, stage, updated_at, updated_by) values (o.id, v_org, 'delivered', now(), auth.uid())
    on conflict (order_id) do update set stage = 'delivered', updated_at = now(), updated_by = auth.uid();
    v_msg := o.display_no || case when v_src in ('swiggy', 'zomato') then ' picked up by the ' || initcap(v_src) || ' rider' else ' delivered' end;
    if v_due > 0.005 and v_pay is not null and v_src not in ('swiggy', 'zomato') and not v_prepaid then
      v_msg := v_msg || ', ₹' || trim(to_char(v_due, 'FM999999990.00')) || ' collected by ' || case v_pay when 'upi' then 'UPI' else v_pay end;
    end if;
  end if;
  -- the kitchen's part is done once it is packed: its dishes are ready
  if o.status in ('new', 'in_billing', 'sent_to_kitchen') then
    update public.kot_tickets set status = 'ready', updated_at = now() where order_id = o.id and status in ('new', 'preparing');
    update public.order_items set status = 'ready' where order_id = o.id and status in ('pending', 'preparing');
    perform public.status_gate('orders', o.id, 'set_ready');
    update public.orders set status = 'ready', updated_at = now() where id = o.id;
  else
    update public.orders set updated_at = now() where id = o.id;
  end if;
  -- 0620: delivered = done: the payment is recorded (that closes the order and its KOTs), or an order already paid is closed
  if v_step = 'delivered' then
    if v_due > 0.005 then
      perform public.pos_record_payment(jsonb_build_object('order_id', o.id, 'amount', v_due,
        'method', case when v_src in ('swiggy', 'zomato') or v_prepaid then 'other' else v_pay end,
        'reference', case when v_src in ('swiggy', 'zomato') then initcap(v_src) when v_prepaid then 'OneLocal app' end,
        'idempotency_key', 'delivered:' || o.id));
    elsif (select status from public.orders where id = o.id) not in ('paid', 'cancelled') then
      perform public.status_gate('orders', o.id, 'set_paid');
      update public.orders set status = 'paid', paid_at = coalesce(paid_at, now()), updated_at = now() where id = o.id;
      update public.kot_tickets set status = 'delivered', updated_at = now() where order_id = o.id and status <> 'delivered';
    end if;
  end if;
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
  values (v_org, o.id, 'delivery_' || v_step, v_msg, 'pos', jsonb_build_object('by', auth.uid(), 'step', v_step, 'rider', v_rider, 'eta_minutes', v_eta));
  return jsonb_build_object('order_id', o.id, 'step', v_step, 'message', v_msg);
end $$;

revoke all on function public.rst_channel_delivery(jsonb) from public, anon;
grant execute on function public.rst_channel_delivery(jsonb) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rst_channel_orders(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(p->>'location_id', '')::uuid; v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_loc is not null and (not exists (select 1 from public.locations l where l.id = v_loc and l.organization_id = v_org) or not public.location_is_allowed(v_org, v_loc)) then
    raise exception 'POS_NOT_FOUND: outlet not found'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.created_at, o.total, o.status as pos_status, o.external_ref, o.customer_phone,
             d.stage as dstage, d.rider_name, d.rider_phone, d.eta_minutes, d.updated_at as d_at,
             greatest(o.total - (select coalesce(sum(pm.amount), 0) from public.payments pm where pm.order_id = o.id), 0) as due,
             (x.id is not null and x.payment_status = 'paid' and coalesce(x.payment_method, '') <> 'cod') as prepaid,
             coalesce(nullif(o.customer_name, ''), 'Guest') as customer,
             case when x.id is not null or o.channel = 'online' then 'onelocal' when o.channel in ('swiggy', 'zomato') then o.channel
                  when o.channel = 'delivery' then 'on_call' end as source,
             case
               when o.status = 'cancelled' or x.status = 'cancelled' then 'cancelled'
               -- 0619: the restaurant's own delivery updates
               when d.stage = 'delivered' then 'delivered' when d.stage = 'out' then 'on_way'
               when x.id is not null then case x.status when 'placed' then 'new' when 'accepted' then 'preparing' when 'packed' then 'ready'
                                                        when 'out' then 'on_way' else 'delivered' end
               else case o.status when 'new' then 'new' when 'in_billing' then 'new' when 'sent_to_kitchen' then 'preparing' when 'ready' then 'ready'
                                  when 'awaiting_payment' then 'on_way' else 'delivered' end
             end as stage,
             (select string_agg(i.qty || ' × ' || i.name || coalesce(' (' || i.variant_name || ')', ''), ', ' order by i.created_at) from public.order_items i where i.order_id = o.id and i.status <> 'cancelled') as items
        from public.orders o
        left join public.ol_orders x on x.pos_order_id = o.id
        left join public.pos_order_delivery d on d.order_id = o.id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc)
         and o.created_at >= v_since
         and (x.id is not null or o.channel in ('online', 'swiggy', 'zomato', 'delivery'))
    ), s(key, label, sort) as (values ('onelocal', 'OneLocal', 1), ('swiggy', 'Swiggy', 2), ('zomato', 'Zomato', 3), ('on_call', 'On call delivery', 4))
    select jsonb_build_object(
      'channels', (select jsonb_agg(jsonb_build_object(
          'key', s.key, 'label', s.label,
          'count', (select count(*) from o where o.source = s.key and o.stage <> 'cancelled'),
          'open', (select count(*) from o where o.source = s.key and o.stage not in ('cancelled', 'delivered')),
          'new', (select count(*) from o where o.source = s.key and o.stage = 'new'),
          'total', (select coalesce(sum(o.total), 0) from o where o.source = s.key and o.stage <> 'cancelled'),
          'names', (select coalesce(jsonb_agg(n.customer), '[]') from (select o.customer from o where o.source = s.key and o.stage <> 'cancelled' order by o.created_at desc limit 3) n)
        ) order by s.sort) from s),
      'accept_window', coalesce((select c.accept_window_seconds from public.ol_merchant_channels c where c.organization_id = v_org), 60),
      'auto_accept', coalesce((select c.auto_accept from public.ol_merchant_channels c where c.organization_id = v_org), false),
      'cancelled', (select count(*) from o where o.stage = 'cancelled' and o.source is not null),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', o.id, 'display_no', o.display_no, 'placed_at', o.created_at, 'customer', o.customer, 'phone', o.customer_phone,
          'total', o.total, 'source', o.source, 'stage', o.stage, 'items', coalesce(o.items, ''),
          'ref', nullif(regexp_replace(coalesce(o.external_ref, ''), '^[a-z]+:', ''), ''),
          'delivery', case when o.dstage is null then null else jsonb_build_object('stage', o.dstage, 'rider_name', o.rider_name, 'rider_phone', o.rider_phone, 'eta_minutes', o.eta_minutes, 'at', o.d_at) end,
          -- 0620: what is still to collect (0 once paid), and whether the customer paid in the app
          'due', o.due, 'prepaid', o.prepaid
        ) order by case o.stage when 'new' then 0 when 'preparing' then 1 when 'ready' then 2 when 'on_way' then 3 else 4 end, o.created_at desc), '[]')
        from o where o.source is not null and o.stage <> 'cancelled')
    )
  );
end $$

;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0621_kot_shows_cancels.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0621: an order cancelled while the kitchen has it shows on the KDS and on the KOT view (founder, 29 Oct 2026). The KOT view used to drop
-- a cancelled order without a word, and the KDS alert (0618) did not say who cancelled or why.
--   * order_cancel_info(order): who cancelled (Customer / Restaurant / Swiggy / Zomato / OneLocal) and the reason
--   * kds_cancelled: + 'by', 'reason'
--   * rst_kot_orders: today's cancelled kitchen orders stay, stage 'cancelled' with 'cancel' {by, reason, at}; a 'cancelled' count and
--     filter; one cancelled in the last hour comes first
-- Read only. Safe to run again.

create or replace function public.order_cancel_info(p_order uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  with o as (select o.id, o.channel from public.orders o where o.id = p_order),
  ol as (select ol.id, ol.user_id, ol.cancelled_by, ol.cancel_reason from public.ol_orders ol join o on ol.pos_order_id = o.id limit 1),
  oc as (select c.initiated_by, c.reason from public.order_cancellations c join ol on c.ol_order_id = ol.id limit 1),
  ev as (select e.meta->>'reason' as reason from public.order_events e join o on e.order_id = o.id
          where e.kind = 'status_cancelled' order by e.created_at desc limit 1)
  select jsonb_build_object(
    'by', case
            when exists (select 1 from ev) then 'Restaurant'
            when (select initiated_by from oc) = 'customer' or ((select cancelled_by from ol) is not null and (select cancelled_by from ol) = (select user_id from ol)) then 'Customer'
            when (select initiated_by from oc) = 'restaurant' then 'Restaurant'
            when exists (select 1 from ol) then 'OneLocal'
            when (select channel from o) = 'swiggy' then 'Swiggy'
            when (select channel from o) = 'zomato' then 'Zomato'
            else 'Restaurant' end,
    'reason', coalesce(nullif(btrim((select reason from ev)), ''), nullif(btrim((select reason from oc)), ''), nullif(btrim((select cancel_reason from ol)), '')))
$$;
revoke all on function public.order_cancel_info(uuid) from public, anon;

create or replace function public.kds_cancelled(p_org uuid, p_loc uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'order_id', o.id, 'display_no', o.display_no, 'channel', o.channel, 'at', o.updated_at,
           'table_label', (select d.label from public.dining_tables d where d.id = o.table_id),
           'kots', (select jsonb_agg(k.kot_no order by k.kot_no) from public.kot_tickets k where k.order_id = o.id),
           'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'qty', i.qty, 'variant', i.variant_name) order by i.created_at), '[]'::jsonb)
                       from public.order_items i where i.order_id = o.id and i.kot_ticket_id is not null))
         || public.order_cancel_info(o.id)
         order by o.updated_at desc), '[]'::jsonb)
    from public.orders o
   where o.organization_id = p_org and o.status = 'cancelled' and o.updated_at > now() - interval '60 minutes'
     and (p_loc is null or o.location_id = p_loc)
     and exists (select 1 from public.kot_tickets k where k.order_id = o.id)
$$;
revoke all on function public.kds_cancelled(uuid, uuid) from public, anon;

CREATE OR REPLACE FUNCTION public.rst_kot_orders(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.current_org_id(); v_loc uuid := nullif(nullif(p->>'location_id', ''), 'all')::uuid;
  v_st text := coalesce(nullif(p->>'status', ''), 'all'); v_tz text; v_since timestamptz;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_st not in ('all', 'preparing', 'ready', 'completed', 'cancelled') then raise exception 'POS_BAD_REQUEST: unknown status'; end if;
  select coalesce(l.timezone, 'Asia/Kolkata') into v_tz from public.locations l
   where l.organization_id = v_org and (v_loc is null or l.id = v_loc) order by (l.code = 'MAIN') desc, l.created_at limit 1;
  v_since := date_trunc('day', now() at time zone coalesce(v_tz, 'Asia/Kolkata')) at time zone coalesce(v_tz, 'Asia/Kolkata');

  return (
    with o as materialized (
      select o.id, o.display_no, o.total, o.status, o.channel, o.created_at, o.updated_at, o.paid_at, o.table_id, o.captain_name,
             t.label as table_label,
             -- a cancelled order counts the dishes the kitchen had (all of them are cancelled now)
             (select count(*) from public.order_items i where i.order_id = o.id and (i.status <> 'cancelled' or (o.status = 'cancelled' and i.kot_ticket_id is not null))) as items,
             (select count(*) from public.order_items i where i.order_id = o.id and (i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered')))) as ready,
             (select count(*) from public.order_items i where i.order_id = o.id and i.status = 'pending' and i.started_at is null) as untouched
        from public.orders o left join public.dining_tables t on t.id = o.table_id
       where o.organization_id = v_org and public.location_is_allowed(o.organization_id, o.location_id)
         and (v_loc is null or o.location_id = v_loc) and o.created_at >= v_since
         and exists (select 1 from public.kot_tickets k where k.order_id = o.id)
    ), s as (
      select o.*,
             case when o.status = 'cancelled' then 'cancelled'
                  when o.paid_at is not null or o.status in ('paid', 'delivered') then 'completed'
                  when o.items > 0 and o.ready = o.items then 'ready'
                  when o.untouched = o.items then 'new' else 'preparing' end as stage,
             o.status = 'cancelled' and o.updated_at > now() - interval '60 minutes' as fresh_cancel
        from o
    )
    select jsonb_build_object(
      'counts', jsonb_build_object('all', (select count(*) from s), 'preparing', (select count(*) from s where stage in ('new', 'preparing')),
                                   'ready', (select count(*) from s where stage = 'ready'), 'completed', (select count(*) from s where stage = 'completed'),
                                   'cancelled', (select count(*) from s where stage = 'cancelled')),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', s.id, 'display_no', s.display_no, 'total', s.total, 'stage', s.stage, 'channel', s.channel, 'table_id', s.table_id, 'table_label', s.table_label,
          'moved', public.order_table_move(s.id),
          'captain', s.captain_name, 'paid', s.paid_at is not null, 'created_at', s.created_at,
          'minutes', floor(extract(epoch from (now() - s.created_at)) / 60)::int, 'items', s.items, 'ready', s.ready,
          'cancel', case when s.stage = 'cancelled' then public.order_cancel_info(s.id) || jsonb_build_object('at', s.updated_at, 'recent', s.fresh_cancel) end,
          'dishes', case when s.stage = 'cancelled' then (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'qty', i.qty) order by i.created_at), '[]')
                                                          from public.order_items i where i.order_id = s.id and i.kot_ticket_id is not null) end,
          'kots', (select jsonb_agg(jsonb_build_object('id', k.id, 'kot_no', k.kot_no, 'status', k.status,
                      'items', (select count(*) from public.order_items i where i.kot_ticket_id = k.id and (i.status <> 'cancelled' or s.stage = 'cancelled')),
                      'ready', (select count(*) from public.order_items i where i.kot_ticket_id = k.id and (i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered'))))) order by k.kot_no)
                   from public.kot_tickets k where k.order_id = s.id),
          'stations', (select coalesce(jsonb_agg(jsonb_build_object('name', public.tbl_station_label(v_org, x.station), 'done', x.done) order by x.station), '[]')
                         from (select i.station, bool_and((i.status in ('ready', 'delivered') or exists (select 1 from public.kot_tickets kk where kk.id = i.kot_ticket_id and kk.status in ('ready', 'delivered')))) as done from public.order_items i
                                where i.order_id = s.id and i.status <> 'cancelled' group by i.station) x),
          'ready_item_ids', (select coalesce(jsonb_agg(i.id), '[]') from public.order_items i where i.order_id = s.id and i.status = 'ready'),
          'latest_ticket', (select k.id from public.kot_tickets k where k.order_id = s.id order by k.kot_no desc limit 1)
        ) order by case when s.fresh_cancel then -1 else case s.stage when 'ready' then 0 when 'preparing' then 1 when 'new' then 2 when 'completed' then 3 else 4 end end, s.created_at desc), '[]')
        from s where v_st = 'all' or (v_st = 'preparing' and s.stage in ('new', 'preparing')) or s.stage = v_st)
    )
  );
end $$;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0622_restaurant_money.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0622: restaurant Money in the store's design (founder, 29 Oct 2026: "keep money built like this for restaurant POS", rebuilt here rather
-- than merged). One ledger over what the restaurant already records — bill payments, refunds, expenses, cash entries, people given / got,
-- supplier invoice payments — plus its own manual entries, so the screens show:
--   * the wallet balance: the cash drawer, UPI and bank (card counts as bank), each = money in − money out + moves between them
--   * Money in / Money out lists by date and method; Add money / Pay money; Transfer to a contact (UPI app or card); move between accounts
--   * the day's cash register (opening, cash sales, other cash in, refunds, paid out, should be in the drawer) and Close day with the count
--   * dues: bills put on credit to collect, supplier invoices to pay
-- New: rmoney_entries, rmoney_contacts, rmoney_day_closes; rmoney_ledger(); rmoney_home, rmoney_entries_list, rmoney_record, rmoney_void,
-- rmoney_register, rmoney_close_day, rmoney_dues, rmoney_contacts_list, rmoney_contact_save. Safe to run again.

create table if not exists public.rmoney_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  location_id uuid references public.locations(id) on delete set null,
  entry_no text not null,
  direction text not null check (direction in ('in', 'out', 'move')),
  kind text not null check (char_length(kind) between 1 and 40),
  category text check (category is null or char_length(category) <= 60),
  method text check (method is null or method in ('cash', 'upi', 'gpay', 'phonepe', 'card', 'bank')),
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 100000000000),
  party text check (party is null or char_length(party) <= 60),
  party_phone text check (party_phone is null or char_length(party_phone) <= 20),
  reference text check (reference is null or char_length(reference) <= 60),
  note text check (note is null or char_length(note) <= 300),
  from_account text check (from_account is null or from_account in ('cash', 'upi', 'bank')),
  to_account text check (to_account is null or to_account in ('cash', 'upi', 'bank')),
  entry_date date not null,
  status text not null default 'posted' check (status in ('posted', 'voided')),
  void_reason text,
  created_by uuid,
  created_at timestamptz not null default now(),
  idempotency_key text not null,
  unique (organization_id, idempotency_key),
  check ((direction = 'move') = (from_account is not null and to_account is not null and from_account <> to_account and method is null)),
  check (direction = 'move' or method is not null)
);
create index if not exists rmoney_entries_org_day on public.rmoney_entries (organization_id, entry_date);
alter table public.rmoney_entries enable row level security;
revoke all on public.rmoney_entries from anon, authenticated;

create table if not exists public.rmoney_contacts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  phone text not null default '' check (char_length(phone) <= 20),
  upi_id text not null default '' check (upi_id = '' or upi_id ~ '^[A-Za-z0-9._-]{2,200}@[A-Za-z0-9.-]{2,64}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists rmoney_contacts_name on public.rmoney_contacts (organization_id, lower(name));
alter table public.rmoney_contacts enable row level security;
revoke all on public.rmoney_contacts from anon, authenticated;

create table if not exists public.rmoney_day_closes (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete cascade,
  day date not null,
  expected_minor bigint not null,
  counted_minor bigint not null check (counted_minor >= 0),
  created_by uuid,
  created_at timestamptz not null default now(),
  primary key (organization_id, location_id, day)
);
alter table public.rmoney_day_closes enable row level security;
revoke all on public.rmoney_day_closes from anon, authenticated;

-- which of the three accounts a method lands in; other ways (aggregator, OneLocal app, wallet, credit) are not the restaurant's money in hand
create or replace function public.rmoney_account(p_method text) returns text
language sql immutable as $$
  select case when p_method = 'cash' then 'cash' when p_method in ('upi', 'gpay', 'phonepe') then 'upi' when p_method in ('card', 'bank') then 'bank' end
$$;

-- every money row of the outlets in p_locs (voided rows left out); moves between accounts come as two rows, one out of the source and one in
-- to the target, with kind 'transfer' (the lists skip them)
create or replace function public.rmoney_ledger(p_org uuid, p_locs uuid[])
returns table (id uuid, source text, kind text, title text, direction text, method text, account text, amount_minor bigint, day date, at timestamptz,
               party text, note text, reference text, voidable boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  with tz as (select public.money_tz() as z)
  select x.id, 'sale', 'sales', 'Sales · ' || coalesce(o.display_no, 'ORD-' || o.order_no), 'in', case when x.method = 'other' then 'online' else x.method end,
         public.rmoney_account(x.method), x.amount_minor, (x.created_at at time zone (select z from tz))::date, x.created_at,
         nullif(btrim(coalesce(o.customer_name, '')), ''), null, o.display_no, false
    from public.payments x join public.orders o on o.id = x.order_id
   where x.organization_id = p_org and (o.location_id = any (p_locs) or o.location_id is null) and x.method <> 'due'
  union all
  select r.id, 'refund', 'refund', 'Refund · ' || coalesce(o.display_no, '') , 'out', r.method, public.rmoney_account(r.method), r.amount_minor,
         (r.created_at at time zone (select z from tz))::date, r.created_at, nullif(btrim(coalesce(o.customer_name, '')), ''), r.reason, o.display_no, false
    from public.pos_refunds r join public.orders o on o.id = r.order_id
   where r.organization_id = p_org and (coalesce(r.location_id, o.location_id) = any (p_locs) or coalesce(r.location_id, o.location_id) is null)
  union all
  select e.id, 'expense', 'expense', e.title, 'out', e.method, public.rmoney_account(e.method), e.amount_minor, e.expense_date, e.created_at, null, e.note, e.expense_no, false
    from public.money_expenses e where e.organization_id = p_org and e.location_id = any (p_locs) and e.status <> 'voided'
  union all
  select c.id, 'cash', case c.direction when 'in' then 'other_in' else 'other_out' end, c.title, c.direction, 'cash', 'cash', c.amount_minor, c.entry_date, c.created_at,
         null, c.note, c.entry_no, false
    from public.money_cash_entries c where c.organization_id = p_org and c.location_id = any (p_locs) and c.source = 'manual' and c.status = 'posted'
  union all
  select y.id, 'party', case y.direction when 'gave' then 'other_out' else 'other_in' end,
         case y.direction when 'gave' then 'Given to ' else 'Received from ' end || y.party_name, case y.direction when 'gave' then 'out' else 'in' end,
         y.method, public.rmoney_account(y.method), y.amount_minor, y.entry_date, y.created_at, y.party_name, y.note, y.entry_no, false
    from public.money_party_entries y where y.organization_id = p_org and y.location_id = any (p_locs)
  union all
  select s.id, 'supplier', 'supplier_payment', 'Supplier payment · ' || i.supplier_name, 'out', s.method, public.rmoney_account(s.method), s.amount_minor, s.paid_on,
         s.created_at, i.supplier_name, s.note, i.invoice_no, false
    from public.supplier_invoice_payments s join public.supplier_invoices i on i.id = s.invoice_id
   where s.organization_id = p_org and (i.location_id = any (p_locs) or i.location_id is null)
  union all
  select m.id, 'manual', m.kind, coalesce(nullif(m.category, ''), m.kind), m.direction, m.method, public.rmoney_account(m.method), m.amount_minor, m.entry_date,
         m.created_at, m.party, m.note, m.reference, true
    from public.rmoney_entries m where m.organization_id = p_org and (m.location_id = any (p_locs) or m.location_id is null) and m.status = 'posted' and m.direction <> 'move'
  union all
  select m.id, 'manual', 'transfer', 'Account transfer', 'out', null, m.from_account, m.amount_minor, m.entry_date, m.created_at, null, m.note, m.entry_no, true
    from public.rmoney_entries m where m.organization_id = p_org and (m.location_id = any (p_locs) or m.location_id is null) and m.status = 'posted' and m.direction = 'move'
  union all
  select m.id, 'manual', 'transfer', 'Account transfer', 'in', null, m.to_account, m.amount_minor, m.entry_date, m.created_at, null, m.note, m.entry_no, true
    from public.rmoney_entries m where m.organization_id = p_org and (m.location_id = any (p_locs) or m.location_id is null) and m.status = 'posted' and m.direction = 'move'
$$;
revoke all on function public.rmoney_ledger(uuid, uuid[]) from public, anon, authenticated;

create or replace function public.rmoney_home(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p); v_acc jsonb;
begin
  select jsonb_agg(jsonb_build_object('key', a.k, 'name', a.n, 'balance_minor', coalesce(b.bal, 0)) order by a.o) into v_acc
    from (values ('cash', 'Cash drawer', 1), ('upi', 'UPI', 2), ('bank', 'Bank', 3)) a(k, n, o)
    left join (select l.account, sum(case l.direction when 'in' then l.amount_minor else -l.amount_minor end) bal
                 from public.rmoney_ledger(v_org, v_locs) l where l.account is not null group by l.account) b on b.account = a.k;
  return jsonb_build_object('accounts', v_acc, 'total_minor', (select coalesce(sum((x->>'balance_minor')::bigint), 0) from jsonb_array_elements(v_acc) x),
    'can_record', public.has_permission(v_org, 'money', 'record', null), 'can_void', public.has_permission(v_org, 'money', 'approve', null),
    'today', (now() at time zone public.money_tz())::date, 'snapshot_at', now());
end $$;

-- Money in or Money out between two days, by method (all | cash | upi | card)
create or replace function public.rmoney_entries_list(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p); v_tz text := public.money_tz();
  v_dir text := coalesce(nullif(p->>'direction', ''), 'in'); v_method text := coalesce(nullif(p->>'method', ''), 'all');
  v_to date := coalesce(nullif(p->>'to', '')::date, (now() at time zone v_tz)::date); v_from date := coalesce(nullif(p->>'from', '')::date, v_to);
  v_rows jsonb; v_total bigint; v_n int;
begin
  if v_dir not in ('in', 'out') then raise exception 'MONEY_BAD_REQUEST: choose money in or money out'; end if;
  if v_method not in ('all', 'cash', 'upi', 'card') then raise exception 'MONEY_BAD_REQUEST: unknown payment method'; end if;
  if v_from > v_to or v_to - v_from > 366 then raise exception 'MONEY_BAD_REQUEST: choose up to a year'; end if;
  with f as (
    select l.* from public.rmoney_ledger(v_org, v_locs) l
     where l.direction = v_dir and l.kind <> 'transfer' and l.day between v_from and v_to
       and (v_method = 'all' or (v_method = 'cash' and l.method = 'cash') or (v_method = 'upi' and l.method in ('upi', 'gpay', 'phonepe'))
            or (v_method = 'card' and l.method = 'card')))
  select coalesce(sum(amount_minor), 0), count(*),
         coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'source', g.source, 'kind', g.kind, 'title', g.title, 'direction', g.direction, 'method', g.method,
                    'amount_minor', g.amount_minor, 'day', g.day, 'at', g.at, 'party', g.party, 'note', g.note, 'reference', g.reference, 'voidable', g.voidable)
                    order by g.at desc, g.id) from (select * from f order by at desc, id limit 300) g), '[]'::jsonb)
    into v_total, v_n, v_rows from f;
  return jsonb_build_object('from', v_from, 'to', v_to, 'direction', v_dir, 'method', v_method, 'total_minor', v_total, 'count', v_n, 'rows', v_rows,
    'can_record', public.has_permission(v_org, 'money', 'record', null), 'can_void', public.has_permission(v_org, 'money', 'approve', null), 'snapshot_at', now());
end $$;

-- Add money, Pay money, Transfer to a contact, move between accounts, collect a due
create or replace function public.rmoney_record(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'record'); v_key text := public.money_key(p); v_locs uuid[] := public.money_scope(v_org, p);
  v_dir text := coalesce(p->>'direction', ''); v_kind text := nullif(btrim(coalesce(p->>'kind', '')), '');
  v_method text := nullif(p->>'method', ''); v_amt bigint := public.money_amount(p, false); v_tz text := public.money_tz();
  v_day date := coalesce(nullif(p->>'entry_date', '')::date, (now() at time zone v_tz)::date);
  v_party text := nullif(btrim(coalesce(p->>'party', '')), ''); v_phone text := nullif(btrim(coalesce(p->>'party_phone', '')), '');
  v_from text := nullif(p->>'from_account', ''); v_to text := nullif(p->>'to_account', ''); e public.rmoney_entries;
begin
  select * into e from public.rmoney_entries where organization_id = v_org and idempotency_key = v_key;
  if found then return to_jsonb(e) || jsonb_build_object('replayed', true); end if;
  if v_dir not in ('in', 'out', 'move') then raise exception 'MONEY_BAD_REQUEST: choose money in, money out or a move'; end if;
  if v_day > (now() at time zone v_tz)::date then raise exception 'MONEY_BAD_REQUEST: the date cannot be in the future'; end if;
  if v_dir = 'move' then
    if v_from is null or v_to is null or v_from = v_to or v_from not in ('cash', 'upi', 'bank') or v_to not in ('cash', 'upi', 'bank') then
      raise exception 'MONEY_BAD_REQUEST: choose two different accounts'; end if;
    v_method := null; v_kind := 'transfer';
  else
    if v_method is null or v_method not in ('cash', 'upi', 'gpay', 'phonepe', 'card', 'bank') then raise exception 'MONEY_BAD_REQUEST: choose how the money moved'; end if;
    if v_kind is null then raise exception 'MONEY_BAD_REQUEST: choose what it is for'; end if;
    v_from := null; v_to := null;
  end if;
  if v_kind = 'due_received' and v_party is null then raise exception 'MONEY_BAD_REQUEST: say who paid the due'; end if;
  insert into public.rmoney_entries (organization_id, location_id, entry_no, direction, kind, category, method, amount_minor, party, party_phone, reference, note,
                                     from_account, to_account, entry_date, created_by, idempotency_key)
  values (v_org, v_locs[1], 'MN-' || lpad(public.next_org_seq(v_org, 'rmoney')::text, 5, '0'), v_dir, v_kind,
          nullif(left(btrim(coalesce(p->>'category', '')), 60), ''), v_method, v_amt, left(v_party, 60), left(v_phone, 20),
          nullif(left(btrim(coalesce(p->>'reference', '')), 60), ''), nullif(left(btrim(coalesce(p->>'note', '')), 300), ''), v_from, v_to, v_day, auth.uid(), v_key)
  returning * into e;
  return to_jsonb(e) || jsonb_build_object('replayed', false);
end $$;

create or replace function public.rmoney_void(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'approve'); e public.rmoney_entries; v_reason text := btrim(coalesce(p->>'reason', ''));
begin
  if v_reason = '' then raise exception 'MONEY_BAD_REQUEST: say why it is removed'; end if;
  select * into e from public.rmoney_entries where id = nullif(p->>'id', '')::uuid and organization_id = v_org for update;
  if not found then raise exception 'MONEY_NOT_FOUND: entry not found (only entries made here can be removed)'; end if;
  if e.kind = 'cash_difference' then raise exception 'MONEY_BAD_REQUEST: a day close cannot be undone'; end if;
  if e.status = 'voided' then return to_jsonb(e); end if;
  update public.rmoney_entries set status = 'voided', void_reason = left(v_reason, 200) where id = e.id returning * into e;
  return to_jsonb(e);
end $$;

-- the cash drawer for a day: opening (everything before it), cash sales, other cash in, cash refunds, cash paid out, what should be in it
create or replace function public.rmoney_register(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p); v_tz text := public.money_tz();
  v_day date := coalesce(nullif(p->>'day', '')::date, (now() at time zone v_tz)::date); r record; c public.rmoney_day_closes;
begin
  select coalesce(sum(case when l.day < v_day then case l.direction when 'in' then l.amount_minor else -l.amount_minor end end), 0) opening,
         coalesce(sum(l.amount_minor) filter (where l.day = v_day and l.direction = 'in' and l.source = 'sale'), 0) sales,
         coalesce(sum(l.amount_minor) filter (where l.day = v_day and l.direction = 'in' and l.source <> 'sale'), 0) other_in,
         coalesce(sum(l.amount_minor) filter (where l.day = v_day and l.direction = 'out' and l.source = 'refund'), 0) refunds,
         coalesce(sum(l.amount_minor) filter (where l.day = v_day and l.direction = 'out' and l.source <> 'refund'), 0) paid_out
    into r from public.rmoney_ledger(v_org, v_locs) l where l.account = 'cash' and l.day <= v_day
      -- the day's own close difference is shown as the count, not as cash in or out
      and not (l.kind = 'cash_difference' and l.day = v_day);
  select * into c from public.rmoney_day_closes where organization_id = v_org and location_id = v_locs[1] and day = v_day;
  return jsonb_build_object('day', v_day, 'opening_minor', r.opening, 'cash_sales_minor', r.sales, 'other_in_minor', r.other_in, 'refunds_minor', r.refunds,
    'paid_out_minor', r.paid_out, 'expected_minor', r.opening + r.sales + r.other_in - r.refunds - r.paid_out,
    'closed', case when c.day is null then null else jsonb_build_object('counted_minor', c.counted_minor, 'expected_minor', c.expected_minor,
               'difference_minor', c.counted_minor - c.expected_minor, 'at', c.created_at, 'by', public.money_person(v_org, c.created_by)) end,
    'can_close', public.has_permission(v_org, 'money', 'record', null) and c.day is null);
end $$;

-- Close day: the counted cash; a difference is booked as cash in (extra) or out (short), so tomorrow opens with what is really there
create or replace function public.rmoney_close_day(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'record'); v_locs uuid[] := public.money_scope(v_org, p); v_tz text := public.money_tz();
  v_day date := coalesce(nullif(p->>'day', '')::date, (now() at time zone v_tz)::date); v_counted bigint := nullif(p->>'counted_minor', '')::bigint;
  v_reg jsonb; v_exp bigint; v_diff bigint;
begin
  if v_counted is null or v_counted < 0 then raise exception 'MONEY_BAD_REQUEST: enter the cash you counted'; end if;
  if v_day > (now() at time zone v_tz)::date then raise exception 'MONEY_BAD_REQUEST: that day has not come yet'; end if;
  if exists (select 1 from public.rmoney_day_closes where organization_id = v_org and location_id = v_locs[1] and day = v_day) then
    raise exception 'MONEY_BAD_REQUEST: this day is already closed'; end if;
  v_reg := public.rmoney_register(jsonb_build_object('day', v_day, 'location_id', p->>'location_id'));
  v_exp := (v_reg->>'expected_minor')::bigint; v_diff := v_counted - v_exp;
  insert into public.rmoney_day_closes (organization_id, location_id, day, expected_minor, counted_minor, created_by) values (v_org, v_locs[1], v_day, v_exp, v_counted, auth.uid());
  if v_diff <> 0 then
    insert into public.rmoney_entries (organization_id, location_id, entry_no, direction, kind, category, method, amount_minor, note, entry_date, created_by, idempotency_key)
    values (v_org, v_locs[1], 'MN-' || lpad(public.next_org_seq(v_org, 'rmoney')::text, 5, '0'), case when v_diff > 0 then 'in' else 'out' end, 'cash_difference',
            case when v_diff > 0 then 'Extra cash at close' else 'Cash short at close' end, 'cash', abs(v_diff), null, v_day, auth.uid(), 'close:' || v_locs[1] || ':' || v_day);
  end if;
  return public.rmoney_register(jsonb_build_object('day', v_day, 'location_id', p->>'location_id'));
end $$;

-- dues: bills put on credit (to collect, less what was collected) and supplier invoices (to pay, less what was paid)
create or replace function public.rmoney_dues(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_locs uuid[] := public.money_scope(v_org, p); v_in jsonb; v_out jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('order_id', d.order_id, 'reference', d.no, 'name', d.name, 'phone', d.phone, 'amount_minor', d.amt,
           'paid_minor', d.got, 'left_minor', d.amt - d.got, 'at', d.at) order by d.at), '[]'::jsonb) into v_in
    from (select o.id order_id, o.display_no no, coalesce(nullif(btrim(o.customer_name), ''), 'Customer') name, o.customer_phone phone, sum(x.amount_minor) amt,
                 min(x.created_at) at,
                 coalesce((select sum(m.amount_minor) from public.rmoney_entries m where m.organization_id = v_org and m.kind = 'due_received'
                            and m.status = 'posted' and m.reference = o.display_no), 0) got
            from public.payments x join public.orders o on o.id = x.order_id
           where x.organization_id = v_org and x.method = 'due' and (o.location_id = any (v_locs) or o.location_id is null)
           group by o.id) d where d.amt > d.got;
  select coalesce(jsonb_agg(jsonb_build_object('invoice_id', i.id, 'reference', i.invoice_no, 'name', i.supplier_name, 'amount_minor', i.total_minor,
           'paid_minor', i.paid, 'left_minor', i.total_minor - i.paid, 'due_date', i.due_date) order by i.due_date nulls last, i.invoice_date), '[]'::jsonb) into v_out
    from (select s.*, coalesce((select sum(y.amount_minor) from public.supplier_invoice_payments y where y.invoice_id = s.id), 0) paid
            from public.supplier_invoices s where s.organization_id = v_org and (s.location_id = any (v_locs) or s.location_id is null)) i
   where i.total_minor > i.paid;
  return jsonb_build_object('to_collect', v_in, 'to_pay', v_out,
    'collect_minor', (select coalesce(sum((x->>'left_minor')::bigint), 0) from jsonb_array_elements(v_in) x),
    'pay_minor', (select coalesce(sum((x->>'left_minor')::bigint), 0) from jsonb_array_elements(v_out) x));
end $$;

-- contacts to pay: saved ones (with a UPI ID) first, then people money was recorded with who are not saved yet
create or replace function public.rmoney_contacts_list(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'read'); v_q text := nullif(lower(btrim(coalesce(p->>'q', ''))), '');
begin
  return jsonb_build_object(
    'saved', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'upi_id', c.upi_id) order by lower(c.name)), '[]'::jsonb)
                from public.rmoney_contacts c where c.organization_id = v_org and (v_q is null or position(v_q in lower(c.name || ' ' || c.phone || ' ' || c.upi_id)) > 0)),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object('name', r.n, 'phone', coalesce(r.ph, '')) order by lower(r.n)), '[]'::jsonb) from (
                 select distinct on (lower(n)) n, ph from (
                   select m.party n, m.party_phone ph from public.rmoney_entries m where m.organization_id = v_org and m.party is not null
                   union all select s.name, s.phone from public.pos_suppliers s where s.organization_id = v_org) z
                  where (v_q is null or position(v_q in lower(n)) > 0)
                    and not exists (select 1 from public.rmoney_contacts c where c.organization_id = v_org and lower(c.name) = lower(z.n))) r));
end $$;

create or replace function public.rmoney_contact_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.money_require('money', 'record'); c public.rmoney_contacts; v_id uuid := nullif(p->>'id', '')::uuid;
  v_name text := btrim(coalesce(p->>'name', '')); v_phone text := btrim(coalesce(p->>'phone', '')); v_upi text := lower(btrim(coalesce(p->>'upi_id', '')));
begin
  if v_name = '' or char_length(v_name) > 60 then raise exception 'MONEY_BAD_REQUEST: enter a name'; end if;
  if v_upi <> '' and v_upi !~ '^[a-z0-9._-]{2,200}@[a-z0-9.-]{2,64}$' then raise exception 'MONEY_BAD_REQUEST: that UPI ID does not look right (like name@bank)'; end if;
  if v_id is null then
    insert into public.rmoney_contacts (organization_id, name, phone, upi_id) values (v_org, v_name, left(v_phone, 20), v_upi)
    on conflict (organization_id, lower(name)) do update set phone = excluded.phone, upi_id = excluded.upi_id, updated_at = now() returning * into c;
  else
    update public.rmoney_contacts set name = v_name, phone = left(v_phone, 20), upi_id = v_upi, updated_at = now() where id = v_id and organization_id = v_org returning * into c;
    if not found then raise exception 'MONEY_NOT_FOUND: contact not found'; end if;
  end if;
  return jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'upi_id', c.upi_id);
end $$;

revoke all on function public.rmoney_home(jsonb), public.rmoney_entries_list(jsonb), public.rmoney_record(jsonb), public.rmoney_void(jsonb),
  public.rmoney_register(jsonb), public.rmoney_close_day(jsonb), public.rmoney_dues(jsonb), public.rmoney_contacts_list(jsonb), public.rmoney_contact_save(jsonb) from public, anon;
grant execute on function public.rmoney_home(jsonb), public.rmoney_entries_list(jsonb), public.rmoney_record(jsonb), public.rmoney_void(jsonb),
  public.rmoney_register(jsonb), public.rmoney_close_day(jsonb), public.rmoney_dues(jsonb), public.rmoney_contacts_list(jsonb), public.rmoney_contact_save(jsonb) to authenticated;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0623_org_sell_plan.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0623: the business's current plan for Subscription plans (founder, 29 Oct 2026: subscription plans in the restaurant POS, same prices as
-- the store). Read from the business's approved partner application (pos_only | pos_and_onelocal), for anyone signed in to the business,
-- not only the person who applied. Read only. Safe to run again.
create or replace function public.org_sell_plan(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id();
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  return jsonb_build_object('plan', (select a.sell_plan from public.ol_partner_applications a where a.organization_id = v_org and a.sell_plan is not null
                                      order by (a.status = 'approved') desc, a.updated_at desc nulls last limit 1));
end $$;
revoke all on function public.org_sell_plan(jsonb) from public, anon;
grant execute on function public.org_sell_plan(jsonb) to authenticated;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0624_addons_combos_billing.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0624: add-ons from the ingredient master, combo groups on a dish, and one pop-up when billing (founder, 29 Oct 2026).
--   * menu_addons: + inventory_item_id, consume_qty. An add-on is an ingredient (from the ingredient master) with the quantity one add-on uses
--     and its selling price; billing it consumes that ingredient (order_stock_consume).
--   * combo groups: menu_combo_groups / menu_combo_group_combos / menu_item_combo_groups; menu_combo_group_list / _save / _delete; a dish's
--     settings tick its combo groups. Choosing a combo on a dish adds the combo's price to the dish and its dishes to the KOT at ₹0.
--   * menu_line_extras(org, dish, line): the add-ons and combos chosen on one bill line, checked against the dish's groups and their
--     min / max, with what they add to the price. tbl_order_add and pos_place_order use it; pos_sell_catalog lists each dish's groups;
--     the KDS shows the add-ons under the dish.
-- Safe to run again.

alter table public.menu_addons add column if not exists inventory_item_id uuid references public.inventory_items(id) on delete set null;
alter table public.menu_addons add column if not exists consume_qty numeric(12,3);
do $$ begin
  alter table public.menu_addons add constraint menu_addons_consume_qty_check check (consume_qty is null or (consume_qty > 0 and consume_qty <= 100000));
exception when duplicate_object then null; end $$;

create table if not exists public.menu_combo_groups (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  min_select int not null default 0 check (min_select between 0 and 10),
  max_select int not null default 1 check (max_select between 1 and 10),
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (min_select <= max_select)
);
create unique index if not exists menu_combo_groups_name on public.menu_combo_groups (organization_id, lower(btrim(name)));
create table if not exists public.menu_combo_group_combos (
  group_id uuid not null references public.menu_combo_groups(id) on delete cascade,
  combo_id uuid not null references public.menu_combos(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  sort_order int not null default 0,
  primary key (group_id, combo_id)
);
create table if not exists public.menu_item_combo_groups (
  menu_item_id uuid not null references public.menu_items(id) on delete cascade,
  group_id uuid not null references public.menu_combo_groups(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  primary key (menu_item_id, group_id)
);
alter table public.menu_combo_groups enable row level security;
alter table public.menu_combo_group_combos enable row level security;
alter table public.menu_item_combo_groups enable row level security;
revoke all on public.menu_combo_groups, public.menu_combo_group_combos, public.menu_item_combo_groups from anon, authenticated;

-- a combo's dishes in a few words: "Peri Peri Fries, Ice Blue"
create or replace function public.menu_combo_items_text(p_combo uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select string_agg(case when ci.qty > 1 then ci.qty || ' × ' else '' end || m.name, ', ' order by m.name)
    from public.menu_combo_items ci join public.menu_items m on m.id = ci.menu_item_id where ci.combo_id = p_combo
$$;
revoke all on function public.menu_combo_items_text(uuid) from public, anon;

-- the add-on and combo groups of a dish, as billing shows them (null when it has none)
create or replace function public.menu_item_options(p_org uuid, p_item uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'addon_groups', (select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'min', g.min_select, 'max', g.max_select,
                       'addons', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'price', a.price, 'food_type', a.food_type) order by a.sort_order, a.name), '[]'::jsonb)
                                    from public.menu_addons a where a.group_id = g.id and a.active)) order by g.sort_order, g.name)
                       from public.menu_item_addon_groups x join public.menu_addon_groups g on g.id = x.group_id
                      where x.menu_item_id = p_item and g.organization_id = p_org and g.active
                        and exists (select 1 from public.menu_addons a where a.group_id = g.id and a.active)),
    'combo_groups', (select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'min', g.min_select, 'max', g.max_select,
                       'combos', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'price', c.price, 'items', public.menu_combo_items_text(c.id)) order by gc.sort_order, c.name), '[]'::jsonb)
                                    from public.menu_combo_group_combos gc join public.menu_combos c on c.id = gc.combo_id where gc.group_id = g.id and c.active)) order by g.sort_order, g.name)
                       from public.menu_item_combo_groups x join public.menu_combo_groups g on g.id = x.group_id
                      where x.menu_item_id = p_item and g.organization_id = p_org and g.active
                        and exists (select 1 from public.menu_combo_group_combos gc join public.menu_combos c on c.id = gc.combo_id where gc.group_id = g.id and c.active))))
$$;
revoke all on function public.menu_item_options(uuid, uuid) from public, anon;

-- One bill line's add-ons ("addons": [id, …], an id twice = two of it) and combos ("combos": [id, …]): each must belong to a group of the dish,
-- each group within its min / max. Returns {"add_ons": [{kind, id, name, price, qty}, …], "extra": the price they add to one dish}.
create or replace function public.menu_line_extras(p_org uuid, p_item uuid, p_line jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_dish text := (select name from public.menu_items where id = p_item); v_out jsonb := '[]'::jsonb; v_extra numeric := 0; g record; r record; v_n int;
begin
  if p_line ? 'addons' and jsonb_typeof(p_line->'addons') <> 'array' then raise exception 'POS_BAD_REQUEST: add-ons are a list'; end if;
  if p_line ? 'combos' and jsonb_typeof(p_line->'combos') <> 'array' then raise exception 'POS_BAD_REQUEST: combos are a list'; end if;
  if jsonb_array_length(coalesce(p_line->'addons', '[]')) > 40 or jsonb_array_length(coalesce(p_line->'combos', '[]')) > 10 then
    raise exception 'POS_BAD_REQUEST: too many add-ons on one dish'; end if;
  -- every chosen add-on is an active add-on of a group this dish has
  for r in select a.value as aid, count(*) as n from jsonb_array_elements_text(coalesce(p_line->'addons', '[]')) a group by a.value loop
    if not exists (select 1 from public.menu_addons ad join public.menu_item_addon_groups x on x.group_id = ad.group_id
                    where ad.id::text = r.aid and x.menu_item_id = p_item and ad.organization_id = p_org and ad.active) then
      raise exception 'POS_BAD_REQUEST: that add-on is not offered with %', v_dish; end if;
  end loop;
  for r in select c.value as cid from jsonb_array_elements_text(coalesce(p_line->'combos', '[]')) c loop
    if not exists (select 1 from public.menu_combo_group_combos gc join public.menu_item_combo_groups x on x.group_id = gc.group_id
                     join public.menu_combos cb on cb.id = gc.combo_id
                    where gc.combo_id::text = r.cid and x.menu_item_id = p_item and gc.organization_id = p_org and cb.active) then
      raise exception 'POS_BAD_REQUEST: that combo is not offered with %', v_dish; end if;
  end loop;
  -- each group within its min / max
  for g in select ag.* from public.menu_item_addon_groups x join public.menu_addon_groups ag on ag.id = x.group_id where x.menu_item_id = p_item and ag.active loop
    select count(*) into v_n from jsonb_array_elements_text(coalesce(p_line->'addons', '[]')) a join public.menu_addons ad on ad.id::text = a.value where ad.group_id = g.id;
    if v_n < g.min_select then raise exception 'POS_BAD_REQUEST: choose at least % from % for %', g.min_select, g.name, v_dish; end if;
    if v_n > g.max_select then raise exception 'POS_BAD_REQUEST: choose at most % from % for %', g.max_select, g.name, v_dish; end if;
  end loop;
  for g in select cg.* from public.menu_item_combo_groups x join public.menu_combo_groups cg on cg.id = x.group_id where x.menu_item_id = p_item and cg.active loop
    select count(*) into v_n from jsonb_array_elements_text(coalesce(p_line->'combos', '[]')) c join public.menu_combo_group_combos gc on gc.combo_id::text = c.value and gc.group_id = g.id;
    if v_n < g.min_select then raise exception 'POS_BAD_REQUEST: choose at least % from % for %', g.min_select, g.name, v_dish; end if;
    if v_n > g.max_select then raise exception 'POS_BAD_REQUEST: choose at most % from % for %', g.max_select, g.name, v_dish; end if;
  end loop;
  for r in select ad.id, ad.name, ad.price, count(*) as n from jsonb_array_elements_text(coalesce(p_line->'addons', '[]')) a join public.menu_addons ad on ad.id::text = a.value
            group by ad.id, ad.name, ad.price, ad.sort_order order by ad.sort_order, ad.name loop
    v_out := v_out || jsonb_build_object('kind', 'addon', 'id', r.id, 'name', r.name, 'price', r.price, 'qty', r.n);
    v_extra := v_extra + r.price * r.n;
  end loop;
  for r in select distinct cb.id, cb.name, cb.price from jsonb_array_elements_text(coalesce(p_line->'combos', '[]')) c join public.menu_combos cb on cb.id::text = c.value loop
    v_out := v_out || jsonb_build_object('kind', 'combo', 'id', r.id, 'name', r.name, 'price', r.price, 'qty', 1, 'items', public.menu_combo_items_text(r.id));
    v_extra := v_extra + r.price;
  end loop;
  return jsonb_build_object('add_ons', v_out, 'extra', v_extra);
end $$;
revoke all on function public.menu_line_extras(uuid, uuid, jsonb) from public, anon;

-- the combo dishes of the lines just added, at ₹0 ("Combo: fries & Cole with Veg Grilled Subway"), so the kitchen makes them and their recipes are used
create or replace function public.order_combo_lines(p_order uuid, p_org uuid, p_lines jsonb) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, notes, station, course)
  select p_order, m2.id, m2.name, (l->>'qty')::int * ci.qty, 0, left('Combo: ' || cb.name || ' with ' || mi.name, 200), coalesce(m2.station, 'main'), coalesce(m2.course, 'eat')
    from jsonb_array_elements(p_lines) l
    join public.menu_items mi on mi.id = (l->>'menu_item_id')::uuid and mi.organization_id = p_org
    cross join lateral jsonb_array_elements_text(coalesce(l->'combos', '[]')) c(cid)
    join public.menu_combos cb on cb.id::text = c.cid and cb.organization_id = p_org
    join public.menu_combo_items ci on ci.combo_id = cb.id
    join public.menu_items m2 on m2.id = ci.menu_item_id
$$;
revoke all on function public.order_combo_lines(uuid, uuid, jsonb) from public, anon, authenticated;

create or replace function public.menu_combo_group_list(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update');
begin
  return jsonb_build_object(
    'groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'min_select', g.min_select, 'max_select', g.max_select, 'active', g.active,
                 'combo_ids', (select coalesce(jsonb_agg(gc.combo_id order by gc.sort_order), '[]'::jsonb) from public.menu_combo_group_combos gc where gc.group_id = g.id),
                 'combos', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'price_minor', round(c.price * 100)::bigint) order by gc.sort_order), '[]'::jsonb)
                              from public.menu_combo_group_combos gc join public.menu_combos c on c.id = gc.combo_id where gc.group_id = g.id),
                 'dish_count', (select count(*) from public.menu_item_combo_groups x where x.group_id = g.id)) order by g.sort_order, g.name)
               from public.menu_combo_groups g where g.organization_id = v_org), '[]'::jsonb),
    'combos', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'price_minor', round(c.price * 100)::bigint, 'items', public.menu_combo_items_text(c.id), 'active', c.active) order by c.name)
               from public.menu_combos c where c.organization_id = v_org), '[]'::jsonb));
end $$;

create or replace function public.menu_combo_group_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); v_id uuid := nullif(p->>'id', '')::uuid; v_name text := public.mb_clean(p->>'name');
  v_min int := coalesce(nullif(p->>'min_select', '')::int, 0); v_max int := coalesce(nullif(p->>'max_select', '')::int, 1); c text; v_n int := 0;
begin
  if v_name is null or char_length(v_name) > 60 then raise exception 'POS_BAD_REQUEST: enter the group name (up to 60 characters)'; end if;
  if v_min < 0 or v_max < 1 or v_min > v_max or v_max > 10 then raise exception 'POS_BAD_REQUEST: choose between 0 and 10, the minimum not above the maximum'; end if;
  if jsonb_typeof(p->'combo_ids') is distinct from 'array' or jsonb_array_length(p->'combo_ids') = 0 then raise exception 'POS_BAD_REQUEST: choose at least one combo'; end if;
  if exists (select 1 from public.menu_combo_groups where organization_id = v_org and lower(btrim(name)) = lower(v_name) and id is distinct from v_id) then
    raise exception 'POS_CONFLICT: there is already a combo group called %', v_name; end if;
  if v_id is null then
    insert into public.menu_combo_groups (organization_id, name, min_select, max_select, sort_order)
    values (v_org, v_name, v_min, v_max, coalesce((select max(sort_order) + 1 from public.menu_combo_groups where organization_id = v_org), 0)) returning id into v_id;
  else
    update public.menu_combo_groups set name = v_name, min_select = v_min, max_select = v_max, active = coalesce((p->>'active')::boolean, active), updated_at = now()
     where id = v_id and organization_id = v_org;
    if not found then raise exception 'POS_NOT_FOUND: combo group not found'; end if;
  end if;
  delete from public.menu_combo_group_combos where group_id = v_id;
  for c in select jsonb_array_elements_text(p->'combo_ids') loop
    if not exists (select 1 from public.menu_combos where id::text = c and organization_id = v_org) then raise exception 'POS_NOT_FOUND: combo not found'; end if;
    v_n := v_n + 1;
    insert into public.menu_combo_group_combos (group_id, combo_id, organization_id, sort_order) values (v_id, c::uuid, v_org, v_n) on conflict do nothing;
  end loop;
  return jsonb_build_object('id', v_id) || public.menu_combo_group_list('{}');
end $$;

create or replace function public.menu_combo_group_delete(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update');
begin
  delete from public.menu_combo_groups where id = nullif(p->>'id', '')::uuid and organization_id = v_org;
  if not found then raise exception 'POS_NOT_FOUND: combo group not found'; end if;
  return public.menu_combo_group_list('{}');
end $$;

revoke all on function public.menu_combo_group_list(jsonb), public.menu_combo_group_save(jsonb), public.menu_combo_group_delete(jsonb) from public, anon;
grant execute on function public.menu_combo_group_list(jsonb), public.menu_combo_group_save(jsonb), public.menu_combo_group_delete(jsonb) to authenticated;

-- ---- existing functions, patched (live definitions + the 0624 changes) ----
CREATE OR REPLACE FUNCTION public.tbl_order_add(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_loc uuid := public.tbl_guard(p, 'order'); v_org uuid := public.current_org_id(); t public.dining_tables%rowtype;
  v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), ''); v_hash text; v_prev jsonb; v_send boolean; v_line jsonb; v_qty int;
  v_item public.menu_items%rowtype; o public.orders%rowtype; v_oid uuid; v_kot jsonb; v_res jsonb; v_n int := 0; v_new boolean := false;
begin
  if v_key is null then raise exception 'TBL_BAD_REQUEST: an Idempotency-Key is needed so a retry never adds the dishes twice'; end if;
  begin v_send := coalesce((p->>'send')::boolean, true); exception when others then raise exception 'TBL_BAD_REQUEST: send is true or false'; end;
  v_hash := md5((p - 'idempotency_key')::text);
  v_prev := public.tbl_req_replay(v_org, v_key, 'add', v_hash);
  if v_prev is not null then return v_prev; end if;
  t := public.tbl_get(v_org, v_loc, nullif(p->>'table_id', '')::uuid);
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') not between 1 and 50 then raise exception 'TBL_BAD_REQUEST: add between 1 and 50 dishes'; end if;
  for v_line in select * from jsonb_array_elements(p->'lines') loop
    begin v_qty := (v_line->>'qty')::int; exception when others then v_qty := null; end;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'TBL_BAD_REQUEST: quantities are 1 to 99'; end if;
    if char_length(coalesce(v_line->>'notes', '')) > 200 then raise exception 'TBL_BAD_REQUEST: a note is at most 200 characters'; end if;
    select * into v_item from public.menu_items where id = nullif(v_line->>'menu_item_id', '')::uuid and organization_id = v_org;
    if not found or not v_item.is_available then raise exception 'TBL_ITEM_UNAVAILABLE: % is not available', coalesce(v_item.name, 'a dish'); end if;
    if nullif(v_line->>'variant_id', '') is not null and not exists (select 1 from public.menu_item_variants mv where mv.id = (v_line->>'variant_id')::uuid and mv.menu_item_id = v_item.id) then
      raise exception 'TBL_BAD_REQUEST: choose a size of %', v_item.name; end if;
    v_n := v_n + 1;
  end loop;

  -- the table's open order (joined tables share one); locked so two phones adding at once queue up
  select o2.* into o from public.orders o2 where o2.organization_id = v_org and o2.table_id = any(public.tbl_group(v_org, t.id))
     and public.tbl_order_open(o2.status, o2.paid_at) order by o2.created_at desc limit 1 for update;
  if not found then
    v_res := public.pos_place_order(jsonb_build_object('organization_id', v_org, 'service_type', 'dine_in', 'table_id', t.id, 'placed_by', 'pos', 'fire_kot', false,
      'guest_count', nullif(p->>'guest_count', ''), 'lines', p->'lines'));
    v_oid := (v_res->>'id')::uuid; v_new := true;
    select * into o from public.orders where id = v_oid for update;
  else
    if o.status not in ('new', 'in_billing', 'sent_to_kitchen', 'ready') then
      raise exception 'TBL_WRONG_STATE: the bill for this table is already %; start a new order after it is settled', replace(o.status, '_', ' '); end if;
    v_oid := o.id;
    -- 0624: the add-ons and combos chosen on each line add to its price and are kept on it; the combo dishes follow at ₹0
    insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, notes, station, course, variant_name, add_ons)
    select o.id, mi.id, mi.name, (l->>'qty')::int, coalesce(mv.price, mi.price) + (e.x->>'extra')::numeric, nullif(btrim(coalesce(l->>'notes', '')), ''), coalesce(mi.station, 'main'), coalesce(mi.course, 'eat'), mv.name,
           nullif(e.x->'add_ons', '[]'::jsonb)
      from jsonb_array_elements(p->'lines') l join public.menu_items mi on mi.id = (l->>'menu_item_id')::uuid and mi.organization_id = v_org
      left join public.menu_item_variants mv on mv.id = nullif(l->>'variant_id', '')::uuid and mv.menu_item_id = mi.id
      cross join lateral (select public.menu_line_extras(v_org, mi.id, l) as x) e;
    perform public.order_combo_lines(o.id, v_org, p->'lines');
    perform public.tbl_order_reprice(o.id);
    insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, o.id, 'items_added', v_n || ' dishes added to ' || o.display_no, 'pos', jsonb_build_object('by', auth.uid(), 'held', not v_send));
  end if;
  -- takeaway lines (0606): mark one of the rows this call added for each line sent with "takeaway": true
  for v_line in select * from jsonb_array_elements(p->'lines') loop
    continue when not coalesce((v_line->>'takeaway')::boolean, false);
    update public.order_items set is_takeaway = true
     where id = (select x.id from public.order_items x where x.order_id = v_oid and x.menu_item_id = (v_line->>'menu_item_id')::uuid
                    and x.qty = (v_line->>'qty')::int and x.created_at = now() and not x.is_takeaway and x.kot_ticket_id is null
                  order by x.id limit 1);
  end loop;
  if v_send then v_kot := public.tbl_kot_fire(v_oid); end if;
  v_res := jsonb_build_object('order_id', v_oid, 'new_order', v_new, 'held', not v_send, 'dishes_added', v_n, 'kot', v_kot,
    'order', (select jsonb_build_object('display_no', x.display_no, 'status', x.status, 'subtotal', x.subtotal, 'total', x.total) from public.orders x where x.id = v_oid),
    'table', jsonb_build_object('id', t.id, 'label', t.label));
  insert into public.table_order_requests (organization_id, idempotency_key, kind, request_hash, order_id, result, created_by)
  values (v_org, v_key, 'add', v_hash, v_oid, v_res, auth.uid());
  return v_res || jsonb_build_object('replayed', false);
end $$;

CREATE OR REPLACE FUNCTION public.pos_place_order(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare
  v_org uuid := (p->>'organization_id')::uuid; v_key text := nullif(p->>'idempotency_key','');
  v_channel text := p->>'service_type'; v_placed_by text := coalesce(nullif(p->>'placed_by',''),'pos');
  v_qty int; v_line jsonb; v_item public.menu_items%rowtype; v_sub numeric(10,2) := 0; v_n int := 0;
  v_cfg public.org_bill_settings%rowtype; v_gst_pct numeric; v_gst numeric(10,2); v_sc numeric(10,2) := 0; v_waived numeric(10,2) := 0;
  v_raw numeric(10,2); v_total numeric(10,2); v_round numeric(10,2) := 0; v_disc numeric(10,2) := 0;
  v_table public.dining_tables%rowtype; v_loc uuid; v_no bigint; v_display text; v_id uuid; v_status text; v_kot uuid; v_ex uuid;
  v_waive boolean := coalesce((p->>'waive_service_charge')::boolean, false);
  v_code text; v_cp public.sell_coupons%rowtype; v_ckey text;
begin
  if auth.uid() is null or v_org is null or v_org is distinct from public.current_org_id() then raise exception 'POS_FORBIDDEN: not your organization'; end if;
  if not public.has_org_role(array['org_owner','org_admin','manager','biller','captain','business_manager','location_manager','operations_manager']) then
    raise exception 'POS_FORBIDDEN: your role cannot place orders'; end if;
  if v_channel not in ('dine_in','pickup','delivery') then raise exception 'POS_BAD_REQUEST: unknown service type'; end if;
  if v_placed_by not in ('pos','captain','guest','integration') then raise exception 'POS_BAD_REQUEST: unknown placed_by'; end if;
  if v_key is not null then
    select id into v_ex from public.orders where organization_id = v_org and idempotency_key = v_key;
    if found then return public.pos_order_json(v_ex) || jsonb_build_object('replayed', true); end if;
  end if;
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') not between 1 and 50 then raise exception 'POS_EMPTY: add between 1 and 50 lines'; end if;
  v_code := upper(nullif(btrim(coalesce(p->>'coupon_code', '')), ''));

  if nullif(p->>'table_id','') is not null then
    select * into v_table from public.dining_tables where id = (p->>'table_id')::uuid and organization_id = v_org and is_active;
    if not found then raise exception 'POS_BAD_TABLE: table not found'; end if;
    v_loc := v_table.location_id;
  elsif v_channel = 'dine_in' then raise exception 'POS_BAD_TABLE: choose a table for a dine-in order'; end if;
  if v_loc is null then select id into v_loc from public.locations where organization_id = v_org order by (code = 'MAIN') desc, created_at limit 1; end if;

  select * into v_cfg from public.org_bill_settings where organization_id = v_org;
  if not found then v_cfg.sgst_pct := 2.5; v_cfg.cgst_pct := 2.5; v_cfg.service_charge_pct := 0; v_cfg.round_off_enabled := true; end if;

  for v_line in select * from jsonb_array_elements(p->'lines') loop
    v_qty := (v_line->>'qty')::int;
    if v_qty is null or v_qty < 1 or v_qty > 99 then raise exception 'POS_BAD_QTY: quantities must be 1 to 99'; end if;
    select * into v_item from public.menu_items where id = (v_line->>'menu_item_id')::uuid and organization_id = v_org;
    if not found or not v_item.is_available then raise exception 'POS_ITEM_UNAVAILABLE: % is not available', coalesce(v_item.name,'an item'); end if;
    if nullif(v_line->>'variant_id', '') is not null and not exists (select 1 from public.menu_item_variants mv where mv.id = (v_line->>'variant_id')::uuid and mv.menu_item_id = v_item.id) then
      raise exception 'POS_BAD_VARIANT: choose a size of %', v_item.name; end if;
    v_sub := v_sub + (coalesce((select mv.price from public.menu_item_variants mv where mv.id = nullif(v_line->>'variant_id', '')::uuid and mv.menu_item_id = v_item.id), v_item.price)
                      + (public.menu_line_extras(v_org, v_item.id, v_line)->>'extra')::numeric) * v_qty; v_n := v_n + v_qty;
  end loop;

  -- 0380: a coupon code takes money off the bill. The rules live in sell_coupons; the discount is worked out here, never by the app.
  if v_code is not null then
    select * into v_cp from public.sell_coupons where organization_id = v_org and upper(code) = v_code and active
      and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now()) for update;
    if not found then raise exception 'POS_COUPON_UNKNOWN: this coupon code is not valid'; end if;
    if v_sub < v_cp.min_order then raise exception 'POS_COUPON_MIN: this coupon needs a bill of at least %', v_cp.min_order; end if;
    v_disc := case v_cp.kind when 'percent' then round(v_sub * v_cp.value / 100, 2) else v_cp.value end;
    if v_cp.max_discount is not null then v_disc := least(v_disc, v_cp.max_discount); end if;
    v_disc := least(v_disc, v_sub);
    -- use limits, counted under the coupon row's lock (the select above), so two tills cannot both take the last use
    v_ckey := nullif(right(regexp_replace(coalesce(p->>'customer_phone', ''), '\D', '', 'g'), 10), '');   -- the last 10 digits, so +91 and 0 prefixes do not make a second customer
    if v_cp.max_uses is not null and (select count(*) from public.sell_coupon_redemptions where coupon_id = v_cp.id and released_at is null) >= v_cp.max_uses then
      raise exception 'POS_COUPON_LIMIT: this coupon has been used up'; end if;
    if v_cp.max_uses_per_customer is not null then
      if v_ckey is null then raise exception 'POS_COUPON_CUSTOMER: this coupon is limited per customer; enter the customer''s mobile number'; end if;
      if (select count(*) from public.sell_coupon_redemptions where coupon_id = v_cp.id and customer_key = v_ckey and released_at is null) >= v_cp.max_uses_per_customer then
        raise exception 'POS_COUPON_LIMIT: this customer has already used this coupon'; end if;
    end if;
    update public.sell_coupons set used_count = used_count + 1, updated_at = now() where id = v_cp.id;
  end if;

  -- 0371: a shop that is not GST-registered charges no GST; when menu prices already include GST, the tax is taken out of them, not added on top
  v_gst_pct := case when v_cfg.gst_registered is false then 0 else v_cfg.sgst_pct + v_cfg.cgst_pct end;
  if coalesce(v_cfg.prices_include_tax, false) and v_gst_pct > 0 then
    v_gst := round((v_sub - v_disc) * v_gst_pct / (100 + v_gst_pct), 2);
    v_sub := v_sub - v_gst;   -- subtotal is stored before tax, so subtotal + GST still equals what the menu showed
  else
    v_gst := round((v_sub - v_disc) * v_gst_pct / 100, 2);
  end if;
  v_sc := round((v_sub - v_disc) * v_cfg.service_charge_pct / 100, 2);
  if v_waive then
    if not public.has_org_role(array['org_owner','org_admin','manager','business_manager','location_manager']) then raise exception 'POS_FORBIDDEN: only a manager can remove the service charge'; end if;
    if coalesce(btrim(p->>'waive_reason'),'') = '' then raise exception 'POS_BAD_REQUEST: a reason is needed to remove the service charge'; end if;
    v_waived := v_sc; v_sc := 0;
  end if;
  v_raw := v_sub - v_disc + v_gst + v_sc;
  v_total := case when v_cfg.round_off_enabled then round(v_raw) else v_raw end; v_round := v_total - v_raw;

  -- a coupon that makes the bill free is refused: a bill with nothing to pay cannot be completed at the counter
  if v_code is not null and v_total <= 0 then raise exception 'POS_COUPON_ZERO: this coupon would make the bill free; use a smaller discount'; end if;

  v_no := public.next_org_seq(v_org, 'order'); v_display := 'P-' || lpad(v_no::text, 5, '0');
  v_status := case when coalesce((p->>'fire_kot')::boolean, true) then 'sent_to_kitchen' else 'in_billing' end;
  insert into public.orders (organization_id, location_id, order_no, display_no, channel, status, table_id, customer_name, customer_phone, captain_name,
      subtotal, discount, gst_pct, gst_amount, service_charge, round_off, total, placed_by, guest_count, notes, idempotency_key,
      service_charge_waived, service_charge_waived_amount, waive_reason, created_by, coupon_code)
  values (v_org, v_loc, v_no, v_display, v_channel, v_status, v_table.id, nullif(p->>'customer_name',''), nullif(p->>'customer_phone',''), null,
      v_sub, v_disc, v_gst_pct, v_gst, v_sc, v_round, v_total, v_placed_by, coalesce(nullif(p->>'guest_count','')::int, 1), nullif(p->>'notes',''), v_key,
      v_waive, v_waived, case when v_waive then p->>'waive_reason' end, auth.uid(), case when v_disc > 0 then v_cp.code end)
  returning id into v_id;
  if v_code is not null and v_disc > 0 then
    insert into public.sell_coupon_redemptions (organization_id, coupon_id, order_id, customer_key) values (v_org, v_cp.id, v_id, v_ckey);
  end if;
  -- 0624: add-ons and combos on each line; the combo dishes follow at ₹0
  insert into public.order_items (order_id, menu_item_id, name, qty, unit_price, notes, station, course, variant_name, add_ons)
  select v_id, mi.id, mi.name, (l->>'qty')::int, coalesce(mv.price, mi.price) + (e.x->>'extra')::numeric, nullif(l->>'notes',''), coalesce(mi.station,'main'), coalesce(mi.course,'eat'), mv.name,
         nullif(e.x->'add_ons', '[]'::jsonb)
  from jsonb_array_elements(p->'lines') l join public.menu_items mi on mi.id = (l->>'menu_item_id')::uuid
  left join public.menu_item_variants mv on mv.id = nullif(l->>'variant_id', '')::uuid and mv.menu_item_id = mi.id
  cross join lateral (select public.menu_line_extras(v_org, mi.id, l) as x) e;
  perform public.order_combo_lines(v_id, v_org, p->'lines');
  insert into public.order_events (organization_id, order_id, kind, message, actor, meta) values
    (v_org, v_id, 'placed', 'Order ' || v_display || ' placed - ' || v_n || ' items', v_placed_by, jsonb_build_object('by', auth.uid()));
  if v_status = 'sent_to_kitchen' then
    insert into public.kot_tickets (organization_id, order_id, kot_no, station, status) values (v_org, v_id, public.next_org_seq(v_org,'kot'), 'main', 'new') returning id into v_kot;
    update public.order_items set kot_ticket_id = v_kot where order_id = v_id;
    insert into public.order_events (organization_id, order_id, kind, message, actor) values (v_org, v_id, 'kot_fired', 'KOT fired for ' || v_display, v_placed_by);
  end if;
  if v_waive then insert into public.order_events (organization_id, order_id, kind, message, actor, meta)
    values (v_org, v_id, 'service_charge_waived', 'Service charge removed: ' || (p->>'waive_reason'), v_placed_by, jsonb_build_object('amount', v_waived, 'by', auth.uid())); end if;
  return public.pos_order_json(v_id) || jsonb_build_object('replayed', false);
end $$;

CREATE OR REPLACE FUNCTION public.order_stock_consume(p_order uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare o public.orders%rowtype; r record; v_done numeric; v_seq integer; v_n integer := 0; v_k integer;
begin
  select * into o from public.orders where id = p_order;
  if not found or o.status not in ('sent_to_kitchen', 'ready', 'paid', 'delivered') then return 0; end if;
  -- an order already reversed (cancelled earlier in this transaction) never consumes again
  if exists (select 1 from public.stock_movements where ref_type = 'orders' and (ref_id = p_order::text or ref_id like p_order::text || '#%') and kind = 'sale_reversal') then return 0; end if;
  -- one consumer per order at a time
  perform pg_advisory_xact_lock(hashtextextended('order_stock:' || p_order::text, 400));
  -- What the order needs per stock item, against what the ledger already took for it. The first consumption writes one row per item
  -- (ref_id = the order id); a line added or increased later is consumed as a further row for just the difference (ref_id = order id#n), so
  -- it is consumed once and a repeat run adds nothing (H-06). Cancel puts back every row, whichever consumption wrote it.
  for r in
    select u.inventory_item_id, round(sum(u.need), 3) as need from (
      select rc.inventory_item_id, oi.qty * coalesce((select mv.recipe_factor from public.menu_item_variants mv where mv.menu_item_id = oi.menu_item_id and mv.name = oi.variant_name limit 1), 1) * rc.qty_per_unit * (1 + rc.wastage_pct / 100) as need
        from public.order_items oi
        join public.menu_item_recipes rc on rc.menu_item_id = oi.menu_item_id and rc.organization_id = o.organization_id
       where oi.order_id = o.id and oi.status <> 'cancelled'
      union all
      -- 0624: an add-on made from an ingredient uses that ingredient: its quantity, times how many, times the dishes
      select ad.inventory_item_id, oi.qty * coalesce((a->>'qty')::numeric, 1) * ad.consume_qty
        from public.order_items oi
        cross join lateral jsonb_array_elements(case when jsonb_typeof(oi.add_ons) = 'array' then oi.add_ons else '[]'::jsonb end) a
        join public.menu_addons ad on ad.id::text = a->>'id' and ad.organization_id = o.organization_id
       where oi.order_id = o.id and oi.status <> 'cancelled' and a->>'kind' = 'addon' and ad.inventory_item_id is not null and ad.consume_qty is not null) u
     group by u.inventory_item_id
  loop
    select coalesce(-sum(quantity), 0), count(*) into v_done, v_seq from public.stock_movements
     where ref_type = 'orders' and kind = 'sale' and inventory_item_id = r.inventory_item_id and (ref_id = o.id::text or ref_id like o.id::text || '#%');
    continue when r.need - v_done <= 0;
    insert into public.stock_movements (organization_id, location_id, inventory_item_id, kind, quantity, ref_type, ref_id, note, created_by)
    values (o.organization_id, o.location_id, r.inventory_item_id, 'sale', -(r.need - v_done), 'orders',
            case when v_seq = 0 then o.id::text else o.id::text || '#' || v_seq end, o.display_no, o.created_by)
    on conflict do nothing;
    get diagnostics v_k = row_count;
    v_n := v_n + v_k;
  end loop;
  return v_n;
end $$;

CREATE OR REPLACE FUNCTION public.menu_addon_group_save(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.mb_org('menu', 'update'); v_id uuid := nullif(p->>'id', '')::uuid; v_name text := public.mb_clean(p->>'name');
  v_min int := coalesce(nullif(p->>'min_select', '')::int, 0); v_max int := coalesce(nullif(p->>'max_select', '')::int, 1); a jsonb; v_keep uuid[] := '{}'; v_aid uuid; v_n int := 0;
  v_price numeric;
begin
  if v_name is null or char_length(v_name) > 60 then raise exception 'POS_BAD_REQUEST: enter the group name (up to 60 characters)'; end if;
  if v_min < 0 or v_max < 1 or v_min > v_max or v_max > 20 then raise exception 'POS_BAD_REQUEST: choose between 0 and 20, the minimum not above the maximum'; end if;
  if jsonb_typeof(p->'addons') <> 'array' or jsonb_array_length(p->'addons') = 0 then raise exception 'POS_BAD_REQUEST: add at least one add-on'; end if;
  if jsonb_array_length(p->'addons') > 50 then raise exception 'POS_BAD_REQUEST: up to 50 add-ons in a group'; end if;
  if exists (select 1 from public.menu_addon_groups where organization_id = v_org and lower(btrim(name)) = lower(v_name) and id is distinct from v_id) then
    raise exception 'POS_CONFLICT: there is already an add-on group called %', v_name; end if;
  if v_id is null then
    insert into public.menu_addon_groups (organization_id, name, min_select, max_select, sort_order)
    values (v_org, v_name, v_min, v_max, coalesce((select max(sort_order) + 1 from public.menu_addon_groups where organization_id = v_org), 0)) returning id into v_id;
  else
    update public.menu_addon_groups set name = v_name, min_select = v_min, max_select = v_max, active = coalesce((p->>'active')::boolean, active), updated_at = now()
     where id = v_id and organization_id = v_org;
    if not found then raise exception 'POS_NOT_FOUND: add-on group not found'; end if;
  end if;
  for a in select * from jsonb_array_elements(p->'addons') loop
    v_n := v_n + 1;
    -- 0624: an add-on picked from the ingredient master takes its name unless one is typed, and says how much of it one add-on uses
    if nullif(a->>'inventory_item_id', '') is not null then
      if not exists (select 1 from public.inventory_items ii where ii.id = (a->>'inventory_item_id')::uuid and ii.organization_id = v_org) then
        raise exception 'POS_NOT_FOUND: ingredient not found'; end if;
      if coalesce(nullif(a->>'consume_qty', '')::numeric, 0) <= 0 then raise exception 'POS_BAD_REQUEST: enter how much of the ingredient one add-on uses'; end if;
      a := a || jsonb_build_object('name', coalesce(public.mb_clean(a->>'name'), (select ii.name from public.inventory_items ii where ii.id = (a->>'inventory_item_id')::uuid)));
    end if;
    if public.mb_clean(a->>'name') is null or char_length(public.mb_clean(a->>'name')) > 60 then raise exception 'POS_BAD_REQUEST: every add-on needs a name (up to 60 characters)'; end if;
    v_price := round(coalesce(nullif(a->>'price', '')::numeric, 0), 2);
    if v_price < 0 or v_price > 100000 then raise exception 'POS_BAD_REQUEST: an add-on price is zero or more'; end if;
    if coalesce(a->>'food_type', 'veg') not in ('veg', 'non_veg', 'egg') then raise exception 'POS_BAD_REQUEST: choose veg, non-veg or egg'; end if;
    v_aid := nullif(a->>'id', '')::uuid;
    if v_aid is not null and exists (select 1 from public.menu_addons where id = v_aid and group_id = v_id) then
      update public.menu_addons set name = public.mb_clean(a->>'name'), price = v_price, food_type = coalesce(a->>'food_type', 'veg'),
             active = coalesce((a->>'active')::boolean, true), sort_order = v_n,
             inventory_item_id = nullif(a->>'inventory_item_id', '')::uuid, consume_qty = case when nullif(a->>'inventory_item_id', '') is null then null else nullif(a->>'consume_qty', '')::numeric end
       where id = v_aid;
    else
      insert into public.menu_addons (organization_id, group_id, name, price, food_type, active, sort_order, inventory_item_id, consume_qty)
      values (v_org, v_id, public.mb_clean(a->>'name'), v_price, coalesce(a->>'food_type', 'veg'), coalesce((a->>'active')::boolean, true), v_n,
              nullif(a->>'inventory_item_id', '')::uuid, case when nullif(a->>'inventory_item_id', '') is null then null else nullif(a->>'consume_qty', '')::numeric end) returning id into v_aid;
    end if;
    v_keep := v_keep || v_aid;
  end loop;
  delete from public.menu_addons where group_id = v_id and not (id = any (v_keep));
  if jsonb_typeof(p->'menu_item_ids') = 'array' then
    delete from public.menu_item_addon_groups where group_id = v_id;
    insert into public.menu_item_addon_groups (menu_item_id, group_id, organization_id)
    select m.id, v_id, v_org from public.menu_items m where m.organization_id = v_org and m.id::text in (select jsonb_array_elements_text(p->'menu_item_ids'))
    on conflict do nothing;
  end if;
  return jsonb_build_object('id', v_id) || public.menu_addon_list('{}');
end $$;

CREATE OR REPLACE FUNCTION public.menu_addon_list(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.mb_org('menu', 'update');
begin
  return jsonb_build_object('groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'min_select', g.min_select,
      'max_select', g.max_select, 'active', g.active,
      'dish_count', (select count(*) from public.menu_item_addon_groups x where x.group_id = g.id),
      'addons', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'price_minor', round(a.price * 100)::bigint,
                  'food_type', a.food_type, 'active', a.active, 'inventory_item_id', a.inventory_item_id, 'consume_qty', a.consume_qty,
                  'ingredient', (select ii.name from public.inventory_items ii where ii.id = a.inventory_item_id),
                  'unit', (select ii.unit from public.inventory_items ii where ii.id = a.inventory_item_id)) order by a.sort_order, a.name) from public.menu_addons a where a.group_id = g.id), '[]'))
    order by g.sort_order, g.name) from public.menu_addon_groups g where g.organization_id = v_org), '[]'),
    -- 0624: the ingredient master, to pick an add-on from
    'ingredients', coalesce((select jsonb_agg(jsonb_build_object('id', ii.id, 'name', ii.name, 'unit', ii.unit) order by lower(ii.name))
                              from public.inventory_items ii where ii.organization_id = v_org and ii.active), '[]'));
end $$;

CREATE OR REPLACE FUNCTION public.menu_item_settings(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.mb_org('menu', 'update'); m public.menu_items%rowtype;
begin
  select * into m from public.menu_items where id = nullif(p->>'id', '')::uuid and organization_id = v_org;
  if not found then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  return jsonb_build_object('id', m.id, 'version', m.edit_version, 'name', m.name, 'price_minor', round(m.price * 100)::bigint,
    'sizes', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'price', v.price, 'recipe_factor', v.recipe_factor, 'is_default', v.is_default) order by v.sort_order, v.price), '[]'::jsonb)
              from public.menu_item_variants v where v.menu_item_id = m.id),
    'category_id', m.category_id, 'category', (select name from public.menu_categories where id = m.category_id),
    'food_type', m.food_type, 'course', m.course, 'station', m.station, 'prep_minutes', m.prep_minutes, 'is_recommended', m.is_recommended,
    'sku', m.sku, 'is_available', m.is_available, 'image_url', m.image_url, 'description', m.description,
    'addon_group_ids', coalesce((select jsonb_agg(group_id) from public.menu_item_addon_groups where menu_item_id = m.id), '[]'),
    'recipe', public.mb_recipe_json(v_org, m.id) - 'lines',
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort_order, name)
                            from public.menu_categories where organization_id = v_org), '[]'),
    'addon_groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name,
                               'addons', (select count(*) from public.menu_addons a where a.group_id = g.id and a.active)) order by g.sort_order, g.name)
                              from public.menu_addon_groups g where g.organization_id = v_org and g.active), '[]'),
    'combo_group_ids', coalesce((select jsonb_agg(group_id) from public.menu_item_combo_groups where menu_item_id = m.id), '[]'),
    'combo_groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name,
                               'combos', (select count(*) from public.menu_combo_group_combos gc join public.menu_combos c on c.id = gc.combo_id where gc.group_id = g.id and c.active)) order by g.sort_order, g.name)
                              from public.menu_combo_groups g where g.organization_id = v_org and g.active), '[]'),
    'stations', '["main","grill","beverage","dessert","tandoor","chinese"]'::jsonb);
end $$;

CREATE OR REPLACE FUNCTION public.menu_item_settings_save(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.mb_org('menu', 'update'); m public.menu_items%rowtype; v_name text; v_price numeric; v_cat uuid; v_sku text; g text;
begin
  select * into m from public.menu_items where id = nullif(p->>'id', '')::uuid and organization_id = v_org for update;
  if not found then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  if nullif(p->>'version', '') is null or (p->>'version')::bigint <> m.edit_version then raise exception 'POS_STALE: this dish was changed on another device'; end if;
  v_name := coalesce(public.mb_clean(p->>'name'), m.name);
  if char_length(v_name) not between 2 and 120 then raise exception 'POS_BAD_REQUEST: enter the dish name'; end if;
  v_price := case when p ? 'price' then round((p->>'price')::numeric, 2) else m.price end;
  if v_price is null or v_price <= 0 or v_price > 1000000 then raise exception 'POS_BAD_REQUEST: enter a selling price above zero'; end if;
  v_cat := case when nullif(p->>'category_id', '') is not null then (select id from public.menu_categories where id = (p->>'category_id')::uuid and organization_id = v_org)
                when public.mb_clean(p->>'category') is not null then public.mb_category(v_org, p->>'category') else m.category_id end;
  if v_cat is null then raise exception 'POS_NOT_FOUND: category not found'; end if;
  v_sku := case when p ? 'sku' then public.mb_clean(p->>'sku') else m.sku end;
  if v_sku is not null and exists (select 1 from public.menu_items where organization_id = v_org and lower(sku) = lower(v_sku) and id <> m.id) then
    raise exception 'POS_CONFLICT: another dish already uses the code %', v_sku; end if;
  if p ? 'food_type' and p->>'food_type' not in ('veg', 'non_veg', 'egg') then raise exception 'POS_BAD_REQUEST: choose veg, non-veg or egg'; end if;
  if p ? 'course' and p->>'course' not in ('eat', 'drink') then raise exception 'POS_BAD_REQUEST: course is eat or drink'; end if;
  if p ? 'prep_minutes' and ((p->>'prep_minutes')::int < 0 or (p->>'prep_minutes')::int > 240) then raise exception 'POS_BAD_REQUEST: preparation time is 0 to 240 minutes'; end if;
  if p ? 'station' and coalesce(public.mb_clean(p->>'station'), '') = '' then raise exception 'POS_BAD_REQUEST: choose a kitchen station'; end if;
  if exists (select 1 from public.menu_items where organization_id = v_org and category_id = v_cat and lower(name) = lower(v_name) and id <> m.id) then
    raise exception 'POS_CONFLICT: % is already in this category', v_name; end if;
  update public.menu_items set name = v_name, price = v_price, category_id = v_cat, sku = v_sku,
    food_type = coalesce(p->>'food_type', food_type), course = coalesce(p->>'course', course),
    station = coalesce(public.mb_clean(p->>'station'), station), prep_minutes = coalesce((p->>'prep_minutes')::int, prep_minutes),
    is_recommended = coalesce((p->>'is_recommended')::boolean, is_recommended), updated_at = now()
   where id = m.id;
  if jsonb_typeof(p->'addon_group_ids') = 'array' then
    delete from public.menu_item_addon_groups where menu_item_id = m.id;
    for g in select jsonb_array_elements_text(p->'addon_group_ids') loop
      if not exists (select 1 from public.menu_addon_groups where id = g::uuid and organization_id = v_org) then raise exception 'POS_NOT_FOUND: add-on group not found'; end if;
      insert into public.menu_item_addon_groups (menu_item_id, group_id, organization_id) values (m.id, g::uuid, v_org) on conflict do nothing;
    end loop;
  end if;
  -- 0624: the combo groups ticked on the dish
  if jsonb_typeof(p->'combo_group_ids') = 'array' then
    delete from public.menu_item_combo_groups where menu_item_id = m.id;
    for g in select jsonb_array_elements_text(p->'combo_group_ids') loop
      if not exists (select 1 from public.menu_combo_groups where id = g::uuid and organization_id = v_org) then raise exception 'POS_NOT_FOUND: combo group not found'; end if;
      insert into public.menu_item_combo_groups (menu_item_id, group_id, organization_id) values (m.id, g::uuid, v_org) on conflict do nothing;
    end loop;
  end if;
  return public.menu_item_settings(jsonb_build_object('id', m.id));
end $$;

CREATE OR REPLACE FUNCTION public.pos_sell_catalog(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.current_org_id(); v_q text := nullif(btrim(coalesce(p->>'q', '')), ''); v_cat text := nullif(btrim(coalesce(p->>'category', '')), '');
  v_av boolean; v_sort text := coalesce(nullif(p->>'sort', ''), 'name'); v_like text;
begin
  if auth.uid() is null or v_org is null then raise exception 'POS_FORBIDDEN: sign in to a business first'; end if;
  if v_sort not in ('name', 'price_asc', 'price_desc') then raise exception 'POS_BAD_REQUEST: unknown sort'; end if;
  begin v_av := coalesce((p->>'available')::boolean, false); exception when others then raise exception 'POS_BAD_REQUEST: available is true or false'; end;
  v_like := '%' || regexp_replace(coalesce(v_q, ''), '([%_\\])', '\\\1', 'g') || '%';
  return jsonb_build_object(
    'items', (select coalesce(jsonb_agg(j order by o1, o2 desc, o3), '[]'::jsonb) from (
        select jsonb_build_object('id', i.id, 'name', i.name, 'sku', coalesce(i.sku, ''), 'price', i.price, 'image_url', i.image_url, 'available', i.is_available,
                 'category', coalesce(c.name, ''), 'food_type', coalesce(i.food_type, 'veg'),
                 'has_recipe', exists (select 1 from public.menu_item_recipes mr where mr.menu_item_id = i.id and mr.organization_id = v_org),
                 'can_make', public.menu_can_make(v_org, i.id),
                 'options', public.menu_item_options(v_org, i.id),
                 'variants', (select coalesce(jsonb_agg(jsonb_build_object('id', mv.id, 'name', mv.name, 'price', mv.price, 'is_default', mv.is_default, 'recipe_factor', mv.recipe_factor,
                                  'can_make', floor(public.menu_can_make(v_org, i.id) / mv.recipe_factor)::int) order by mv.sort_order, mv.price), '[]'::jsonb)
                                from public.menu_item_variants mv where mv.menu_item_id = i.id)) as j,
               case when v_sort = 'price_asc' then i.price end as o1, case when v_sort = 'price_desc' then i.price end as o2, i.name as o3
        from public.menu_items i left join public.menu_categories c on c.id = i.category_id
        where i.organization_id = v_org and (not v_av or i.is_available)
          and (v_q is null or i.name ilike v_like or coalesce(i.sku, '') ilike v_like)
          and (v_cat is null or lower(coalesce(c.name, '')) = lower(v_cat))
        order by o1 asc, o2 desc, o3 limit 200) s),
    'categories', (select coalesce(jsonb_agg(n order by n), '[]'::jsonb) from (
        select distinct c.name as n from public.menu_items i join public.menu_categories c on c.id = i.category_id where i.organization_id = v_org) k));
end $$;

CREATE OR REPLACE FUNCTION public.kds_card_json(p_ticket uuid, p_key text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
  select jsonb_build_object(
    'card_id', c.ticket_id || ':' || c.queue_key, 'id', c.ticket_id, 'station', c.queue_key,
    'station_name', coalesce((select s.name from public.pos_kitchen_stations s where s.organization_id = t.organization_id and s.key = c.queue_key), 'Unassigned'),
    'kot_no', c.kot_no, 'order_id', c.order_id, 'display_no', c.display_no, 'channel', c.channel, 'chip', c.chip, 'version', c.version,
    'status', case c.chip when 'new' then 'new' when 'in_progress' then 'preparing' when 'ready' then 'ready' else 'delivered' end,
    'priority', c.priority, 'age_minutes', greatest(0, floor(extract(epoch from now() - c.created_at) / 60))::int,
    'delayed', c.chip in ('new', 'in_progress') and c.created_at < now() - interval '15 minutes',
    'created_at', c.created_at, 'started_at', c.started_at, 'ready_at', case when c.chip in ('ready', 'served') then c.ready_at end, 'served_at', c.served_at,
    'table_label', (select d.label from public.dining_tables d where d.id = o.table_id and d.organization_id = o.organization_id),
    'moved', public.order_table_move(o.id),
    'order_note', nullif(btrim(coalesce(o.notes, '')), ''),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'takeaway', i.is_takeaway, 'qty', i.qty, 'status', i.status, 'done', i.status in ('ready', 'delivered'),
                 'station', i.station, 'notes', nullif(btrim(coalesce(i.notes, '')), ''), 'variant', i.variant_name,
                 'add_ons', (select jsonb_agg(case when coalesce((a->>'qty')::int, 1) > 1 then (a->>'qty') || ' × ' else '' end || (a->>'name') || case when a->>'kind' = 'combo' then ' (combo)' else '' end)
                               from jsonb_array_elements(case when jsonb_typeof(i.add_ons) = 'array' then i.add_ons else '[]'::jsonb end) a)) order by i.created_at, i.name)
               from public.order_items i where i.kot_ticket_id = t.id and i.status <> 'cancelled' and public.kitchen_queue_key(t.organization_id, i.station) = c.queue_key), '[]'::jsonb),
    'item_count', c.n_total, 'done_count', c.n_done,
    'stations', jsonb_build_array(coalesce((select s.name from public.pos_kitchen_stations s where s.organization_id = t.organization_id and s.key = c.queue_key), 'Unassigned')))
  from public.kot_tickets t join public.orders o on o.id = t.order_id
  join lateral public.kds_cards(t.organization_id, t.id) c on c.queue_key = p_key
  where t.id = p_ticket;
$$;


-- ----------------------------------------------------------------------------------------------------------------------------
-- 0625_bill_lists_addons.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0625: the bill slip, the printed bill, checkout and the receipt list each dish's add-ons and combos under it (founder, 29 Oct 2026), with
-- their price; a combo's dishes (₹0 rows that are there for the kitchen) are marked "in_combo" so the bill does not list them twice.
-- rst_bill_order_json feeds rst_bill_view and rst_receipt_view. Safe to run again.

CREATE OR REPLACE FUNCTION public.rst_bill_order_json(p_order uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
  select jsonb_build_object('id', o.id, 'display_no', o.display_no, 'status', o.status, 'updated_at', o.updated_at, 'created_at', o.created_at,
    'subtotal', o.subtotal, 'discount', o.discount, 'coupon_code', o.coupon_code, 'gst_pct', o.gst_pct, 'gst_amount', o.gst_amount,
    'service_charge', o.service_charge, 'round_off', o.round_off, 'total', o.total, 'paid', public.rst_paid(o.id),
    'due', greatest(o.total - public.rst_paid(o.id), 0), 'notes', o.notes, 'customer_phone', o.customer_phone,
    'bill_generated', o.status = 'awaiting_payment',
    'items', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'takeaway', i.is_takeaway, 'variant', i.variant_name, 'qty', i.qty, 'unit_price', i.unit_price,
                'line_total', i.unit_price * i.qty,
                -- 0625: what was chosen with the dish (add-ons and combos, each priced for one dish), and whether this row is a combo's dish at ₹0
                'add_ons', (select coalesce(jsonb_agg(jsonb_build_object('kind', x->>'kind', 'name', x->>'name', 'qty', coalesce((x->>'qty')::int, 1),
                              'price', (x->>'price')::numeric, 'items', x->>'items')), '[]'::jsonb)
                              from jsonb_array_elements(case when jsonb_typeof(i.add_ons) = 'array' then i.add_ons else '[]'::jsonb end) x),
                'in_combo', i.unit_price = 0 and coalesce(i.notes, '') like 'Combo: %') order by i.created_at, i.id), '[]'::jsonb)
                from public.order_items i where i.order_id = o.id and i.status <> 'cancelled'),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', y.id, 'method', y.method, 'amount', y.amount, 'at', y.created_at,
                   'tendered', (select t.tendered from public.pos_cash_tenders t where t.payment_id = y.id)) order by y.created_at, y.id), '[]'::jsonb)
                   from public.payments y where y.order_id = o.id),
    'split', (select public.rst_split_json(s.id) from public.rst_bill_splits s where s.order_id = o.id and s.status in ('active', 'completed')
               order by s.created_at desc limit 1))
  from public.orders o where o.id = p_order;
$$;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0626_addon_recipes.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0626: a recipe for an add-on (a topping made of several ingredients), kept in the recipe master next to the dishes (founder, 29 Oct 2026).
--   * menu_addon_recipes: an add-on's ingredients, quantity per add-on, wastage, key flag.
--   * rcp_list: + 'addons' (every add-on with its recipe figures); rcp_view / rcp_save take "addon_id" instead of "menu_item_id".
--   * Saving an add-on's recipe sets the add-on's main ingredient (0624) to its key (or first) line, so the add-on master shows it.
--   * order_stock_consume: a billed add-on uses its recipe; an add-on without one still uses its single ingredient (0624).
-- Safe to run again.

create table if not exists public.menu_addon_recipes (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  addon_id uuid not null references public.menu_addons(id) on delete cascade,
  inventory_item_id uuid not null references public.inventory_items(id) on delete cascade,
  qty_per_unit numeric(12,4) not null check (qty_per_unit > 0 and qty_per_unit <= 100000),
  wastage_pct numeric(5,2) not null default 0 check (wastage_pct between 0 and 90),
  is_key boolean not null default false,
  note text check (note is null or char_length(note) <= 200),
  primary key (addon_id, inventory_item_id)
);
alter table public.menu_addon_recipes enable row level security;
revoke all on public.menu_addon_recipes from anon, authenticated;

-- an add-on's recipe and its figures, shaped like a dish's (mb_recipe_json): "kind" 'addon', its id also as menu_item_id for the screens
create or replace function public.mb_addon_recipe_json(p_org uuid, p_addon uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare a public.menu_addons%rowtype; v_lines jsonb := '[]'; v_cost bigint := 0; v_missing int := 0; r record; c record; v_line bigint;
begin
  select * into a from public.menu_addons where id = p_addon and organization_id = p_org;
  if not found then raise exception 'POS_NOT_FOUND: add-on not found'; end if;
  for r in select ar.*, i.name, i.unit, i.category from public.menu_addon_recipes ar join public.inventory_items i on i.id = ar.inventory_item_id
            where ar.addon_id = p_addon and ar.organization_id = p_org order by ar.is_key desc, i.name loop
    select * into c from public.mb_ing_cost(p_org, r.inventory_item_id);
    v_line := case when c.cost_minor is null then null else round(c.cost_minor * r.qty_per_unit * (1 + r.wastage_pct / 100))::bigint end;
    if v_line is null then v_missing := v_missing + 1; else v_cost := v_cost + v_line; end if;
    v_lines := v_lines || jsonb_build_object('inventory_item_id', r.inventory_item_id, 'name', r.name, 'unit', r.unit, 'category', r.category,
      'qty', r.qty_per_unit, 'wastage_pct', r.wastage_pct, 'is_key', r.is_key, 'note', r.note,
      'unit_cost_minor', c.cost_minor, 'cost_source', c.source, 'line_cost_minor', v_line);
  end loop;
  return jsonb_build_object(
    'kind', 'addon', 'addon_id', a.id, 'menu_item_id', a.id, 'name', a.name, 'food_type', a.food_type, 'image_url', null,
    'category', (select g.name from public.menu_addon_groups g where g.id = a.group_id),
    -- an add-on without a recipe yet that has its one ingredient (0624): billed, it uses that
    'single', case when jsonb_array_length(v_lines) = 0 and a.inventory_item_id is not null then
                     jsonb_build_object('name', (select name from public.inventory_items where id = a.inventory_item_id),
                                        'unit', (select unit from public.inventory_items where id = a.inventory_item_id), 'qty', a.consume_qty) end,
    'price_minor', round(a.price * 100)::bigint, 'lines', v_lines, 'line_count', jsonb_array_length(v_lines),
    'key_count', (select count(*) from jsonb_array_elements(v_lines) x where (x->>'is_key')::boolean),
    'missing_cost', v_missing, 'cost_minor', v_cost,
    'food_cost_pct', case when a.price > 0 and jsonb_array_length(v_lines) > 0 then round(v_cost / (a.price * 100) * 100, 1) end,
    'margin_minor', case when jsonb_array_length(v_lines) > 0 then round(a.price * 100)::bigint - v_cost end,
    'margin_pct', case when a.price > 0 and jsonb_array_length(v_lines) > 0 then round((a.price * 100 - v_cost) / (a.price * 100) * 100, 1) end);
end $$;
revoke all on function public.mb_addon_recipe_json(uuid, uuid) from public, anon, authenticated;

-- ---- existing functions, patched (live definitions + the 0626 changes) ----

CREATE OR REPLACE FUNCTION public.rcp_list(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.mb_org('menu', 'update'); v_q text := lower(coalesce(public.mb_clean(p->>'q'), ''));
  v_items jsonb := '[]'; r record; j jsonb; v_with int := 0; v_sum numeric := 0; v_n int := 0;
begin
  for r in select m.id from public.menu_items m left join public.menu_categories c on c.id = m.category_id
            where m.organization_id = v_org and (v_q = '' or lower(m.name) like '%' || v_q || '%')
            order by c.sort_order nulls last, c.name, m.sort_order, m.name loop
    j := public.mb_recipe_json(v_org, r.id) - 'lines';
    if (j->>'line_count')::int > 0 then
      v_with := v_with + 1;
      if j->>'food_cost_pct' is not null then v_sum := v_sum + (j->>'food_cost_pct')::numeric; v_n := v_n + 1; end if;
    end if;
    v_items := v_items || j;
  end loop;
  return jsonb_build_object('items', v_items,
    'summary', jsonb_build_object('dishes', jsonb_array_length(v_items), 'with_recipe', v_with, 'without_recipe', jsonb_array_length(v_items) - v_with,
                                  'avg_food_cost_pct', case when v_n > 0 then round(v_sum / v_n, 1) end),
    -- 0626: every add-on with its recipe figures (the recipe master's Add-ons)
    'addons', coalesce((select jsonb_agg(public.mb_addon_recipe_json(v_org, ad.id) - 'lines' order by g.sort_order, g.name, ad.sort_order, ad.name)
                          from public.menu_addons ad join public.menu_addon_groups g on g.id = ad.group_id
                         where ad.organization_id = v_org and ad.active and (v_q = '' or lower(ad.name) like '%' || v_q || '%')), '[]'::jsonb));
end $$;

CREATE OR REPLACE FUNCTION public.rcp_view(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.mb_org('menu', 'update');
begin
  -- 0626: an add-on's recipe
  if nullif(p->>'addon_id', '') is not null then return public.mb_addon_recipe_json(v_org, (p->>'addon_id')::uuid); end if;
  return public.mb_recipe_json(v_org, nullif(p->>'menu_item_id', '')::uuid);
end $$;

CREATE OR REPLACE FUNCTION public.rcp_save(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.mb_org('menu', 'update'); v_item uuid := nullif(p->>'menu_item_id', '')::uuid; l jsonb; v_ing uuid; v_qty numeric; v_w numeric;
begin
  -- 0626: an add-on's recipe, the same rules as a dish's
  if nullif(p->>'addon_id', '') is not null then
    if not exists (select 1 from public.menu_addons where id = (p->>'addon_id')::uuid and organization_id = v_org) then raise exception 'POS_NOT_FOUND: add-on not found'; end if;
    if jsonb_typeof(p->'lines') <> 'array' then raise exception 'POS_BAD_REQUEST: lines is a list'; end if;
    if jsonb_array_length(p->'lines') > 60 then raise exception 'POS_BAD_REQUEST: up to 60 ingredients in one recipe'; end if;
    delete from public.menu_addon_recipes where addon_id = (p->>'addon_id')::uuid and organization_id = v_org;
    for l in select * from jsonb_array_elements(p->'lines') loop
      v_ing := nullif(l->>'inventory_item_id', '')::uuid;
      if not exists (select 1 from public.inventory_items where id = v_ing and organization_id = v_org) then raise exception 'POS_NOT_FOUND: an ingredient in this recipe was not found'; end if;
      v_qty := nullif(l->>'qty', '')::numeric;
      if v_qty is null or v_qty <= 0 or v_qty > 100000 then raise exception 'POS_BAD_REQUEST: every ingredient needs a quantity above zero'; end if;
      v_w := coalesce(nullif(l->>'wastage_pct', '')::numeric, 0);
      if v_w < 0 or v_w > 90 then raise exception 'POS_BAD_REQUEST: wastage is 0 to 90 percent'; end if;
      insert into public.menu_addon_recipes (organization_id, addon_id, inventory_item_id, qty_per_unit, wastage_pct, is_key, note)
      values (v_org, (p->>'addon_id')::uuid, v_ing, v_qty, v_w, coalesce((l->>'is_key')::boolean, false), left(public.mb_clean(l->>'note'), 200))
      on conflict (addon_id, inventory_item_id) do update set qty_per_unit = excluded.qty_per_unit + menu_addon_recipes.qty_per_unit,
        wastage_pct = excluded.wastage_pct, is_key = excluded.is_key or menu_addon_recipes.is_key;
    end loop;
    -- the add-on master shows the recipe's key (or first) ingredient as the add-on's ingredient
    update public.menu_addons ad set inventory_item_id = k.inventory_item_id, consume_qty = k.qty_per_unit
      from (select ar.inventory_item_id, ar.qty_per_unit from public.menu_addon_recipes ar where ar.addon_id = (p->>'addon_id')::uuid
             order by ar.is_key desc, ar.qty_per_unit desc limit 1) k
     where ad.id = (p->>'addon_id')::uuid;
    return public.mb_addon_recipe_json(v_org, (p->>'addon_id')::uuid);
  end if;
  if not exists (select 1 from public.menu_items where id = v_item and organization_id = v_org) then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  if jsonb_typeof(p->'lines') <> 'array' then raise exception 'POS_BAD_REQUEST: lines is a list'; end if;
  if jsonb_array_length(p->'lines') > 60 then raise exception 'POS_BAD_REQUEST: up to 60 ingredients in one recipe'; end if;
  delete from public.menu_item_recipes where menu_item_id = v_item and organization_id = v_org;
  for l in select * from jsonb_array_elements(p->'lines') loop
    v_ing := nullif(l->>'inventory_item_id', '')::uuid;
    if not exists (select 1 from public.inventory_items where id = v_ing and organization_id = v_org) then raise exception 'POS_NOT_FOUND: an ingredient in this recipe was not found'; end if;
    v_qty := nullif(l->>'qty', '')::numeric;
    if v_qty is null or v_qty <= 0 or v_qty > 100000 then raise exception 'POS_BAD_REQUEST: every ingredient needs a quantity above zero'; end if;
    v_w := coalesce(nullif(l->>'wastage_pct', '')::numeric, 0);
    if v_w < 0 or v_w > 90 then raise exception 'POS_BAD_REQUEST: wastage is 0 to 90 percent'; end if;
    insert into public.menu_item_recipes (organization_id, menu_item_id, inventory_item_id, qty_per_unit, wastage_pct, is_key, note)
    values (v_org, v_item, v_ing, v_qty, v_w, coalesce((l->>'is_key')::boolean, false), left(public.mb_clean(l->>'note'), 200))
    on conflict (menu_item_id, inventory_item_id) do update set qty_per_unit = excluded.qty_per_unit + menu_item_recipes.qty_per_unit,
      wastage_pct = excluded.wastage_pct, is_key = excluded.is_key or menu_item_recipes.is_key;
  end loop;
  return public.mb_recipe_json(v_org, v_item);
end $$;

CREATE OR REPLACE FUNCTION public.order_stock_consume(p_order uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare o public.orders%rowtype; r record; v_done numeric; v_seq integer; v_n integer := 0; v_k integer;
begin
  select * into o from public.orders where id = p_order;
  if not found or o.status not in ('sent_to_kitchen', 'ready', 'paid', 'delivered') then return 0; end if;
  -- an order already reversed (cancelled earlier in this transaction) never consumes again
  if exists (select 1 from public.stock_movements where ref_type = 'orders' and (ref_id = p_order::text or ref_id like p_order::text || '#%') and kind = 'sale_reversal') then return 0; end if;
  -- one consumer per order at a time
  perform pg_advisory_xact_lock(hashtextextended('order_stock:' || p_order::text, 400));
  -- What the order needs per stock item, against what the ledger already took for it. The first consumption writes one row per item
  -- (ref_id = the order id); a line added or increased later is consumed as a further row for just the difference (ref_id = order id#n), so
  -- it is consumed once and a repeat run adds nothing (H-06). Cancel puts back every row, whichever consumption wrote it.
  for r in
    select u.inventory_item_id, round(sum(u.need), 3) as need from (
      select rc.inventory_item_id, oi.qty * coalesce((select mv.recipe_factor from public.menu_item_variants mv where mv.menu_item_id = oi.menu_item_id and mv.name = oi.variant_name limit 1), 1) * rc.qty_per_unit * (1 + rc.wastage_pct / 100) as need
        from public.order_items oi
        join public.menu_item_recipes rc on rc.menu_item_id = oi.menu_item_id and rc.organization_id = o.organization_id
       where oi.order_id = o.id and oi.status <> 'cancelled'
      union all
      -- 0624 / 0626: a billed add-on uses its recipe (each ingredient, with wastage); one without a recipe uses its single ingredient;
      -- times how many of the add-on, times the dishes
      select coalesce(ar.inventory_item_id, ad.inventory_item_id),
             oi.qty * coalesce((a->>'qty')::numeric, 1) * coalesce(ar.qty_per_unit * (1 + ar.wastage_pct / 100), ad.consume_qty)
        from public.order_items oi
        cross join lateral jsonb_array_elements(case when jsonb_typeof(oi.add_ons) = 'array' then oi.add_ons else '[]'::jsonb end) a
        join public.menu_addons ad on ad.id::text = a->>'id' and ad.organization_id = o.organization_id
        left join public.menu_addon_recipes ar on ar.addon_id = ad.id
       where oi.order_id = o.id and oi.status <> 'cancelled' and a->>'kind' = 'addon'
         and (ar.addon_id is not null or (ad.inventory_item_id is not null and ad.consume_qty is not null))) u
     group by u.inventory_item_id
  loop
    select coalesce(-sum(quantity), 0), count(*) into v_done, v_seq from public.stock_movements
     where ref_type = 'orders' and kind = 'sale' and inventory_item_id = r.inventory_item_id and (ref_id = o.id::text or ref_id like o.id::text || '#%');
    continue when r.need - v_done <= 0;
    insert into public.stock_movements (organization_id, location_id, inventory_item_id, kind, quantity, ref_type, ref_id, note, created_by)
    values (o.organization_id, o.location_id, r.inventory_item_id, 'sale', -(r.need - v_done), 'orders',
            case when v_seq = 0 then o.id::text else o.id::text || '#' || v_seq end, o.display_no, o.created_by)
    on conflict do nothing;
    get diagnostics v_k = row_count;
    v_n := v_n + v_k;
  end loop;
  return v_n;
end $$;


-- ----------------------------------------------------------------------------------------------------------------------------
-- 0627_channel_prices.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0627: a dish's price on OneLocal, Zomato and Swiggy (founder, 29 Oct 2026: Price control shows Selling price, OneLocal, Zomato and Swiggy
-- prices). A dish without a channel price is sold there at its selling price. Set or cleared from Price control.
--   * menu_item_channel_prices; menu_channel_price_save; rcp_list rows: + channel_prices {onelocal, zomato, swiggy}
-- Safe to run again.

create table if not exists public.menu_item_channel_prices (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  menu_item_id uuid not null references public.menu_items(id) on delete cascade,
  channel text not null check (channel in ('onelocal', 'zomato', 'swiggy')),
  price numeric(10,2) not null check (price > 0 and price <= 100000),
  updated_by uuid,
  updated_at timestamptz not null default now(),
  primary key (menu_item_id, channel)
);
alter table public.menu_item_channel_prices enable row level security;
revoke all on public.menu_item_channel_prices from anon, authenticated;

-- set a dish's price on one channel, or clear it ("price": null) so the selling price applies there
create or replace function public.menu_channel_price_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.mb_org('menu', 'update'); v_item uuid := nullif(p->>'menu_item_id', '')::uuid; v_ch text := p->>'channel';
  v_price numeric := round(nullif(p->>'price', '')::numeric, 2);
begin
  if not exists (select 1 from public.menu_items where id = v_item and organization_id = v_org) then raise exception 'POS_NOT_FOUND: dish not found'; end if;
  if v_ch is null or v_ch not in ('onelocal', 'zomato', 'swiggy') then raise exception 'POS_BAD_REQUEST: choose OneLocal, Zomato or Swiggy'; end if;
  if v_price is null then
    delete from public.menu_item_channel_prices where menu_item_id = v_item and channel = v_ch;
  else
    if v_price <= 0 or v_price > 100000 then raise exception 'POS_BAD_REQUEST: enter a price above zero'; end if;
    insert into public.menu_item_channel_prices (organization_id, menu_item_id, channel, price, updated_by) values (v_org, v_item, v_ch, v_price, auth.uid())
    on conflict (menu_item_id, channel) do update set price = excluded.price, updated_by = excluded.updated_by, updated_at = now();
  end if;
  return jsonb_build_object('menu_item_id', v_item, 'channel_prices', coalesce((select jsonb_object_agg(channel, price) from public.menu_item_channel_prices
                                                                                   where menu_item_id = v_item and organization_id = v_org), '{}'::jsonb));
end $$;
revoke all on function public.menu_channel_price_save(jsonb) from public, anon;
grant execute on function public.menu_channel_price_save(jsonb) to authenticated;

-- ---- existing function, patched (live definition + the 0627 change) ----
CREATE OR REPLACE FUNCTION public.rcp_list(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare v_org uuid := public.mb_org('menu', 'update'); v_q text := lower(coalesce(public.mb_clean(p->>'q'), ''));
  v_items jsonb := '[]'; r record; j jsonb; v_with int := 0; v_sum numeric := 0; v_n int := 0;
begin
  for r in select m.id from public.menu_items m left join public.menu_categories c on c.id = m.category_id
            where m.organization_id = v_org and (v_q = '' or lower(m.name) like '%' || v_q || '%')
            order by c.sort_order nulls last, c.name, m.sort_order, m.name loop
    j := public.mb_recipe_json(v_org, r.id) - 'lines'
      -- 0627: its price on each channel where one is set (else the selling price applies)
      || jsonb_build_object('channel_prices', coalesce((select jsonb_object_agg(cp.channel, cp.price) from public.menu_item_channel_prices cp
                                                          where cp.menu_item_id = r.id and cp.organization_id = v_org), '{}'::jsonb));
    if (j->>'line_count')::int > 0 then
      v_with := v_with + 1;
      if j->>'food_cost_pct' is not null then v_sum := v_sum + (j->>'food_cost_pct')::numeric; v_n := v_n + 1; end if;
    end if;
    v_items := v_items || j;
  end loop;
  return jsonb_build_object('items', v_items,
    'summary', jsonb_build_object('dishes', jsonb_array_length(v_items), 'with_recipe', v_with, 'without_recipe', jsonb_array_length(v_items) - v_with,
                                  'avg_food_cost_pct', case when v_n > 0 then round(v_sum / v_n, 1) end),
    -- 0626: every add-on with its recipe figures (the recipe master's Add-ons)
    'addons', coalesce((select jsonb_agg(public.mb_addon_recipe_json(v_org, ad.id) - 'lines' order by g.sort_order, g.name, ad.sort_order, ad.name)
                          from public.menu_addons ad join public.menu_addon_groups g on g.id = ad.group_id
                         where ad.organization_id = v_org and ad.active and (v_q = '' or lower(ad.name) like '%' || v_q || '%')), '[]'::jsonb));
end $$;

-- ----------------------------------------------------------------------------------------------------------------------------
-- 0628_dish_without_addons.sql
-- ----------------------------------------------------------------------------------------------------------------------------
-- 0628: a dish without add-ons could not be ordered. 0624 wrote nullif(add_ons, '[]') into order_items.add_ons, which is NOT NULL
-- (default '[]'), so every plain dish was refused ("null value in column add_ons"), at a table and at the counter. Write '[]' instead.
-- The two functions that place dishes (pos_place_order, tbl_order_add) are rewritten in place from their live definitions.
do $$
declare r record; v_def text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('pos_place_order', 'tbl_order_add')
             and p.prosrc like '%nullif(e.x->''add_ons'', ''[]''::jsonb)%'
  loop
    v_def := replace(pg_get_functiondef(r.oid), 'nullif(e.x->''add_ons'', ''[]''::jsonb)', 'coalesce(e.x->''add_ons'', ''[]''::jsonb)');
    execute v_def;
  end loop;
end $$;

do $$
begin
  if exists (select 1 from pg_proc where proname in ('pos_place_order', 'tbl_order_add') and prosrc like '%nullif(e.x->''add_ons''%') then
    raise exception '0628: a function still writes a null add_ons';
  end if;
end $$;

-- tell the API about the new functions and tables
notify pgrst, 'reload schema';
commit;
