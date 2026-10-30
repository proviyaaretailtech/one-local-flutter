-- 0635: Ad credits, the whole flow, in rupees (founder, 30 Oct 2026: "Ad credits complete flow"; "there is no coin top ups, all the
-- wallets will be in rupees"; money comes in from the OneLocal wallet, or OneLocal gives credits).
--   1. One ad credit is one rupee: ol_ads_config.coin_rupees 10 -> 1, and every price, budget and balance kept in coins is multiplied by 10,
--      so each ad costs what it cost before. Runs once (only while coin_rupees is 10).
--   2. No top-ups: ads_topup refuses and says where ad credits come from.
--   3. Move money from the OneLocal wallet into ad credits (ads_wallet_move): at most what OneLocal owes the business for app orders and
--      has not settled yet, less what the business owes OneLocal. The move is taken off the next weekly settlement (finance_run_settlement
--      subtracts it like a shortfall, so a week too small carries the rest forward), and the wallet shows the due without it at once.
--   4. OneLocal's side (platform admins only): ol_admin_me says who is one; ads_admin_queue lists the ads waiting for OneLocal, the
--      businesses to give credits to, and the credits given. ads_admin_review, ads_admin_offer and ads_grant already do the work.
-- The ads system lives only where the store team built it (hosted); without it, parts 1, 2 and the ad-credit insert are skipped.

-- ---------------------------------------------------------------------------------------------------------------- 3. the moves
create table if not exists public.ad_credit_moves (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  amount_minor bigint not null check (amount_minor > 0),
  idempotency_key text not null,
  ledger_id uuid,
  settlement_id uuid references public.settlements(id) on delete set null,   -- null until a weekly settlement takes it off
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (organization_id, idempotency_key)
);
create index if not exists ad_credit_moves_open_idx on public.ad_credit_moves (organization_id) where settlement_id is null;
alter table public.ad_credit_moves enable row level security;
revoke all on public.ad_credit_moves from anon, authenticated;
alter table public.settlements add column if not exists ad_credits_minor bigint not null default 0;

-- the wallet: the due without what was moved to ad credits and not settled yet
do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('public.wallet_overview(jsonb)'::regprocedure);
  if position('ad_credit_moves' in v_def) > 0 then return; end if;
  v_new := replace(v_def, '  select coalesce(sum(amount_minor) filter (where status in (''pending'', ''approved'')), 0),',
    '  -- 0635: money moved to ad credits comes off the due now and off the next settlement
  v_due := v_due - coalesce((select sum(m.amount_minor) from public.ad_credit_moves m where m.organization_id = v_org and m.settlement_id is null), 0);
  select coalesce(sum(amount_minor) filter (where status in (''pending'', ''approved'')), 0),');
  v_new := replace(v_new, '''owed_to_onelocal'', jsonb_build_object(',
    '''ad_credits_moved'', jsonb_build_object(''amount_minor'', coalesce((select sum(m.amount_minor) from public.ad_credit_moves m where m.organization_id = v_org and m.settlement_id is null), 0)),
    ''owed_to_onelocal'', jsonb_build_object(');
  if v_new = v_def or (length(v_new) - length(v_def)) < 300 then raise exception '0635: wallet_overview is not the expected definition'; end if;
  execute v_new;
end $$;

-- the weekly settlement: takes off the moves made before the week ended, once
do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('public.finance_run_settlement(uuid, date, date)'::regprocedure);
  if position('ad_credit_moves' in v_def) > 0 then return; end if;
  v_new := replace(v_def, 'v_dprev uuid; v_din bigint := 0;', 'v_dprev uuid; v_din bigint := 0; v_ads bigint := 0;');
  v_new := replace(v_new, '  v_net_raw := v_food - v_claw - v_payable - v_cgst - v_din;',
    '  -- 0635: money the business moved from its wallet to ad credits, up to the end of this week, is taken off here once
  with taken as (update public.ad_credit_moves m set settlement_id = v_id
                  where m.organization_id = p_org and m.settlement_id is null and (m.created_at at time zone v_tz)::date <= p_end returning m.amount_minor)
  select coalesce(sum(amount_minor), 0) into v_ads from taken;
  v_net_raw := v_food - v_claw - v_payable - v_cgst - v_din - v_ads;');
  v_new := replace(v_new, 'debt_in_minor = v_din,', 'debt_in_minor = v_din, ad_credits_minor = v_ads,');
  if (length(v_new) - length(v_def)) < 350 then raise exception '0635: finance_run_settlement is not the expected definition'; end if;
  execute v_new;
end $$;

create or replace function public.ads_wallet_move(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_org uuid := public.current_org_id(); v_amt bigint; v_key text := nullif(btrim(coalesce(p->>'idempotency_key', '')), '');
  w jsonb; v_free bigint; m public.ad_credit_moves; v_ledger uuid;
begin
  if auth.uid() is null or v_org is null then raise exception 'SF_FORBIDDEN: sign in to a business first'; end if;
  if not public.has_org_role(array['org_owner', 'org_admin']) then raise exception 'SF_FORBIDDEN: only the owner can move money into ad credits'; end if;
  if to_regclass('public.ol_coin_ledger') is null then raise exception 'SF_WRONG_STATE: ads are not open here yet'; end if;
  if v_key is null or length(v_key) < 8 then raise exception 'SF_BAD_REQUEST: a request key is needed'; end if;
  perform pg_advisory_xact_lock(hashtext('ad-credits:' || v_org::text));
  select * into m from public.ad_credit_moves where organization_id = v_org and idempotency_key = v_key;
  if found then return jsonb_build_object('id', m.id, 'amount_minor', m.amount_minor, 'replayed', true); end if;
  begin v_amt := (p->>'amount_minor')::bigint; exception when others then v_amt := null; end;
  if v_amt is null or v_amt < 10000 or v_amt % 100 <> 0 then raise exception 'SF_BAD_REQUEST: move whole rupees, at least ₹100'; end if;
  w := public.wallet_overview('{}'::jsonb);   -- its due already leaves out earlier moves
  v_free := greatest(0, coalesce((w->'unsettled'->>'due_minor')::bigint, 0) - coalesce((w->'owed_to_onelocal'->>'amount_minor')::bigint, 0));
  if v_amt > v_free then raise exception 'SF_BAD_REQUEST: only % can be moved from your OneLocal wallet now', public.notice_money(v_free / 100.0, 'INR'); end if;
  execute 'insert into public.ol_coin_ledger (organization_id, kind, coins, status, bucket, amount_minor, method, note, created_by)
           values ($1, ''topup'', $2, ''done'', ''purchased'', $3, ''wallet'', ''From your OneLocal wallet'', $4) returning id'
    into v_ledger using v_org, v_amt / 100, v_amt, auth.uid();
  execute 'update public.ol_coin_ledger set ref = ''OLW-'' || upper(substr(replace(id::text, ''-'', ''''), 1, 8)) where id = $1' using v_ledger;
  insert into public.ad_credit_moves (organization_id, amount_minor, idempotency_key, ledger_id, created_by)
  values (v_org, v_amt, v_key, v_ledger, auth.uid()) returning * into m;
  return jsonb_build_object('id', m.id, 'amount_minor', m.amount_minor, 'replayed', false);
end $$;
revoke all on function public.ads_wallet_move(jsonb) from public, anon;
grant execute on function public.ads_wallet_move(jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------- 4. OneLocal's side
create or replace function public.ol_admin_me(p jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('admin', auth.uid() is not null and public.is_platform_admin());
$$;
revoke all on function public.ol_admin_me(jsonb) from public, anon;
grant execute on function public.ol_admin_me(jsonb) to authenticated, service_role;

create or replace function public.ads_admin_queue(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_q text := nullif(btrim(coalesce(p->>'q', '')), ''); v_review jsonb; v_grants jsonb;
begin
  if auth.uid() is null or not public.is_platform_admin() then raise exception 'SF_FORBIDDEN: only OneLocal can do this'; end if;
  if to_regclass('public.pos_ad_requests') is null then
    return jsonb_build_object('review', '[]'::jsonb, 'businesses', '[]'::jsonb, 'grants', '[]'::jsonb);
  end if;
  -- ads waiting for OneLocal: the check of the ad, then its price
  execute $q$select coalesce(jsonb_agg(public.ads__json(a) || jsonb_build_object('business', o.name) order by a.submitted_at nulls last, a.created_at), '[]'::jsonb)
             from public.pos_ad_requests a join public.organizations o on o.id = a.organization_id
            where a.deleted_at is null and a.stage in ('under_review', 'approved') and a.accepted_at is null$q$ into v_review;
  execute $q$select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'business', o.name, 'amount', l.coins, 'note', l.note, 'created_at', l.created_at)
                    order by l.created_at desc), '[]'::jsonb)
             from (select * from public.ol_coin_ledger where kind = 'promo' order by created_at desc limit 20) l join public.organizations o on o.id = l.organization_id$q$
    into v_grants;
  return jsonb_build_object(
    'review', v_review,
    'businesses', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'credits', (public.ads__balances(o.id)->>'available')::numeric) order by o.name)
                            from (select id, name from public.organizations where v_q is not null and name ilike '%' || v_q || '%' order by name limit 20) o), '[]'::jsonb),
    'grants', v_grants);
end $$;
revoke all on function public.ads_admin_queue(jsonb) from public, anon;
grant execute on function public.ads_admin_queue(jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------- 1 and 2: rupees, no top-ups
do $$
declare v_def text;
begin
  if to_regclass('public.ol_ads_config') is null then return; end if;
  if (select coin_rupees from public.ol_ads_config limit 1) <> 10 then return; end if;   -- already in rupees
  update public.ol_ads_config set coin_rupees = 1, reel_coins = reel_coins * 10, banner_coins = banner_coins * 10, popup_coins = popup_coins * 10;
  update public.ad_commercial_rules set rate_coins = rate_coins * 10, min_budget_coins = min_budget_coins * 10, max_budget_coins = max_budget_coins * 10,
         daily_cap_coins = daily_cap_coins * 10;
  update public.pos_ad_requests set rate_coins = rate_coins * 10, budget_coins = budget_coins * 10, daily_cap_coins = daily_cap_coins * 10, coins = coins * 10;
  update public.ad_events set charged_coins = charged_coins * 10;
  update public.ol_coin_ledger set coins = coins * 10;
  update public.ad_disputes set coins = coins * 10, credited_coins = credited_coins * 10;
  update public.ol_ad_daily set spent_coins = spent_coins * 10;
end $$;

-- the words the business reads: rupees, not coins (rewrites only what still says coins, so it can run again)
do $$
declare f text; v_def text; v_new text;
begin
  if to_regclass('public.ol_coin_ledger') is null then return; end if;
  foreach f in array array['ads_save', 'ads_fund', 'ads_dispute', 'ads_grant'] loop
    v_def := pg_get_functiondef(('public.' || f || '(jsonb)')::regprocedure);
    v_new := replace(v_def, 'Set the most coins this campaign can spend', 'Set the most this campaign can spend');
    v_new := replace(v_new, 'The budget is at least % coins', 'The budget is at least ₹%');
    v_new := replace(v_new, 'The budget is at most % coins', 'The budget is at most ₹%');
    v_new := replace(v_new, 'This campaign needs % coins and you have %. Top up first.', 'This campaign needs ₹% and your ad credits are ₹%. Add credits first.');
    v_new := replace(v_new, 'this campaign is not waiting for coins', 'this campaign is not waiting for ad credits');
    v_new := replace(v_new, 'You can dispute up to the coins this campaign has spent', 'You can dispute up to what this campaign has spent');
    v_new := replace(v_new, 'organization and coins are needed', 'choose the business and the amount');
    if v_new <> v_def then execute v_new; end if;
  end loop;
end $$;

do $$
begin
  if to_regclass('public.ol_coin_ledger') is null then return; end if;
  execute $f$create or replace function public.ads_topup(p jsonb) returns jsonb
    language plpgsql security definer set search_path = public, pg_temp as $b$
    begin
      raise exception 'SF_BAD_REQUEST: Add ad credits from your OneLocal wallet';
    end $b$
  $f$;
end $$;
