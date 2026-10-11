-- Midweek Madness 3.0, S2: club names in the Midweek views (VibeTrunk/kut#262;
-- ADR-145; design/mm3/HANDOFF.md "Club or account name").
--
-- Midweek names a member's team by their account name. Where the team plays,
-- wins or goes through, pages are to show the club name a member sets in
-- Settings (kut.set_own_club_name), defaulting to "<display name>'s Club" as
-- kut.club_value_leaderboard already does. The four views that name a member
-- gain a club column, appended at the end:
--
--   1. kut.midweek_matches_public    -- side_0_club, side_1_club (null on a bye)
--   2. kut.midweek_draw_public       -- side_0_club, side_1_club (null on a bye)
--   3. kut.midweek_entries_public    -- club_name
--   4. kut.midweek_tournaments_public
--                                    -- champion_club, with the champion
--
-- Each view is otherwise its latest definition, word for word: same gates,
-- definer, security barrier and kut.is_active_member(). The name columns stay
-- (the account name is still shown where the member acts: calls, the picker,
-- "Your night"). kut.midweek_current names no member; kut.my_midweek_predictions
-- names the called member, which stays the account name (calls, Q7). The result
-- message written in SQL is unchanged.
--
-- Deploy ordering: none. No page reads the new columns yet (S7 does, with a
-- fallback to the account name), and every existing column is unchanged.
--
-- Tier: additive (docs/OPERATIONS.md): views only; columns are appended, no
-- table, function or row changes.
--
-- Rollback: re-create kut.midweek_matches_public and
-- kut.midweek_tournaments_public from 20261014000000_midweek_live_reveal.sql
-- sections 1 and 3, kut.midweek_draw_public from
-- 20261012000000_midweek_draw_from_lock.sql section 1, and
-- kut.midweek_entries_public from 20261016000000_midweek_balance.sql section 8
-- (drop each first: a view cannot lose a column), then re-apply their grants
-- and comments.

