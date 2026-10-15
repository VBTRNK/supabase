-- ADR-164 / #223 S1: Regular, Silver and Gold packs on one canonical draw.
--
-- * kut.pack_draw_pool() is the only definition of the eligible Live pool,
--   its weights (100/60/30/12/4/1 per Player) and discard values. open_pack
--   materializes it once per opening; kut.pack_metrics() computes exact
--   guarantee-aware expectations from the same rows for admin health.
-- * A pack with a min_tier draws its first cards normally and restricts only
--   its last card to Players at or above that tier, when no earlier card met
--   it. Duplicates and low companions stay possible. An empty qualifying pool
--   fails before any debit or mint.
-- * Openings snapshot slug, title and floor; each slot snapshots the tier and
--   OVR it was drawn at. Older openings keep their recorded title and price;
--   their drawn tier/OVR stay null (never recorded, never inferred).
-- * Prices and Silver/Gold availability change only through the audited,
--   revisioned kut.admin_apply_pack_settings. Direct writes are revoked. The
--   75% / 10% / round-up-25 suggestions are advisory and never block a save
--   or a purchase.
-- * Silver (500) and Gold (750) are seeded OFF. The current shop lists every
--   active offer without its guarantee, so Silver is switched on by an admin
--   once the S2 shop is live (deviation from "seed Silver on", see the PR).
-- * Views only gain columns, at the end. my_pack_opening_results now LEFT
--   joins the definition: a member's invoker read of an opening must not
--   vanish when its pack is switched off.
--
-- Cohort for usage, wallets and flows: enabled, non-superadmin profiles (no
-- explicit test-account marker exists). Market and trade transfers and
-- escrow are not sinks; the market tax and the trade tax are.
--
-- Rollback (before Silver/Gold openings exist): re-emit open_pack from
-- 20260918000000 with 'insufficient KUT Coins', the three views from their
-- sources (20261018000000, 20260928000000, 20260816070500; drop and recreate
-- active_pack_offers and pack_economy_health), drop the new functions, table,
-- columns and constraint, restore the admin ALL policy, rename the pack back.

-- 1. Definitions --------------------------------------------------------------

do $$
begin
  if (select count(*) from kut.pack_definitions) <> 1
     or not exists (select 1 from kut.pack_definitions where slug = 'tfh-pack' and is_active) then
    raise exception 'expected exactly one active tfh-pack definition';
  end if;
end;
$$;

alter table kut.pack_definitions
  add column min_tier text check (min_tier in ('silver', 'gold')),
  add constraint pack_definitions_regular_always_on check (slug <> 'tfh-pack' or is_active);

alter table kut.pack_openings
  add column pack_slug text,
  add column pack_title text,
  add column min_tier text check (min_tier in ('silver', 'gold'));

alter table kut.pack_opening_cards
  add column opened_tier text check (opened_tier in ('common', 'bronze', 'silver', 'gold', 'holo', 'elite')),
  add column opened_ovr integer check (opened_ovr between 0 and 99),
  add column floor_draw boolean not null default false;

-- Historical receipts keep the name they were bought under.
update kut.pack_openings opening
set pack_slug = pack.slug, pack_title = pack.title
from kut.pack_definitions pack
where pack.id = opening.pack_id;

update kut.pack_definitions set title = 'Regular pack', updated_at = now() where slug = 'tfh-pack';

insert into kut.pack_definitions (slug, title, price, cards_per_pack, is_active, min_tier) values
  ('tfh-silver-pack', 'Silver pack', 500, 3, false, 'silver'),
  ('tfh-gold-pack', 'Gold pack', 750, 3, false, 'gold');

-- Only the settings RPC writes definitions.
drop policy "admins manage pack definitions" on kut.pack_definitions;
revoke insert, update, delete, truncate on kut.pack_definitions from public, anon, authenticated;

create table kut.pack_settings_changes (
  revision bigint primary key check (revision > 0),
  changed_by uuid references kut.profiles(id) on delete set null,
  changed_at timestamptz not null default now(),
  before jsonb,
  after jsonb not null
);

comment on table kut.pack_settings_changes is
  'ADR-164. One row per applied pack price/availability change; the highest revision is the edit-conflict token. Written only by kut.admin_apply_pack_settings.';

alter table kut.pack_settings_changes enable row level security;
revoke all on kut.pack_settings_changes from public, anon, authenticated;
grant select on kut.pack_settings_changes to authenticated, service_role;
create policy "admins read pack settings changes" on kut.pack_settings_changes
  for select to authenticated using (kut.is_admin());
