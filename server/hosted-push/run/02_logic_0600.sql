-- ==========================================================================================================================
-- HOSTED PUSH piece 02 (logic): run the pieces in number order, each whole file in its own SQL editor run.
-- One transaction: if it stops with an error, nothing in this piece has changed; send the error back and stop.
-- Project ywylhzcxuoeilygzdonx. Built by server/hosted-push/build.sh; checked on a copy of hosted (29 Oct 2026).
-- ==========================================================================================================================
begin;

-- ---- 0600_menu_recipes_ingredients.sql
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


notify pgrst, 'reload schema';
commit;
