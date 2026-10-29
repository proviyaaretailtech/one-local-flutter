# One-time push to the hosted DB (29 Oct 2026)

Brings the hosted project `ywylhzcxuoeilygzdonx` up to the local test DB: migrations 0600-0628 (all the logic since the 26 Oct copy of
hosted) and Niks Cafe's set-up. Both SQL files are one transaction each: if one stops with an error, nothing in it has changed.

Checked before handing over, on a copy of the hosted DB (its 26 Oct dump) inside the local Docker:
- `01` applies without errors as the `postgres` role (the role the SQL editor uses) and leaves the same tables, columns, functions,
  triggers, indexes and policies as the local test DB.
- `02` applies without errors, and a second run changes nothing (no duplicate stock or events).
- Every function the server allows (267) was called as Niks Cafe's hosted owner: no "permission denied" or missing table.
- A full kitchen day (table orders, KDS start / item done / ready, takeaway, delivery), recipes, money and tables work as that owner.

## Order
1. **SQL editor → run `01_logic_0600_0628.sql`** (whole file). Expect "Success. No rows returned".
2. **SQL editor → run `02_niks_cafe_data.sql`** (whole file).
3. **Storage → `item-images` bucket → upload the folder `item-images/bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd`** (drag the whole folder in,
   so each photo lands at `bd4d8ee9-…/items/<dish id>/<photo>.jpg`). 11 photos, 1.4 MB. The dishes already point at these paths.
   This folder is not committed (business photos); it is rebuilt from the local storage, see below.
4. Tell Claude; the server code is then pushed to `main` (Vercel deploys it) and the app is switched to hosted.

The server must not be deployed before step 1: the new server code calls functions that step 1 creates.

## Rebuild
`bash hosted-push/build.sh` (Git Bash, in `server/`) rebuilds both SQL files from `migrations/` and the local DB. The photos come from the
local storage: `item-images/` was filled with one `curl` per object of the local `item-images` bucket.

## Not copied on purpose
Orders, KOTs, payments, bills, the test login, closing-stock test counts, notifications, outlet settings and counters.