create policy "active membership required for reads" on kut.pack_settings_changes
  as restrictive for select to authenticated using ((select kut.is_active_member()));

insert into kut.pack_settings_changes (revision, changed_by, before, after)
select 1, null, null, jsonb_object_agg(slug, jsonb_build_object('price', price, 'is_active', is_active))
from kut.pack_definitions;

-- 2. Canonical pool -----------------------------------------------------------

create function kut.pack_tier_rank(p_tier text)
returns integer
language sql
immutable
set search_path = kut, pg_catalog
as $$
  select case p_tier
    when 'common' then 0 when 'bronze' then 1 when 'silver' then 2
    when 'gold' then 3 when 'holo' then 4 when 'elite' then 5
  end
$$;

create function kut.pack_draw_pool()
returns table (
  edition_id uuid,
  player_id uuid,
  tier text,
  tier_rank integer,
  ovr integer,
  weight integer,
  discard_value bigint
)
language sql
stable
set search_path = kut, pg_catalog
as $$
  select
    edition.id,
    player.id,
    rating.tier,
    kut.pack_tier_rank(rating.tier),
    rating.ovr,
    case rating.tier
      when 'common' then 100 when 'bronze' then 60 when 'silver' then 30
      when 'gold' then 12 when 'holo' then 4 when 'elite' then 1
    end,
    round(10 * power(1.08::numeric, rating.ovr - 30))::bigint
  from kut.card_editions edition
  join kut.players player on player.id = edition.player_id
  left join kut.seasons active_season on active_season.is_active
  left join kut.player_season_state state
    on state.player_id = player.id and state.season_id = active_season.id
  cross join lateral (
    select coalesce(state.rarity_tier, 'common') as tier, coalesce(state.live_ovr, 30) as ovr
  ) rating
  where edition.is_live
    and edition.edition_type = 'live'
    and player.is_active
    and player.is_collectible
$$;

comment on function kut.pack_draw_pool() is
  'ADR-164. The eligible Live pool with its draw weight, tier and discard value. The single source for open_pack and kut.pack_metrics; internal only.';

revoke all on function kut.pack_tier_rank(text), kut.pack_draw_pool() from public, anon, authenticated;
grant execute on function kut.pack_tier_rank(text), kut.pack_draw_pool() to service_role;


-- 3. Exact guarantee-aware expectations --------------------------------------
-- With n cards, floor rank f, r(k) the pool's weight share at rank >= k,
-- q = r(f) and a = (1 - q)^(n-1), the chance that no earlier card met the
-- floor (a = 0 without a floor):
--   expected copies at rank >= t = (n - a) r(t) + a r(max(t, f)) / q
--   expected discard             = (n - a) D(0) + a D(f) / q, where D(k) sums
--                                  weight share x discard value at rank >= k
--   P(no card at rank >= t)      = (1 - r(t))^n without a floor; 0 if t <= f;
--     otherwise a (q - r(t)) / q + ((1 - r(t))^(n-1) - a) (1 - r(t))
-- Only admins receive rows. A pack whose floor has no qualifying Player, or an
-- empty pool, returns null expectations rather than a cheap-looking zero.
create function kut.pack_metrics()
returns table (
  slug text,
  title text,
  price bigint,
  cards_per_pack integer,
  is_active boolean,
  min_tier text,
  eligible_count integer,
  qualifying_count integer,
  expected_discard_per_slot numeric,
  expected_discard_per_pack numeric,
  expected_silver_plus numeric,
  expected_gold_plus numeric,
  expected_holo_plus numeric,
  expected_elite numeric,
  chance_silver_plus numeric,
  chance_gold_plus numeric,
  chance_holo_plus numeric,
  chance_elite numeric
)
language plpgsql
stable
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_ranks integer[];
  v_weights numeric[];
  v_discards numeric[];
  v_w numeric[] := array_fill(0::numeric, array[6]);
  v_d numeric[] := array_fill(0::numeric, array[6]);
  v_n integer[] := array_fill(0, array[6]);
  v_total numeric;
  v_pack record;
  v_f integer;
  v_q numeric;
  v_a numeric;
  v_r numeric;
  v_expected numeric[];
  v_chance numeric[];
  i integer;
  k integer;
