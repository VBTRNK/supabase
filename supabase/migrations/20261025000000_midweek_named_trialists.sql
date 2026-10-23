-- ADR-165 / #246 S5: Talents as named Midweek trialists.
--
-- Midweek's empty squad slots are filled by trialists. From go-live they carry
-- the names of visible Talents, so Talents get a weekly stage before
-- promotion. Names only: a trialist keeps its power (OVR 30, All-rounder, the
-- trialist factor), and members still can't own or pick a Talent.
--
--   1. kut.midweek_entry_cards.trialist_name: a frozen, nullable display name,
--      only on a trialist row.
--   2. kut._mm_trialist_names: one entrant's draw from the visible Talents,
--      with its own seed tag, without repeats within the squad (repeats
--      across squads are allowed).
--   3. kut._mm_lock_tournament: writes the names with the entry cards, after
--      the simulation. The engine never sees them: kut._mm_simulate, its
--      input, its fixtures and golden vectors are unchanged. A stored result
--      is written once (kut._mm_guard_result), so the names go in with the
--      insert and never change (Part L 25).
--   4. kut.midweek_entries_public appends trialist_name. Pages fall back to
--      "<manager>'s trialist" when it is null: before go-live, when a squad
--      has more trialist slots than there are visible Talents, and for every
--      week locked before this migration.
--
-- The pool is the Academy as the worker finds it at the lock: active Talents
-- whose stored lifecycle is visible (progress >= 2), only once the Academy is
-- live. Comebacks are Retired, not Talents, so they never lend a name.
--
-- Deploy ordering: none. Pages read the view with select("*") and treat a
-- missing column as null, so the app works on either side of this migration.
--
-- Rollback: re-create kut._mm_lock_tournament from
-- 20261016000000_midweek_balance.sql and kut.midweek_entries_public from
-- 20261020000000_midweek_club_names.sql (drop the view first: a view cannot
-- lose a column, then re-apply its grants), drop kut._mm_trialist_names, then
-- drop the trialist_name column. Stored names are lost; pages fall back.

-- 1. The column ---------------------------------------------------------------------

alter table kut.midweek_entry_cards
  add column trialist_name text,
  add constraint midweek_entry_cards_trialist_name_check check (trialist_name is null or trialist);

comment on column kut.midweek_entry_cards.trialist_name is
  'ADR-165: the visible Talent a trialist was named after at the lock, frozen; null for a card, an anonymous trialist and every week locked before the rule.';

-- 2. The draw -----------------------------------------------------------------------

-- One entrant's trialist names, in the order their trialist slots take them:
-- the visible Talents shuffled with the entrant's own tag. The k-th trialist
-- slot (by slot) takes element k; slots past the end stay anonymous.
create function kut._mm_trialist_names(p_seed bytea, p_user_id uuid, p_names text[])
returns text[] language sql immutable parallel safe set search_path = kut, pg_catalog as $$
  select coalesce(array_agg(p_names[position + 1] order by ord), '{}')
  from unnest(kut._mm_shuffle_order(p_seed, 'trialist-name:' || p_user_id, coalesce(cardinality(p_names), 0)))
    with ordinality as shuffled(position, ord)
$$;

-- 3. The lock step --------------------------------------------------------------------
-- As in 20261016000000_midweek_balance.sql section 7, with the visible Talents
-- read once and each trialist row's name written with the entry cards.

create or replace function kut._mm_lock_tournament(p_tournament_id uuid)
returns text language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_tournament kut.midweek_tournaments%rowtype;
  v_seed text; v_result jsonb; v_rounds integer; v_talents text[];
