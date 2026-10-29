#!/usr/bin/env bash
# Builds the two one-time hosted push files from this repo and the LOCAL test DB (reads only; never connects to hosted).
#   01_logic_0600_0628.sql   migrations 0600-0628 in order, one transaction
#   02_niks_cafe_data.sql    Niks Cafe's menu set-up, ingredients, recipes, add-ons, combos, sizes, tables, suppliers and purchase
#                            orders (copied by id from the local DB), dish photo links moved to hosted, and opening stock for 100 of
#                            each dish (posted as receipts, worked out on hosted from the recipes)
# Usage (Git Bash, from one-local-flutter/server): bash hosted-push/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=supabase_db_onelocal-local-db
OUT=hosted-push

{
  cat <<'EOF'
-- ============================================================================================================================
-- HOSTED PUSH 1 of 2: LOGIC. Migrations 0600-0628 (29 files) in order, as ONE transaction: all of it applies, or none of it.
-- Built from server/migrations by hosted-push/build.sh. Run it in the Supabase SQL editor of project ywylhzcxuoeilygzdonx
-- BEFORE 02_niks_cafe_data.sql and before the server is deployed. Checked on a copy of the hosted DB (dump of 26 Oct 2026):
-- applies without errors and leaves the same tables, functions, triggers, indexes and policies as the local test DB.
-- Run it once. If it stops with an error, nothing has changed; send the error back.
-- ============================================================================================================================
begin;
EOF
  for f in migrations/06*.sql; do
    printf '\n-- ----------------------------------------------------------------------------------------------------------------------------\n-- %s\n-- ----------------------------------------------------------------------------------------------------------------------------\n' "$(basename "$f")"
    grep -viE '^\s*(begin|commit)\s*;\s*$' "$f"
  done
  cat <<'EOF'

-- tell the API about the new functions and tables
notify pgrst, 'reload schema';
commit;
EOF
} > "$OUT/01_logic_0600_0628.sql"

docker cp "$OUT/gen_niks_data.sql" "$DB:/tmp/gen_niks_data.sql" > /dev/null
{
  cat <<'EOF'
-- ============================================================================================================================
-- HOSTED PUSH 2 of 2: NIKS CAFE DATA (organization bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd), as ONE transaction.
-- Run AFTER 01_logic_0600_0628.sql, in the Supabase SQL editor of project ywylhzcxuoeilygzdonx.
-- Copied by id from the local test DB (hosted-push/build.sh): categories, dishes (descriptions, sizes, photo links on hosted
-- storage), ingredients, recipes, add-ons, add-on recipes, combos, channel prices, the five tables, suppliers and purchase orders.
-- Not copied: orders, KOTs, payments, bills, test logins, closing-stock test counts, notifications.
-- Then opening stock: enough for 100 of each dish (with wastage), less what is on hand, posted as receipts.
-- The 11 dish photo FILES are uploaded separately (hosted-push/item-images/, see README.md).
-- Running it twice is safe: rows are matched by id and the opening stock only tops up what is missing.
-- ============================================================================================================================
begin;

EOF
  MSYS_NO_PATHCONV=1 docker exec "$DB" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -q -f /tmp/gen_niks_data.sql
  cat <<'EOF'

-- opening stock: what 100 of every dish needs (with wastage), less what is on hand, at the main outlet
insert into public.stock_movements (organization_id, location_id, inventory_item_id, kind, quantity, unit_cost_minor, ref_type, ref_id, note)
select n.org, (select l.id from public.locations l where l.organization_id = n.org order by (l.code = 'MAIN') desc, l.created_at limit 1),
       n.item, 'receipt', n.need - n.on_hand, coalesce(p.cost_minor, 0), 'opening_stock', 'ai-recipes-100', 'Opening stock for 100 of each dish'
  from (select mr.organization_id as org, mr.inventory_item_id as item,
               ceil(sum(100 * mr.qty_per_unit * (1 + mr.wastage_pct / 100)) * 1000) / 1000 as need,
               public.mb_on_hand(mr.organization_id, mr.inventory_item_id) as on_hand
          from public.menu_item_recipes mr where mr.organization_id = 'bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd'
         group by mr.organization_id, mr.inventory_item_id) n
  left join public.ingredient_profiles p on p.inventory_item_id = n.item
 where n.need - n.on_hand > 0;

set constraints all immediate; -- place the new stock in its bins now

notify pgrst, 'reload schema';
commit;
EOF
} > "$OUT/02_niks_cafe_data.sql"

wc -c "$OUT"/0*.sql