begin
  if not kut.is_admin() then
    return;
  end if;

  select coalesce(array_agg(pool.tier_rank), '{}'),
         coalesce(array_agg(pool.weight::numeric), '{}'),
         coalesce(array_agg(pool.discard_value::numeric), '{}')
  into v_ranks, v_weights, v_discards
  from kut.pack_draw_pool() pool
  where pool.weight > 0;

  -- Index k + 1 holds the total at rank >= k.
  for i in 1..coalesce(cardinality(v_ranks), 0) loop
    for k in 0..v_ranks[i] loop
      v_w[k + 1] := v_w[k + 1] + v_weights[i];
      v_d[k + 1] := v_d[k + 1] + v_weights[i] * v_discards[i];
      v_n[k + 1] := v_n[k + 1] + 1;
    end loop;
  end loop;
  v_total := v_w[1];

  for v_pack in
    select pack.slug, pack.title, pack.price, pack.cards_per_pack, pack.is_active, pack.min_tier
    from kut.pack_definitions pack
    order by pack.price, pack.slug
  loop
    slug := v_pack.slug;
    title := v_pack.title;
    price := v_pack.price;
    cards_per_pack := v_pack.cards_per_pack;
    is_active := v_pack.is_active;
    min_tier := v_pack.min_tier;
    eligible_count := v_n[1];
    v_f := kut.pack_tier_rank(v_pack.min_tier);
    qualifying_count := v_n[coalesce(v_f, 0) + 1];
    expected_discard_per_slot := case when v_total > 0 then v_d[1] / v_total end;
    v_expected := array_fill(null::numeric, array[5]);
    v_chance := array_fill(null::numeric, array[5]);
    expected_discard_per_pack := null;

    if v_total > 0 and qualifying_count > 0 then
      v_q := case when v_f is null then 1 else v_w[v_f + 1] / v_total end;
      v_a := case when v_f is null then 0 else power(1 - v_q, v_pack.cards_per_pack - 1) end;
      expected_discard_per_pack := (v_pack.cards_per_pack - v_a) * v_d[1] / v_total
        + case when v_a > 0 then v_a * (v_d[v_f + 1] / v_total) / v_q else 0 end;
      for k in 2..5 loop
        v_r := v_w[k + 1] / v_total;
        v_expected[k] := (v_pack.cards_per_pack - v_a) * v_r
          + case when v_a > 0 then v_a * (v_w[greatest(k, v_f) + 1] / v_total) / v_q else 0 end;
        v_chance[k] := 1 - case
          when v_f is null then power(1 - v_r, v_pack.cards_per_pack)
          when k <= v_f then 0
          else v_a * (v_q - v_r) / v_q + (power(1 - v_r, v_pack.cards_per_pack - 1) - v_a) * (1 - v_r)
        end;
      end loop;
    end if;

    expected_silver_plus := v_expected[2];
    expected_gold_plus := v_expected[3];
    expected_holo_plus := v_expected[4];
    expected_elite := v_expected[5];
    chance_silver_plus := v_chance[2];
    chance_gold_plus := v_chance[3];
    chance_holo_plus := v_chance[4];
    chance_elite := v_chance[5];
    return next;
  end loop;
end;
$$;

comment on function kut.pack_metrics() is
  'ADR-164. Exact per-pack expectations (discard, Silver+/Gold+/Holo+/Elite copies and chances) from kut.pack_draw_pool and the conditional last-card rule, for every definition including inactive ones. Admin rows only.';

revoke all on function kut.pack_metrics() from public, anon;
grant execute on function kut.pack_metrics() to authenticated, service_role;

-- Advisory price suggestions (issue #223): R* = max(current Regular price,
-- roundUp25(Regular discard / 0.75)); a premium is roundUp25(max(its discard
-- / 0.75, R* x its largest per-pack value ratio to Regular / 0.90)) over
-- cards, discard and Silver+/Gold+/Holo+/Elite copies. A 0/0 ratio is ignored;
-- a premium outcome Regular cannot produce has no finite suggestion.
create function kut._pack_round_up_25(p_value numeric)
returns bigint
language sql
immutable
set search_path = kut, pg_catalog
as $$
  -- Rounding first keeps an exact multiple from tipping up on the last digit.
  select (ceil(round(p_value / 25, 9)) * 25)::bigint
$$;

create function kut.pack_price_suggestions()
returns table (slug text, suggested_price bigint, suggestion_state text, value_ratio numeric)
language plpgsql
stable
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_regular record;
  v_pack record;
  v_regular_price bigint;
  v_ratio numeric;
  v_unsupported boolean;
  v_pairs numeric[][];
  i integer;
