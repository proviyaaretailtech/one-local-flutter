# One-time push to the hosted DB (29 Oct 2026)

Brings the hosted project `ywylhzcxuoeilygzdonx` up to the local test DB: migrations 0600-0630 and Niks Cafe's set-up, in ten SQL
pieces (`run/`). Each piece is one transaction: if one stops with an error, nothing in it has changed.

## Checked against today's hosted (read-only dump of 29 Oct 2026, 23:16), on a copy inside the local Docker
- Since 26 Oct the store team changed 24 functions on hosted and added 136. My files replace 15 functions; 13 of those are unchanged on
  hosted since 26 Oct, so nothing of theirs is lost. The other two were changed by both sides and are merged:
  - `pos_order_view` (0629): keeps their packed-bag photo fields and adds the dish size and takeaway flag.
  - `stock_movement_allocate` (0630): their negative-stock version fails on **every** movement that adds stock ("record "s" is not
    assigned yet": a loop variable `s` clashes with a table alias `s`). Live on hosted now: receiving goods, opening stock and stock
    coming back from a cancelled order all fail. 0630 renames the variable; nothing else changes.
- The ten pieces apply in order without errors as the `postgres` role (the role the SQL editor uses). Afterwards every table,
  column, trigger, index, policy, constraint and grant of today's hosted is still there unchanged, apart from the two merges above.
- Every function the merged server allows (353) was called as a Niks Cafe owner: no "permission denied", no missing table or column.
  A full kitchen day, the order page, recipes, money, tables and stock coming in all work.
- **Niks Cafe has no members on hosted today** (its owner's login was deleted since 26 Oct). The data goes in, but nobody can sign in
  to it until an account is attached as its owner.

## Order
Run the pieces in `run/` in number order, each **whole file in its own SQL editor run** (the editor keeps only the first 65,536
characters of a script, so each piece is under 62,000). Each ends with "Success. No rows returned". If one fails, nothing in it changed:
stop and send the error.
1. `01_logic_0630.sql`: fixes stock coming in on hosted (run it first; it is small).
2. `02` to `08` (logic): migrations 0600-0628, with 0629 inside `04`.
3. `09` and `10` (Niks Cafe data, then opening stock).
4. **Storage → `item-images` bucket → upload the folder `item-images/bd4d8ee9-5885-41e4-b6a1-ba2b9cb873dd`** (drag the whole folder in,
   so each photo lands at `bd4d8ee9-…/items/<dish id>/<photo>.jpg`). 11 photos, 1.4 MB. Not committed (business photos).
5. Tell Claude; the server code is then pushed to `main` (Vercel deploys it) and the app is switched to hosted.

The server must not be deployed before pieces 01-08 are in: the new server code calls functions they create.

## Rebuild
`bash hosted-push/build.sh` (Git Bash, in `server/`) rebuilds the pieces from `migrations/` and the local DB. The photos come
from the local storage: `item-images/` was filled with one `curl` per object of the local `item-images` bucket.

## Not copied on purpose
Orders, KOTs, payments, bills, the test login, closing-stock test counts, notifications, outlet settings and counters.
