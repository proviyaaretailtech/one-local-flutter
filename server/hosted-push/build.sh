#!/usr/bin/env bash
# Builds the one-time hosted push from this repo and the LOCAL test DB (reads only; never connects to hosted), as numbered pieces in
# hosted-push/run/: the Supabase SQL editor keeps only the first 65,536 characters of a script, so no piece is over 62,000.
# Each piece is one transaction; run them in number order.
#   logic: 0630 first (fixes stock coming in on hosted), then 0600-0611, 0629 (pos_order_view merged, right after the last migration
#          that replaces it), 0612-0628. Whole migrations only: a migration is never split across two pieces.
#   data:  Niks Cafe's menu set-up, ingredients, recipes, add-ons, combos, sizes, tables, suppliers and purchase orders (copied by id
#          from the local DB, one statement per table), dish photo links moved to hosted, then opening stock for 100 of each dish.
# Usage (Git Bash, from one-local-flutter/server): bash hosted-push/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=supabase_db_onelocal-local-db
OUT=hosted-push/run
CAP=62000
UNITS=$(mktemp -d)
trap 'rm -rf "$UNITS"' EXIT
rm -rf "$OUT" && mkdir -p "$OUT"
rm -f hosted-push/01a_logic_0600_0613.sql hosted-push/01b_logic_0614_0628.sql hosted-push/02_niks_cafe_data.sql hosted-push/01_logic_0600_0628.sql

# ---- units: one file each, in the order they must run; the name says logic or data
n=0
unit() { n=$((n + 1)); printf -v id '%03d' "$n"; cat > "$UNITS/$id-$1"; }
for m in 0630 0600 0601 0602 0603 0604 0605 0606 0607 0608 0609 0610 0611 0629 0612 0613 0614 0615 0616 0617 0618 0619 0620 0621 0622 0623 0624 0625 0626 0627 0628; do
  f=$(ls migrations/${m}_*.sql)
  unit "logic-$m" < <(printf '\n-- ---- %s\n' "$(basename "$f")"; grep -viE '^\s*(begin|commit)\s*;\s*$' "$f")
done
docker cp hosted-push/gen_niks_data.sql "$DB:/tmp/gen_niks_data.sql" > /dev/null
MSYS_NO_PATHCONV=1 docker exec "$DB" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -q -f /tmp/gen_niks_data.sql > "$UNITS/data.sql"
# one statement per table: each starts at its "-- <table>: ..." line
awk -v dir="$UNITS" -v start="$n" '/^-- [a-z_]+: /{k++; t=$2; sub(/:$/, "", t); f=sprintf("%s/%03d-data-%s", dir, start + k, t)} k{print > f}' "$UNITS/data.sql"
rm "$UNITS/data.sql"
n=$(ls "$UNITS" | wc -l)
unit "data-opening_stock" <<'EOF'

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
EOF

# ---- pack the units into pieces: in order, logic and data never share a piece, each piece under CAP characters
piece=0; kind=""; size=0; files=()
flush() {
  [ ${#files[@]} -eq 0 ] && return
  piece=$((piece + 1)); printf -v pn '%02d' "$piece"
  local first last name
  first=$(basename "${files[0]}" | cut -d- -f3-); last=$(basename "${files[-1]}" | cut -d- -f3-)
  name="${pn}_${kind}_${first}"; [ "$first" != "$last" ] && name="${name}_to_${last}"; name="$name.sql"
  {
    printf -- '-- ==========================================================================================================================\n'
    printf -- '-- HOSTED PUSH piece %s (%s): run the pieces in number order, each whole file in its own SQL editor run.\n' "$pn" "$kind"
    printf -- '-- One transaction: if it stops with an error, nothing in this piece has changed; send the error back and stop.\n'
    printf -- '-- Project ywylhzcxuoeilygzdonx. Built by server/hosted-push/build.sh; checked on a copy of hosted (29 Oct 2026).\n'
    printf -- '-- ==========================================================================================================================\n'
    echo 'begin;'
    cat "${files[@]}"
    printf '\nnotify pgrst, %s;\ncommit;\n' "'reload schema'"
  } > "$OUT/$name"
  files=(); size=0
}
for u in "$UNITS"/*; do
  k=$(basename "$u" | cut -d- -f2); s=$(wc -m < "$u")
  if [ "$k" != "$kind" ] || [ $((size + s + 900)) -gt $CAP ]; then flush; kind=$k; fi
  files+=("$u"); size=$((size + s))
done
flush

for f in "$OUT"/*.sql; do
  c=$(wc -m < "$f")
  [ "$c" -gt 65000 ] && { echo "TOO LONG: $f ($c)"; exit 1; }
  printf '%6d  %s\n' "$c" "$(basename "$f")"
done