begin
  if not kut.is_admin() then
    return;
  end if;
  select * into v_regular from kut.pack_metrics() m where m.slug = 'tfh-pack';
  if v_regular.slug is not null and v_regular.expected_discard_per_pack is not null then
    v_regular_price := greatest(v_regular.price, kut._pack_round_up_25(v_regular.expected_discard_per_pack / 0.75));
  end if;

  for v_pack in select * from kut.pack_metrics() m loop
    slug := v_pack.slug;
    suggested_price := null;
    value_ratio := null;
    if v_regular_price is null or v_pack.expected_discard_per_pack is null then
      suggestion_state := 'unavailable';
    elsif v_pack.slug = 'tfh-pack' then
      suggestion_state := 'suggested';
      suggested_price := v_regular_price;
      value_ratio := 1;
    else
      v_pairs := array[
        [v_pack.cards_per_pack::numeric, v_regular.cards_per_pack::numeric],
        [v_pack.expected_discard_per_pack, v_regular.expected_discard_per_pack],
        [v_pack.expected_silver_plus, v_regular.expected_silver_plus],
        [v_pack.expected_gold_plus, v_regular.expected_gold_plus],
        [v_pack.expected_holo_plus, v_regular.expected_holo_plus],
        [v_pack.expected_elite, v_regular.expected_elite]
      ];
      v_ratio := 0;
      v_unsupported := false;
      for i in 1..6 loop
        if v_pairs[i][2] = 0 then
          v_unsupported := v_unsupported or v_pairs[i][1] > 0;
        else
          v_ratio := greatest(v_ratio, v_pairs[i][1] / v_pairs[i][2]);
        end if;
      end loop;
      if v_unsupported then
        suggestion_state := 'unsupported';
      else
        suggestion_state := 'suggested';
        value_ratio := v_ratio;
        suggested_price := kut._pack_round_up_25(greatest(
          v_pack.expected_discard_per_pack / 0.75,
          v_regular_price * v_ratio / 0.90
        ));
      end if;
    end if;
    return next;
  end loop;
end;
$$;

revoke all on function kut._pack_round_up_25(numeric) from public, anon, authenticated;
revoke all on function kut.pack_price_suggestions() from public, anon;
grant execute on function kut.pack_price_suggestions() to authenticated, service_role;