-- 1. Matches -------------------------------------------------------------------------
-- As in 20261014000000_midweek_live_reveal.sql section 1, with each side's club
-- appended.
create or replace view kut.midweek_matches_public
with (security_invoker = false, security_barrier = true)
as
select
  played.id as match_id,
  played.tournament_id,
  tournament.week_start,
  played.round,
  played.pairing,
  played.bye,
  played.side_0_user_id,
  side_0.display_name as side_0_name,
  played.side_1_user_id,
  side_1.display_name as side_1_name,
  case when ended.ended then played.side_0_goals end as side_0_goals,
  case when ended.ended then played.side_1_goals end as side_1_goals,
  case when ended.ended then played.side_0_penalties end as side_0_penalties,
  case when ended.ended then played.side_1_penalties end as side_1_penalties,
  case when ended.ended then played.winner_side end as winner_side,
  case when ended.ended then played.winner_user_id end as winner_user_id,
  played.win_chance_ppm,
  played.side_0_day_rolls_ppm,
  played.side_1_day_rolls_ppm,
  played.reveal_at,
  case when ended.ended then played.ends_at end as ends_at,
  not ended.ended as in_play,
  coalesce(nullif(btrim(side_0.club_name), ''), side_0.display_name || '''s Club') as side_0_club,
  coalesce(nullif(btrim(side_1.club_name), ''), side_1.display_name || '''s Club') as side_1_club
from kut.midweek_matches played
join kut.midweek_tournaments tournament on tournament.id = played.tournament_id
join kut.profiles side_0 on side_0.id = played.side_0_user_id
left join kut.profiles side_1 on side_1.id = played.side_1_user_id
cross join lateral (
  -- Before ADR-104 a match has no end and shows whole from its kick-off.
  select played.ends_at is null or played.ends_at <= now() as ended
) ended
where kut.is_active_member()
  and tournament.status in ('simulated', 'complete')
  and played.reveal_at <= now();

comment on view kut.midweek_matches_public is
  'ADR-095, ADR-106, ADR-145: Midweek Madness pairings from their kick-off, byes included, with the pre-match win chance and each card''s day roll; goals, penalties, the winner and ends_at only once the match has ended, and in_play until then. side_*_club is each side''s club name, or "<name>''s Club" when none is set (null on a bye). Gated on kut.is_active_member() (ADR-079).';

-- 2. The draw ------------------------------------------------------------------------
-- As in 20261012000000_midweek_draw_from_lock.sql section 1, with each side's
-- club appended.
create or replace view kut.midweek_draw_public
with (security_invoker = false, security_barrier = true)
as
select
  played.id as match_id,
  played.tournament_id,
  tournament.week_start,
  played.pairing,
  played.bye,
  played.side_0_user_id,
  side_0.display_name as side_0_name,
  played.side_1_user_id,
  side_1.display_name as side_1_name,
  played.reveal_at as kickoff_at,
  coalesce(nullif(btrim(side_0.club_name), ''), side_0.display_name || '''s Club') as side_0_club,
  coalesce(nullif(btrim(side_1.club_name), ''), side_1.display_name || '''s Club') as side_1_club
from kut.midweek_matches played
join kut.midweek_tournaments tournament on tournament.id = played.tournament_id
join kut.profiles side_0 on side_0.id = played.side_0_user_id
left join kut.profiles side_1 on side_1.id = played.side_1_user_id
where kut.is_active_member()
  and tournament.status in ('simulated', 'complete')
  and tournament.lock_at <= now()
  and played.round = 1;

comment on view kut.midweek_draw_public is
  'ADR-105, ADR-145: round 1 of a drawn Midweek Madness week from the lock: pairings, byes, both managers, their clubs (side_*_club, "<name>''s Club" when none is set, null on a bye) and the kick-off, with no result. Gated on kut.is_active_member() (ADR-079).';

-- 3. Entries -------------------------------------------------------------------------
-- As in 20261016000000_midweek_balance.sql section 8, with the manager's club
-- appended.
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
  coalesce(nullif(btrim(manager.club_name), ''), manager.display_name || '''s Club') as club_name
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
  'ADR-091, ADR-095, ADR-105, ADR-116, ADR-145: every entered Midweek Madness card (engine slots 0-4) with its lock-time OVR, archetype, injury flag and factors, from the lock; form roll, pick factor and power only from round 1''s kick-off. Picks and owner counts only once complete; owners null below three. balance_ppm is the squad''s weakest-line factor, null before ADR-116. club_name is the manager''s club, or "<name>''s Club" when none is set. Gated on kut.is_active_member() (ADR-079).';

-- 4. The champion's club -------------------------------------------------------------
-- As in 20261014000000_midweek_live_reveal.sql section 3, with the champion's
-- club appended; it shows exactly when the champion does.
create or replace view kut.midweek_tournaments_public
with (security_invoker = false, security_barrier = true)
as
select
  tournament.id as tournament_id,
  tournament.week_start,
  tournament.lock_at,
  tournament.seed_hash,
  tournament.status,
  tournament.status_reason,
  tournament.void_note,
  tournament.rounds,
  case when tournament.final_reveal_at <= now() then tournament.final_reveal_at end as final_reveal_at,
  tournament.seed,
  champion.user_id as champion_user_id,
  champion.display_name as champion_name,
  tournament.schedule_version,
  champion.club_name as champion_club
from kut.midweek_tournaments tournament
left join lateral (
  select final.winner_user_id as user_id, profile.display_name,
    coalesce(nullif(btrim(profile.club_name), ''), profile.display_name || '''s Club') as club_name
  from kut.midweek_matches final
  join kut.profiles profile on profile.id = final.winner_user_id
  where final.tournament_id = tournament.id
    and final.round = tournament.rounds
    and tournament.status in ('simulated', 'complete')
    and coalesce(final.ends_at, final.reveal_at) <= now()
) champion on true
where kut.is_active_member()
order by tournament.week_start desc;

comment on view kut.midweek_tournaments_public is
  'ADR-089, ADR-095, ADR-104, ADR-105, ADR-106, ADR-145: every Midweek Madness tournament (status, skip or void reason, lock, final_reveal_at once passed, the seed only once complete, the version of its clock) and its champion and champion_club (the club name, or "<name>''s Club" when none is set) once the final has ended. Gated on kut.is_active_member() (ADR-079).';
