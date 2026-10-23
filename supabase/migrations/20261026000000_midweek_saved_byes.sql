-- ADR-166 / #314: Midweek byes go to saved squads first.
--
-- A field that isn't a power of two gives some round-1 pairings a bye, which
-- pays like a win. The draw used to seat everyone in one shuffled order, so an
-- auto squad (no saved card survived the lock checks) could take a bye while a
-- member who saved a squad had to play. Now the byes go to saved squads first,
-- in seat order, and to auto squads only once every saved squad has one. A
-- squad with at least one surviving saved card counts as saved.
--
--   1. kut._mm_simulate -- as in 20261016000000_midweek_balance.sql section 5,
--      except the draw block (bracket.ts `drawBracket`):
--        - the `bracket:bye` shuffle still picks the bye pairings and the
--          `bracket:seat` shuffle still sets the seat order; no new draws;
--        - the bye queue is the first B of [saved in seat order, then auto
--          in seat order], the match queue the seat order without them;
--        - visiting pairings 0..P-1, a bye pairing takes the next bye holder,
--          a match pairing the next two of the match queue, left then right.
--
-- The engine is a pure function of the locked squads and the seed (Part L
-- #25): a week already simulated keeps its stored bracket and payouts, and
-- completion pays the stored rows without re-running it. A week first
-- simulated after this push uses the new rule, including an open week whose
-- lock is overdue. Golden vectors and the parity test are regenerated
-- (ADR-090); no invariant changes.
--
-- Deploy ordering: none. The app never runs the draw; the TypeScript twin is
-- for tests and simulation only.
--
-- Tier: data-changing (docs/OPERATIONS.md): it changes who gets a bye at the
-- lock and so who is paid. Fresh cold-verified backup first; never push it
-- during a Wednesday evening.
--
-- Rollback (stored weeks stay as they are; only the next lock changes):
--   re-create kut._mm_simulate from 20261016000000_midweek_balance.sql.

create or replace function kut._mm_simulate(p_seed bytea, p_entrants jsonb)
returns jsonb language plpgsql immutable parallel safe set search_path = kut, pg_catalog as $$
declare
  c jsonb := kut._mm_config();
  v_size_cap integer := (c->>'squadSize')::int;
  v_ppm constant bigint := 1000000;
  v_count integer := coalesce(jsonb_array_length(p_entrants), 0);
  v_entrants jsonb; v_entrant jsonb; v_user text; v_auto boolean; v_cards jsonb; v_card jsonb;
  v_squads jsonb := '[]'::jsonb; v_squad jsonb;
  v_pick_shares jsonb; v_share_factor jsonb;
  v_entries jsonb := '[]'::jsonb; v_entry_cards jsonb; v_sides jsonb := '{}'::jsonb;
  v_slot integer; v_handicap bigint; v_ovr_factor bigint; v_form bigint; v_pick bigint; v_fitness bigint;
  v_power bigint; v_lines record; v_archetype text;
  v_keeper integer; v_keeper_score bigint; v_keeperless boolean; v_score bigint; v_balance bigint;
  v_users text[]; v_size integer := 1; v_rounds integer := 0; v_pairing_count integer; v_bye_count integer;
  v_bye_pairings integer[]; v_seat_order integer[]; v_seated text[];
  v_autos boolean[]; v_bye_holders text[]; v_playing text[]; v_next_bye integer;
  v_first text[] := '{}'; v_second text[] := '{}'; v_next integer; v_pairing integer;
  v_pays integer[]; v_round integer; v_winners text[];
  v_byes jsonb := '[]'::jsonb; v_matches jsonb := '[]'::jsonb; v_payouts jsonb := '[]'::jsonb;
  v_outcome jsonb; v_winner text;
begin
  if v_count < (c->>'minEntrants')::int then
    return jsonb_build_object('status', 'skipped', 'reason', 'too_few_entrants');
  end if;

  -- tournament.ts `validate`: the caller has applied the lock-time checks.
  if (select count(distinct e->>'userId') from jsonb_array_elements(p_entrants) e) <> v_count then
    raise exception 'Duplicate Midweek entrant' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_entrants) e
    where coalesce(jsonb_array_length(e->'owned'), 0) = 0
      or coalesce(jsonb_array_length(e->'saved'), 0) > v_size_cap
      or exists (
        select 1 from jsonb_array_elements(e->'saved') saved
        where not exists (
          select 1 from jsonb_array_elements(e->'owned') owned where owned->>'cardId' = saved->>'cardId'))
      or (select count(distinct saved->>'playerId') from jsonb_array_elements(e->'saved') saved)
        <> coalesce(jsonb_array_length(e->'saved'), 0)
  ) then
    raise exception 'Invalid Midweek field: an entrant owns no card, or a saved squad is invalid' using errcode = '22023';
  end if;

  select jsonb_agg(e order by e->>'userId' collate "C") into v_entrants from jsonb_array_elements(p_entrants) e;

  for v_entrant in select value from jsonb_array_elements(v_entrants) loop
    v_auto := jsonb_array_length(v_entrant->'saved') = 0;
    v_squads := v_squads || jsonb_build_array(jsonb_build_object(
      'userId', v_entrant->>'userId', 'auto', v_auto,
      'cards', case when v_auto then kut._mm_auto_squad(p_seed, v_entrant) else v_entrant->'saved' end));
  end loop;

  -- Pick shares: owners count every entrant owning the Player, picks only
  -- non-auto squads.
  with owners as (
    select owned->>'playerId' as player_id, count(distinct e->>'userId')::int as owners
    from jsonb_array_elements(v_entrants) e, jsonb_array_elements(e->'owned') owned
    group by 1
  ),
  picks as (
    select card->>'playerId' as player_id, count(*)::int as picks
    from jsonb_array_elements(v_squads) squad, jsonb_array_elements(squad->'cards') card
    where not (squad->>'auto')::boolean
    group by 1
  ),
  shares as (
    select owners.player_id, owners.owners, coalesce(picks.picks, 0) as picks,
      kut._mm_pick_share(coalesce(picks.picks, 0), owners.owners) as share_ppm
    from owners left join picks using (player_id)
  )
  select
    coalesce(jsonb_agg(jsonb_build_object('playerId', player_id, 'owners', owners, 'picks', picks,
      'sharePpm', share_ppm, 'pickFactorPpm', kut._mm_pick_factor(share_ppm)) order by player_id collate "C"), '[]'::jsonb),
    coalesce(jsonb_object_agg(player_id, kut._mm_pick_factor(share_ppm)), '{}'::jsonb)
  into v_pick_shares, v_share_factor
  from shares;

  -- Every card's week-long factors, trialists in the empty slots, and the keeper.
  for v_squad in select value from jsonb_array_elements(v_squads) loop
    v_user := v_squad->>'userId';
    v_auto := (v_squad->>'auto')::boolean;
    v_handicap := case when v_auto then (c->>'autoFactorPpm')::bigint else v_ppm end;
    v_entry_cards := '[]'::jsonb;
    for v_slot in 0 .. v_size_cap - 1 loop
      v_card := v_squad->'cards'->v_slot;
      if v_card is not null then
        v_archetype := v_card->>'archetype';
        v_ovr_factor := kut._mm_ovr_factor((v_card->>'ovr')::int);
        v_form := kut._mm_form_roll(p_seed, 'form:p:' || (v_card->>'playerId'));
        v_pick := case when v_auto then (c#>>'{pick,neutralPpm}')::bigint
          else (v_share_factor->>(v_card->>'playerId'))::bigint end;
        v_fitness := case when (v_card->>'injured')::boolean then (c->>'injuredFitnessPpm')::bigint else v_ppm end;
        v_power := kut._mm_card_power(v_ovr_factor, v_form, v_pick, v_fitness, v_handicap);
        select * into v_lines from kut._mm_lines(v_archetype);
        v_entry_cards := v_entry_cards || jsonb_build_array(jsonb_build_object(
          'slot', v_slot, 'cardId', v_card->'cardId', 'playerId', v_card->'playerId', 'trialist', false,
          'ovr', v_card->'ovr', 'archetype', v_archetype, 'injured', v_card->'injured',
          'ovrFactorPpm', v_ovr_factor, 'formRollPpm', v_form, 'pickFactorPpm', v_pick,
          'fitnessPpm', v_fitness, 'handicapPpm', v_handicap, 'powerPpm', v_power,
          'lines', jsonb_build_object('attPpm', v_lines.att_ppm, 'midPpm', v_lines.mid_ppm, 'defPpm', v_lines.def_ppm)));
      else
        v_ovr_factor := kut._mm_ovr_factor((c#>>'{trialist,ovr}')::int);
        v_form := kut._mm_form_roll(p_seed, 'form:t:' || v_user || ':' || v_slot);
        v_power := kut._mm_card_power(v_ovr_factor, v_form, (c#>>'{pick,neutralPpm}')::bigint, v_ppm,
          kut._mm_mul(v_handicap, (c#>>'{trialist,factorPpm}')::bigint));
        select * into v_lines from kut._mm_lines('all_rounder');
        v_entry_cards := v_entry_cards || jsonb_build_array(jsonb_build_object(
          'slot', v_slot, 'cardId', null, 'playerId', null, 'trialist', true,
          'ovr', (c#>>'{trialist,ovr}')::int, 'archetype', 'all_rounder', 'injured', false,
          'ovrFactorPpm', v_ovr_factor, 'formRollPpm', v_form, 'pickFactorPpm', (c#>>'{pick,neutralPpm}')::bigint,
          'fitnessPpm', v_ppm, 'handicapPpm', kut._mm_mul(v_handicap, (c#>>'{trialist,factorPpm}')::bigint),
          'powerPpm', v_power,
          'lines', jsonb_build_object('attPpm', v_lines.att_ppm, 'midPpm', v_lines.mid_ppm, 'defPpm', v_lines.def_ppm)));
      end if;
    end loop;

    -- shape.ts `chooseKeeper`: the strongest Goalkeeper, else the outfielder
    -- with the highest defence contribution; ties to the lower slot.
    v_keeper := -1; v_keeper_score := -1; v_keeperless := false;
    for v_slot in 0 .. v_size_cap - 1 loop
      v_card := v_entry_cards->v_slot;
      if v_card->>'archetype' = 'goalkeeper' and (v_card->>'powerPpm')::bigint > v_keeper_score then
        v_keeper := v_slot; v_keeper_score := (v_card->>'powerPpm')::bigint;
      end if;
    end loop;
    if v_keeper < 0 then
      v_keeperless := true;
      for v_slot in 0 .. v_size_cap - 1 loop
        v_card := v_entry_cards->v_slot;
        v_score := kut._mm_mul((v_card->>'powerPpm')::bigint, (v_card#>>'{lines,defPpm}')::bigint);
        if v_score > v_keeper_score then v_keeper := v_slot; v_keeper_score := v_score; end if;
      end loop;
    end if;

    -- shape.ts `squadBalance`: the weakest-line rule over the outfielders.
    v_balance := (kut._mm_balance(array(
      select card->>'archetype' from jsonb_array_elements(v_entry_cards) with ordinality as x(card, ord) order by ord),
      v_keeper)->>'balancePpm')::bigint;

    v_entries := v_entries || jsonb_build_array(jsonb_build_object(
      'userId', v_user, 'auto', v_auto, 'cards', v_entry_cards, 'keeperSlot', v_keeper, 'keeperless', v_keeperless,
      'balancePpm', v_balance));
    v_sides := v_sides || jsonb_build_object(v_user, jsonb_build_object(
      'cards', (select jsonb_agg(jsonb_build_object('archetype', card->'archetype', 'weekPowerPpm', card->'powerPpm',
        'lines', card->'lines') order by ord) from jsonb_array_elements(v_entry_cards) with ordinality as x(card, ord)),
      'keeperSlot', v_keeper, 'keeperless', v_keeperless, 'balancePpm', v_balance));
  end loop;

  -- bracket.ts `drawBracket`: saved squads take the byes first (ADR-166).
  select array_agg(e->>'userId' order by ord), array_agg((e->>'auto')::boolean order by ord)
  into v_users, v_autos
  from jsonb_array_elements(v_entries) with ordinality as x(e, ord);
  while v_size < v_count loop v_size := v_size * 2; v_rounds := v_rounds + 1; end loop;
  v_pairing_count := v_size / 2;
  v_bye_count := v_size - v_count;
  v_bye_pairings := (kut._mm_shuffle_order(p_seed, 'bracket:bye', v_pairing_count))[1 : v_bye_count];
  v_seat_order := kut._mm_shuffle_order(p_seed, 'bracket:seat', v_count);
  select array_agg(v_users[i + 1] order by ord) into v_seated from unnest(v_seat_order) with ordinality as x(i, ord);
  -- The bye holders: saved before auto (false sorts first), each in seat order.
  select coalesce(array_agg(user_id order by auto, ord), '{}') into v_bye_holders
  from (
    select v_users[i + 1] as user_id, v_autos[i + 1] as auto, ord
    from unnest(v_seat_order) with ordinality as x(i, ord)
    order by auto, ord
    limit v_bye_count
  ) holders;
  -- Everyone else plays, in seat order.
  select coalesce(array_agg(user_id order by ord), '{}') into v_playing
  from unnest(v_seated) with ordinality as x(user_id, ord)
  where user_id <> all(v_bye_holders);
  v_next_bye := 1; v_next := 1;
  for v_pairing in 0 .. v_pairing_count - 1 loop
    if v_pairing = any(coalesce(v_bye_pairings, '{}')) then
      v_first := v_first || v_bye_holders[v_next_bye]; v_second := v_second || null::text;
      v_next_bye := v_next_bye + 1;
    else
      v_first := v_first || v_playing[v_next]; v_second := v_second || v_playing[v_next + 1]; v_next := v_next + 2;
    end if;
  end loop;

  v_pays := kut._mm_round_payouts(v_rounds);
  for v_round in 1 .. v_rounds loop
    v_winners := '{}';
    for v_pairing in 0 .. cardinality(v_first) - 1 loop
      if v_second[v_pairing + 1] is null then
        v_byes := v_byes || jsonb_build_array(jsonb_build_object('pairing', v_pairing, 'userId', v_first[v_pairing + 1]));
        v_payouts := v_payouts || jsonb_build_array(jsonb_build_object(
          'userId', v_first[v_pairing + 1], 'round', v_round, 'amount', v_pays[v_round], 'bye', true));
        v_winners := v_winners || v_first[v_pairing + 1];
      else
        v_outcome := kut._mm_play_match(p_seed, 'm:' || v_round || ':' || v_pairing,
          v_sides->v_first[v_pairing + 1], v_sides->v_second[v_pairing + 1]);
        v_winner := case when (v_outcome->>'winnerSide')::int = 0 then v_first[v_pairing + 1] else v_second[v_pairing + 1] end;
        v_matches := v_matches || jsonb_build_array(jsonb_build_object(
          'round', v_round, 'pairing', v_pairing,
          'userIds', jsonb_build_array(v_first[v_pairing + 1], v_second[v_pairing + 1]), 'outcome', v_outcome));
        v_payouts := v_payouts || jsonb_build_array(jsonb_build_object(
          'userId', v_winner, 'round', v_round, 'amount', v_pays[v_round], 'bye', false));
        v_winners := v_winners || v_winner;
      end if;
    end loop;
    v_first := '{}'; v_second := '{}';
    for v_pairing in 0 .. cardinality(v_winners) / 2 - 1 loop
      v_first := v_first || v_winners[2 * v_pairing + 1];
      v_second := v_second || v_winners[2 * v_pairing + 2];
    end loop;
  end loop;

  return jsonb_build_object(
    'status', 'simulated', 'size', v_size, 'rounds', v_rounds, 'entries', v_entries,
    'pickShares', v_pick_shares, 'byes', v_byes, 'matches', v_matches, 'payouts', v_payouts,
    'championUserId', v_winners[1]);
end $$;