-- 4. Purchase -------------------------------------------------------------------
-- Source: 20260918000000_basic_pack_175.sql. Signature, locks (profile, pack
-- FOR SHARE, wallet), quote check, replays and response keys are unchanged.
-- New: one pool snapshot per opening, the conditional last card, an atomic
-- empty-guarantee failure, the receipt snapshot and FLUT in the server text.
create or replace function kut.open_pack(
  p_pack_slug text,
  p_expected_price bigint,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_user_id uuid := auth.uid();
  v_pack record;
  v_opening record;
  v_balance bigint;
  v_slot integer;
  v_card_id uuid;
  v_ledger_key text := 'pack:' || p_idempotency_key::text;
  v_editions uuid[];
  v_tiers text[];
  v_ranks integer[];
  v_ovrs integer[];
  v_weights integer[];
  v_floor integer;
  v_met boolean := false;
  v_restrict boolean;
  v_pick integer;
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_idempotency_key is null
     or p_expected_price is null
     or p_expected_price <= 0
     or p_pack_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then
    raise exception 'valid pack, price, and idempotency key are required' using errcode = '22023';
  end if;

  perform 1 from kut.profiles where id = v_user_id and not is_disabled for update;
  if not found then
    raise exception 'active profile not found' using errcode = '42501';
  end if;

  select opening.id, opening.price_paid
  into v_opening
  from kut.pack_openings opening
  where opening.user_id = v_user_id
    and opening.idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'opening_id', v_opening.id,
      'price_paid', v_opening.price_paid,
      'already_processed', true,
      'price_changed', false
    );
  end if;

  select id, slug, title, price, cards_per_pack, min_tier
  into v_pack
  from kut.pack_definitions
  where slug = p_pack_slug and is_active
  for share;
  if not found then
    raise exception 'active pack not found' using errcode = 'P0002';
  end if;

  if v_pack.price <> p_expected_price then
    return jsonb_build_object(
      'already_processed', false,
      'price_changed', true,
      'current_price', v_pack.price
    );
  end if;

  -- One pool for the whole opening, so a rating change cannot move a Player
  -- across the floor between draws.
  select array_agg(pool.edition_id order by pool.edition_id),
         array_agg(pool.tier order by pool.edition_id),
         array_agg(pool.tier_rank order by pool.edition_id),
         array_agg(pool.ovr order by pool.edition_id),
         array_agg(pool.weight order by pool.edition_id)
  into v_editions, v_tiers, v_ranks, v_ovrs, v_weights
  from kut.pack_draw_pool() pool
  where pool.weight > 0;
  if v_editions is null then
    raise exception 'no eligible Live editions are available' using errcode = 'P0002';
  end if;
  v_floor := kut.pack_tier_rank(v_pack.min_tier);
  if v_floor is not null and not (v_floor <= any(v_ranks)) then
    raise exception 'pack guarantee cannot be met' using errcode = 'P0002';
  end if;

  insert into kut.wallets (user_id, balance) values (v_user_id, 0)
  on conflict (user_id) do nothing;
  select balance into v_balance from kut.wallets where user_id = v_user_id for update;

  -- A same-key call may have waited for the wallet lock. Replay before debit.
  select opening.id, opening.price_paid
  into v_opening
  from kut.pack_openings opening
  where opening.user_id = v_user_id
    and opening.idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'opening_id', v_opening.id,
      'price_paid', v_opening.price_paid,
      'already_processed', true,
      'price_changed', false
    );
  end if;

  if v_balance < v_pack.price then
    raise exception 'insufficient FLUT Coins for this pack' using errcode = 'P0001';
  end if;

  insert into kut.pack_openings (user_id, pack_id, price_paid, idempotency_key, pack_slug, pack_title, min_tier)
  values (v_user_id, v_pack.id, v_pack.price, p_idempotency_key, v_pack.slug, v_pack.title, v_pack.min_tier)
  returning id, price_paid into v_opening;

  update kut.wallets set balance = balance - v_pack.price, updated_at = now()
  where user_id = v_user_id;
  insert into kut.wallet_ledger (user_id, amount, reason, reference_type, reference_id, idempotency_key)
  values (v_user_id, -v_pack.price, 'pack_purchase', 'pack_opening', v_opening.id, v_ledger_key);

  for v_slot in 1..v_pack.cards_per_pack loop
    -- Only the last card is restricted, and only if no earlier card met the floor.
    v_restrict := v_floor is not null and not v_met and v_slot = v_pack.cards_per_pack;
    select candidate.ord::integer into v_pick
    from unnest(v_weights, v_ranks) with ordinality as candidate(weight, tier_rank, ord)
    where not v_restrict or candidate.tier_rank >= v_floor
    order by -ln(greatest(random(), 0.0000001)) / candidate.weight
    limit 1;

    v_met := v_met or (v_floor is not null and v_ranks[v_pick] >= v_floor);
    insert into kut.user_cards (edition_id, owner_id, source)
    values (v_editions[v_pick], v_user_id, 'pack') returning id into v_card_id;
    insert into kut.pack_opening_cards (opening_id, slot, card_id, opened_tier, opened_ovr, floor_draw)
    values (v_opening.id, v_slot, v_card_id, v_tiers[v_pick], v_ovrs[v_pick], v_restrict);
    update kut.card_editions set minted_count = minted_count + 1 where id = v_editions[v_pick];
  end loop;

  return jsonb_build_object(
    'opening_id', v_opening.id,
    'price_paid', v_opening.price_paid,
    'already_processed', false,
    'price_changed', false
  );
end;
$$;