begin
  select * into v_tournament from kut.midweek_tournaments where id = p_tournament_id for update;
  if not found or v_tournament.status <> 'open' or v_tournament.lock_at > now() then return 'not_due'; end if;

  if not kut._mm_club_played(v_tournament.week_start) then
    update kut.midweek_tournaments set status = 'skipped', status_reason = 'club_break', updated_at = now()
    where id = p_tournament_id;
    return 'skipped';
  end if;

  select seed into v_seed from kut.midweek_tournament_secrets where tournament_id = p_tournament_id;
  if v_seed is null then raise exception 'Midweek tournament % has no seed', p_tournament_id; end if;
  -- Opt-outs count as of the lock (§44.2); everything else as the worker finds it.
  v_result := kut._mm_simulate(decode(v_seed, 'hex'),
    kut._mm_field(p_tournament_id, v_tournament.lock_at)->'entrants');

  if v_result->>'status' = 'skipped' then
    update kut.midweek_tournaments set status = 'skipped', status_reason = v_result->>'reason', updated_at = now()
    where id = p_tournament_id;
    return 'skipped';
  end if;

  v_rounds := (v_result->>'rounds')::int;

  -- The names trialists may carry (ADR-165): the Academy as members see it.
  select coalesce(array_agg(player.display_name order by player.id), '{}') into v_talents
  from kut.players player
  join kut.player_lifecycle lifecycle on lifecycle.player_id = player.id
  where kut.academy_is_live() and player.is_active and player.lifecycle_stage = 'talent'
    and lifecycle.academy_visible;

  insert into kut.midweek_entries (tournament_id, user_id, auto, keeper_slot, keeperless, balance_ppm)
  select p_tournament_id, (entry->>'userId')::uuid, (entry->>'auto')::boolean,
    (entry->>'keeperSlot')::smallint, (entry->>'keeperless')::boolean, (entry->>'balancePpm')::int
  from jsonb_array_elements(v_result->'entries') entry;

  insert into kut.midweek_entry_cards (tournament_id, user_id, slot, trialist, card_id, player_id, ovr, archetype,
    injured, ovr_factor_ppm, form_roll_ppm, pick_factor_ppm, fitness_ppm, handicap_ppm, power_ppm,
    att_ppm, mid_ppm, def_ppm, trialist_name)
  select p_tournament_id, (entry->>'userId')::uuid, (card->>'slot')::smallint, (card->>'trialist')::boolean,
    (card->>'cardId')::uuid, (card->>'playerId')::uuid, (card->>'ovr')::smallint, card->>'archetype',
    (card->>'injured')::boolean, (card->>'ovrFactorPpm')::int, (card->>'formRollPpm')::int,
    (card->>'pickFactorPpm')::int, (card->>'fitnessPpm')::int, (card->>'handicapPpm')::int,
    (card->>'powerPpm')::int, (card#>>'{lines,attPpm}')::int, (card#>>'{lines,midPpm}')::int,
    (card#>>'{lines,defPpm}')::int,
    case when (card->>'trialist')::boolean then drawn.names[(
      select count(*) from jsonb_array_elements(entry->'cards') earlier
      where (earlier->>'trialist')::boolean and (earlier->>'slot')::int <= (card->>'slot')::int)::int] end
  from jsonb_array_elements(v_result->'entries') entry
  cross join lateral (
    select kut._mm_trialist_names(decode(v_seed, 'hex'), (entry->>'userId')::uuid, v_talents) as names
  ) drawn
  cross join lateral jsonb_array_elements(entry->'cards') card;

  insert into kut.midweek_pick_shares (tournament_id, player_id, owners, picks, share_ppm, pick_factor_ppm)
  select p_tournament_id, (share->>'playerId')::uuid, (share->>'owners')::smallint, (share->>'picks')::smallint,
    (share->>'sharePpm')::int, (share->>'pickFactorPpm')::int
  from jsonb_array_elements(v_result->'pickShares') share;

  insert into kut.midweek_matches (tournament_id, round, pairing, bye, side_0_user_id, winner_side, winner_user_id,
    reveal_at, ends_at)
  select p_tournament_id, 1, (bye->>'pairing')::smallint, true, (bye->>'userId')::uuid, 0, (bye->>'userId')::uuid,
    clock.start_at, clock.start_at
  from jsonb_array_elements(v_result->'byes') bye
  cross join lateral (
    select kut._mm_round_start_at(v_tournament.lock_at, 1, v_tournament.schedule_version) as start_at
  ) clock;

  insert into kut.midweek_matches (tournament_id, round, pairing, bye, side_0_user_id, side_1_user_id,
    side_0_goals, side_1_goals, side_0_penalties, side_1_penalties, winner_side, winner_user_id,
    win_chance_ppm, side_0_day_rolls_ppm, side_1_day_rolls_ppm, reveal_at, ends_at)
  select p_tournament_id, (played->>'round')::smallint, (played->>'pairing')::smallint, false,
    (played#>>'{userIds,0}')::uuid, (played#>>'{userIds,1}')::uuid,
    (played#>>'{outcome,goals,0}')::smallint, (played#>>'{outcome,goals,1}')::smallint,
    (played#>>'{outcome,penalties,0}')::smallint, (played#>>'{outcome,penalties,1}')::smallint,
    (played#>>'{outcome,winnerSide}')::smallint,
    (played->'userIds'->>((played#>>'{outcome,winnerSide}')::int))::uuid,
    (played#>>'{outcome,winChancePpm}')::int,
    array(select jsonb_array_elements_text(played#>'{outcome,dayRollsPpm,0}')::int),
    array(select jsonb_array_elements_text(played#>'{outcome,dayRollsPpm,1}')::int),
    clock.start_at,
    clock.start_at + interval '1 millisecond' * (clock.timing->>'endOffsetMs')::bigint
  from jsonb_array_elements(v_result->'matches') played
  cross join lateral (
    select kut._mm_round_start_at(v_tournament.lock_at, (played->>'round')::int, v_tournament.schedule_version) as start_at,
      kut._mm_match_timing(played#>'{outcome,events}', v_tournament.schedule_version) as timing
  ) clock;

  insert into kut.midweek_match_events (match_id, seq, kind, side, minute, penalty_round, creator_slot, shooter_slot,
    defender_slot, kicker_slot, keeper_slot, chance_type, outcome, p_goal_ppm, reveal_at)
  select stored.id, (event.ord - 1)::smallint, event.value->>'kind', (event.value->>'side')::smallint,
    (event.value->>'minute')::smallint,
    case when event.value->>'kind' = 'penalty' then (event.value->>'round')::smallint end,
    (event.value->>'creator')::smallint, (event.value->>'shooter')::smallint,
    (event.value->>'defender')::smallint, (event.value->>'kicker')::smallint,
    case when event.value->>'kind' = 'penalty' then (event.value->>'keeper')::smallint end,
    event.value->>'chanceType', event.value->>'outcome', (event.value->>'pGoalPpm')::int,
    stored.reveal_at + interval '1 millisecond' * (clock.timing->'eventOffsetsMs'->>((event.ord - 1)::int))::bigint
  from jsonb_array_elements(v_result->'matches') played
  join kut.midweek_matches stored
    on stored.tournament_id = p_tournament_id
   and stored.round = (played->>'round')::int and stored.pairing = (played->>'pairing')::int
  cross join lateral (
    select kut._mm_match_timing(played#>'{outcome,events}', v_tournament.schedule_version) as timing
  ) clock
  cross join lateral jsonb_array_elements(played#>'{outcome,events}') with ordinality as event(value, ord);

  update kut.midweek_tournaments
  set status = 'simulated', rounds = v_rounds,
    final_reveal_at = (
      select max(final.ends_at) from kut.midweek_matches final
      where final.tournament_id = p_tournament_id and final.round = v_rounds),
    updated_at = now()
  where id = p_tournament_id;
  return 'simulated';
end $$;

revoke all on function kut._mm_trialist_names(bytea, uuid, text[]), kut._mm_lock_tournament(uuid)
  from public, anon, authenticated;

-- 4. The entries view: trialist_name appended -------------------------------------------
-- As in 20261020000000_midweek_club_names.sql section 3, with trialist_name
-- appended. It is stored at the lock, so it shows from the lock like the five.
create or replace view kut.midweek_entries_public
with (security_invoker = false, security_barrier = true)
as
select
  entry.tournament_id,
  tournament.week_start,
  entry.user_id,
  manager.display_name as manager_name,
  entry.auto,
  entry.keeper_slot,
  entry.keeperless,
  card.slot,
  card.trialist,
  card.player_id,
  player.display_name as player_name,
  player.photo_path,
  card.ovr,
  card.archetype,
  card.injured,
  card.ovr_factor_ppm,
  case when kickoff.started then card.form_roll_ppm end as form_roll_ppm,
  case when kickoff.started then card.pick_factor_ppm end as pick_factor_ppm,
  card.fitness_ppm,
  card.handicap_ppm,
  case when kickoff.started then card.power_ppm end as power_ppm,
  card.att_ppm,
  card.mid_ppm,
  card.def_ppm,
  case when tournament.status = 'complete' then share.picks end as picks,
  case when tournament.status = 'complete' and share.owners >= 3 then share.owners end as owners,
  entry.balance_ppm,
  coalesce(nullif(btrim(manager.club_name), ''), manager.display_name || '''s Club') as club_name,
  card.trialist_name
from kut.midweek_entries entry
join kut.midweek_tournaments tournament on tournament.id = entry.tournament_id
join kut.profiles manager on manager.id = entry.user_id
join kut.midweek_entry_cards card on card.tournament_id = entry.tournament_id and card.user_id = entry.user_id
left join kut.players player on player.id = card.player_id
left join kut.midweek_pick_shares share on share.tournament_id = card.tournament_id and share.player_id = card.player_id
cross join lateral (
  select exists (
    select 1 from kut.midweek_matches first_round
    where first_round.tournament_id = entry.tournament_id and first_round.round = 1
      and first_round.reveal_at <= now()) as started
) kickoff
where kut.is_active_member()
  and tournament.status in ('simulated', 'complete')
  and tournament.lock_at <= now();

comment on view kut.midweek_entries_public is
  'ADR-091, ADR-095, ADR-105, ADR-116, ADR-145, ADR-165: every entered Midweek Madness card (engine slots 0-4) with its lock-time OVR, archetype, injury flag and factors, from the lock; form roll, pick factor and power only from round 1''s kick-off. Picks and owner counts only once complete; owners null below three. balance_ppm is the squad''s weakest-line factor, null before ADR-116. club_name is the manager''s club, or "<name>''s Club" when none is set. trialist_name is the visible Talent a trialist was named after at the lock; null for a card, an anonymous trialist ("<name>''s trialist") and weeks before ADR-165. Gated on kut.is_active_member() (ADR-079).';