-- 5. Audited settings -----------------------------------------------------------
-- All three prices and both toggles in one call, against the revision the
-- admin loaded. Rows lock in slug order (open_pack's FOR SHARE waits, and two
-- admins serialize). A stale revision returns 'conflict' with the current
-- values and changes nothing; an identical submission returns 'unchanged'.
-- The bound is technical (whole coins, JS-safe), not an economic rule.
create function kut.admin_apply_pack_settings(
  p_expected_revision bigint,
  p_regular_price bigint,
  p_silver_price bigint,
  p_gold_price bigint,
  p_silver_active boolean,
  p_gold_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_user_id uuid := auth.uid();
  v_revision bigint;
  v_before jsonb;
  v_after jsonb;
  v_count integer;
begin
  if v_user_id is null or not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;
  if p_expected_revision is null or p_silver_active is null or p_gold_active is null
     or p_regular_price is null or p_silver_price is null or p_gold_price is null
     or least(p_regular_price, p_silver_price, p_gold_price) < 1
     or greatest(p_regular_price, p_silver_price, p_gold_price) > 1000000 then
    raise exception 'prices must be whole coins from 1 to 1000000' using errcode = '22023';
  end if;

  perform 1 from kut.pack_definitions
  where slug in ('tfh-gold-pack', 'tfh-pack', 'tfh-silver-pack')
  order by slug
  for update;
  get diagnostics v_count = row_count;
  if v_count <> 3 then
    raise exception 'expected the Regular, Silver and Gold pack definitions' using errcode = 'P0002';
  end if;

  select coalesce(max(revision), 0) into v_revision from kut.pack_settings_changes;
  select jsonb_object_agg(slug, jsonb_build_object('price', price, 'is_active', is_active))
  into v_before
  from kut.pack_definitions
  where slug in ('tfh-gold-pack', 'tfh-pack', 'tfh-silver-pack');

  if v_revision <> p_expected_revision then
    return jsonb_build_object('status', 'conflict', 'revision', v_revision, 'packs', v_before);
  end if;

  v_after := jsonb_build_object(
    'tfh-pack', jsonb_build_object('price', p_regular_price, 'is_active', true),
    'tfh-silver-pack', jsonb_build_object('price', p_silver_price, 'is_active', p_silver_active),
    'tfh-gold-pack', jsonb_build_object('price', p_gold_price, 'is_active', p_gold_active)
  );
  if v_after = v_before then
    return jsonb_build_object('status', 'unchanged', 'revision', v_revision, 'packs', v_before);
  end if;

  update kut.pack_definitions pack
  set price = (v_after -> pack.slug ->> 'price')::bigint,
      is_active = (v_after -> pack.slug ->> 'is_active')::boolean,
      updated_at = now()
  where pack.slug in ('tfh-gold-pack', 'tfh-pack', 'tfh-silver-pack')
    and (pack.price, pack.is_active) is distinct from
        ((v_after -> pack.slug ->> 'price')::bigint, (v_after -> pack.slug ->> 'is_active')::boolean);

  insert into kut.pack_settings_changes (revision, changed_by, before, after)
  values (v_revision + 1, v_user_id, v_before, v_after);

  return jsonb_build_object('status', 'applied', 'revision', v_revision + 1, 'packs', v_after);
end;
$$;

revoke all on function kut.admin_apply_pack_settings(bigint, bigint, bigint, bigint, boolean, boolean) from public, anon;
grant execute on function kut.admin_apply_pack_settings(bigint, bigint, bigint, bigint, boolean, boolean) to authenticated, service_role;

-- 6. Admin economy read -----------------------------------------------------------
-- One snapshot for /admin/economy: canonical metrics and suggestions for every
-- pack, the settings revision, openings by recorded pack and price paid, the
-- cohort's wallets (sorted, anonymous: the page counts who can afford a draft
-- price) and its 7/28-day coin flows. Period discards are not pack ROI.
create function kut.admin_pack_economy()
returns jsonb
language plpgsql
stable
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null or not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;

  with cohort as (
    select profile.id from kut.profiles profile
    where not profile.is_disabled and profile.role <> 'superadmin'
  ), balances as (
    select coalesce(wallet.balance, 0) as balance
    from cohort left join kut.wallets wallet on wallet.user_id = cohort.id
  ), pack_usage as (
    select coalesce(opening.pack_slug, pack.slug) as slug,
           coalesce(opening.pack_title, pack.title) as title,
           opening.price_paid,
           count(*) filter (where opening.opened_at > now() - interval '7 days') as openings_7d,
           coalesce(sum(opening.price_paid) filter (where opening.opened_at > now() - interval '7 days'), 0) as coins_7d,
           count(*) as openings_28d,
           sum(opening.price_paid) as coins_28d
    from kut.pack_openings opening
    join cohort on cohort.id = opening.user_id
    join kut.pack_definitions pack on pack.id = opening.pack_id
    where opening.opened_at > now() - interval '28 days'
    group by 1, 2, 3
  ), ledger as (
    select
      case
        when entry.reason in ('starter', 'attendance_reward', 'admin_grant', 'admin_self_grant', 'bibs_bonus',
          'session_report_reward', 'injury_stipend', 'midweek_win', 'midweek_prediction') then 'rewards_and_grants'
        when entry.reason = 'discard' then 'discards'
        when entry.reason = 'pack_purchase' then 'packs'
        when entry.reason = 'market_tax' then 'market_tax'
        when entry.reason in ('admin_correction', 'admin_reset') then 'admin_adjustments'
      end as flow,
      entry.amount,
      entry.created_at as at
    from kut.wallet_ledger entry
    join cohort on cohort.id = entry.user_id
    where entry.created_at > now() - interval '28 days'
    union all
    -- A trade's tax is burned from the proposer's escrow, with no ledger row.
    select 'market_tax', -offer.coins_burned, offer.resolved_at
    from kut.trade_offers offer
    join cohort on cohort.id = offer.proposer_id
    where offer.status = 'accepted' and offer.coins_burned > 0
      and offer.resolved_at > now() - interval '28 days'
  ), flows as (
    select groups.flow,
           coalesce(sum(ledger.amount) filter (where ledger.at > now() - interval '7 days'), 0) as net_7d,
           coalesce(sum(ledger.amount), 0) as net_28d
    from (values ('rewards_and_grants'), ('discards'), ('packs'), ('market_tax'), ('admin_adjustments')) groups(flow)
    left join ledger on ledger.flow = groups.flow
    group by groups.flow
  ), latest_revision as (
    select change.revision, change.changed_at, profile.display_name as changed_by_name
    from kut.pack_settings_changes change
    left join kut.profiles profile on profile.id = change.changed_by
    order by change.revision desc
    limit 1
  )
  select jsonb_build_object(
    'measured_at', now(),
    'revision', (select to_jsonb(latest_revision) from latest_revision),
    'packs', coalesce((
      select jsonb_agg(to_jsonb(metric) || jsonb_build_object(
        'suggested_price', suggestion.suggested_price,
        'suggestion_state', suggestion.suggestion_state,
        'value_ratio', suggestion.value_ratio
      ) order by metric.price, metric.slug)
      from kut.pack_metrics() metric
      left join kut.pack_price_suggestions() suggestion on suggestion.slug = metric.slug
    ), '[]'::jsonb),
    'usage', coalesce((select jsonb_agg(to_jsonb(pack_usage) order by pack_usage.slug, pack_usage.price_paid) from pack_usage), '[]'::jsonb),
    'cohort', jsonb_build_object(
      'definition', 'enabled non-superadmin profiles',
      'members', (select count(*) from balances),
      'median_balance', (select percentile_cont(0.5) within group (order by balance) from balances),
      'balances', coalesce((select jsonb_agg(balance order by balance) from balances), '[]'::jsonb)
    ),
    'flows', coalesce((select jsonb_object_agg(flows.flow, jsonb_build_object('net_7d', flows.net_7d, 'net_28d', flows.net_28d)) from flows), '{}'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

comment on function kut.admin_pack_economy() is
  'ADR-164. Admin-only snapshot for /admin/economy. Flows are signed ledger sums (sinks negative); transfers between members and trade escrow are excluded; the cohort is enabled non-superadmin profiles.';

revoke all on function kut.admin_pack_economy() from public, anon;
grant execute on function kut.admin_pack_economy() to authenticated, service_role;

-- 7. Views: appended columns only ---------------------------------------------

create or replace view kut.active_pack_offers
with (security_invoker = true, security_barrier = true)
as
select slug, title, price, cards_per_pack, min_tier
from kut.pack_definitions
where is_active;

-- Source: 20261018000000_special_snapshot_tiers.sql. Receipt identity comes
-- from the opening; the definition is a LEFT join (an inactive pack is hidden
-- from members by RLS); opening-time evidence is appended.
create or replace view kut.my_pack_opening_results
with (security_invoker = true, security_barrier = true)
as
select
  opening.id as opening_id,
  opening.opened_at,
  opening.price_paid,
  coalesce(opening.pack_slug, pack.slug) as pack_slug,
  coalesce(opening.pack_title, pack.title) as pack_title,
  result.slot,
  card.id as card_id,
  player.display_name,
  player.archetype,
  coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
  coalesce(edition.snapshot_pac, state.pac, 30) as pac,
  coalesce(edition.snapshot_sho, state.sho, 30) as sho,
  coalesce(edition.snapshot_pas, state.pas, 30) as pas,
  coalesce(edition.snapshot_dri, state.dri, 30) as dri,
  coalesce(edition.snapshot_def, state.def, 30) as def,
  coalesce(edition.snapshot_phy, state.phy, 30) as phy,
  case
    when edition.is_live then coalesce(state.rarity_tier, 'common')
    else edition.snapshot_rarity_tier
  end as rarity_tier,
  player.photo_path,
  edition.player_id,
  edition.is_live,
  opening.min_tier,
  result.opened_tier,
  result.opened_ovr,
  result.floor_draw
from kut.pack_openings opening
left join kut.pack_definitions pack on pack.id = opening.pack_id
join kut.pack_opening_cards result on result.opening_id = opening.id
join kut.user_cards card on card.id = result.card_id
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state
  on state.player_id = player.id
  and state.season_id = active_season.id
where opening.user_id = auth.uid();

-- Source: 20260816070500_pack_economy_health.sql. Now every definition
-- (inactive too) from kut.pack_metrics; per pack and return are guarantee-
-- aware; per slot stays the base draw. Unavailable packs read 0 in the old
-- columns, as before, and qualifying_count 0 says why.
create or replace view kut.pack_economy_health
with (security_invoker = true, security_barrier = true)
as
select
  metric.slug,
  metric.title,
  metric.price,
  metric.cards_per_pack,
  metric.eligible_count as eligible_live_count,
  round(coalesce(metric.expected_discard_per_slot, 0), 2) as expected_discard_per_slot,
  round(coalesce(metric.expected_discard_per_pack, 0), 2) as expected_discard_per_pack,
  round(coalesce(metric.expected_discard_per_pack, 0) / metric.price, 4) as expected_discard_return_ratio,
  (select coalesce(sum(balance), 0) from kut.wallets)::bigint as total_coin_supply,
  (select count(*) from kut.pack_openings)::bigint as total_pack_openings,
  (select count(*) from kut.user_cards)::bigint as total_card_copies,
  (select count(*) from kut.user_cards where burned_at is not null)::bigint as total_burned_cards,
  metric.is_active,
  metric.min_tier,
  metric.qualifying_count
from kut.pack_metrics() metric
where kut.is_admin();

-- Source: 20260928000000_active_member_projection_gate.sql (body verbatim;
-- pack_slug and pack_title appended to every arm, null outside packs).
create or replace view kut.activity_feed
with (security_invoker = false, security_barrier = true)
as
select * from (

select
  'sale'::text                    as kind,
  sale.sold_at                    as ts,
  seller.display_name             as actor_name,
  buyer.display_name              as counterparty_name,
  player.display_name             as card_name,
  sale.sale_price                 as amount,
  null::date                      as session_date,
  null::text                      as session_type,
  null::text[]                    as offered_card_names,
  null::text                      as pack_slug,
  null::text                      as pack_title
from kut.market_sales sale
join kut.profiles seller       on seller.id = sale.seller_id
join kut.profiles buyer        on buyer.id = sale.buyer_id
join kut.card_editions edition on edition.id = sale.edition_id
join kut.players player        on player.id = edition.player_id
where seller.role <> 'superadmin' and buyer.role <> 'superadmin'

union all

select
  'trade'::text,
  offer.resolved_at,
  seller.display_name,
  proposer.display_name,
  player.display_name,
  offer.offered_coins,
  null::date,
  null::text,
  offered.names,
  null::text,
  null::text
from kut.trade_offers offer
join kut.profiles seller       on seller.id = offer.seller_id
join kut.profiles proposer     on proposer.id = offer.proposer_id
join kut.user_cards card       on card.id = offer.settled_card_id
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player        on player.id = edition.player_id
left join lateral (
  select array_agg(offered_player.display_name order by offered_player.display_name) as names
  from kut.trade_offer_cards offer_card
  join kut.user_cards offered_card       on offered_card.id = offer_card.card_id
  join kut.card_editions offered_edition on offered_edition.id = offered_card.edition_id
  join kut.players offered_player        on offered_player.id = offered_edition.player_id
  where offer_card.offer_id = offer.id
) offered on true
where offer.status = 'accepted' and offer.resolved_at is not null
  and seller.role <> 'superadmin' and proposer.role <> 'superadmin'

union all

select
  'listing'::text,
  listing.listed_at,
  seller.display_name,
  null,
  player.display_name,
  listing.price,
  null::date,
  null::text,
  null::text[],
  null::text,
  null::text
from kut.market_listings listing
join kut.user_cards card       on card.id = listing.card_id
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player        on player.id = edition.player_id
join kut.profiles seller       on seller.id = listing.seller_id
where listing.status = 'active' and listing.expires_at > now()
  and seller.role <> 'superadmin'

union all

select
  'pack'::text,
  opening.opened_at,
  opener.display_name,
  null,
  null,
  opening.price_paid,
  null::date,
  null::text,
  null::text[],
  opening.pack_slug,
  opening.pack_title
from kut.pack_openings opening
join kut.profiles opener on opener.id = opening.user_id
where opener.role <> 'superadmin'

union all

select
  'session'::text,
  session.published_at,
  null,
  null,
  null,
  null::bigint,
  session.session_date,
  session.session_type,
  null::text[],
  null::text,
  null::text
from kut.match_sessions session
where session.status = 'published' and session.published_at is not null

) gated
where kut.is_active_member();

revoke all on kut.activity_feed from public, anon;
grant select on kut.activity_feed to authenticated, service_role;
