-- ADR-165 / #246 S2: the Academy lifecycle (Talent, First Team, Retired).
--
-- * kut.players.lifecycle_stage stores the stage. Every existing Player
--   becomes founding First Team (a stored stage, not a promotion event), so
--   packs, starters, resets, rotation and the album are unchanged until
--   go-live. Only definer functions may change a stage (guard trigger).
-- * kut.player_lifecycle_events holds promotions (permanent, immutable
--   effective week, reason 'progress' or 'admin'), retirements (recomputed:
--   undone when a correction removes the cause, revived without a second
--   message) and At risk warnings (one message key per episode).
-- * kut.academy_credits: audited bonus points for a Talent or a Retired
--   Player, at most 2 active, each expiring after 8 subsequent counted weeks.
--   They never create attendance, rating input, coins or Chronicle entries.
-- * kut.academy_go_live is the activation (the current football week, set
--   once). Without it nothing changes for members: no promotion, retirement,
--   warning or lifecycle message, and the member projections return no rows.
-- * kut._evaluate_lifecycle re-derives every stage from published attendance
--   in every season, injury periods (unlinked Players too), credits and the
--   stored promotions. It runs after the final state of publish, correct,
--   cancel and reactivate (through kut.rebuild_season), injury start and end,
--   credits, registration, admin promotion and go-live. It is idempotent.
--   A counted week counts as absent from its first published session.
-- * One supply predicate, kut.can_mint_copies (active, collectible First
--   Team), in packs, starter grants, account resets and archetype rotation.
--   One Midweek condition, kut.is_midweek_playable (not Retired), at the lock
--   and in save_midweek_squad. Retirement never touches a copy, a listing,
--   escrow or a stored Midweek field.
-- * Registration (roster and attendance) creates a Talent with no Live
--   edition (not collectible) and 0-2 credits, after a similar-name check.
--   admin_add_player keeps its signature as the direct First Team route.
--   Promotion creates the Live edition if missing, never a copy.
-- * Views only gain columns, at the end. Retired Players leave the rating
--   lists (public_live_ratings, top_risers); the album and profile reads get
--   the stage, and two new member projections serve the Academy and the
--   Chronicle's roster block.
--
-- Rollback (before go-live is recorded): re-emit rebuild_season (20260920010000),
-- admin_add_player (20260906000000), admin_start_injury and admin_end_injury
-- (20260930000000), pack_draw_pool (20261023000000), grant_starter_pack
-- (20260903000000), admin_reset_account (20260911000000), _mm_rotate_archetypes
-- (20261015000000), _mm_field (20261008000000), save_midweek_squad
-- (20261003000000) and the six views from their sources (see section 12);
-- restore the notification event_type constraint from 20261006000000; drop the
-- new views, functions, triggers and tables, then the lifecycle_stage column.
-- Talents registered meanwhile stay as non-collectible Players.

-- 1. The stage ------------------------------------------------------------------

alter table kut.players
  add column lifecycle_stage text not null default 'first_team'
    check (lifecycle_stage in ('talent', 'first_team', 'retired'));

-- A stage changes only through the definer functions below (they run as the
-- table owner). Direct client writes keep today's default: First Team.
create function kut.protect_player_lifecycle_stage()
returns trigger language plpgsql set search_path = kut, pg_catalog as $$
begin
  if current_user in ('authenticated', 'anon') and (
    (tg_op = 'INSERT' and new.lifecycle_stage <> 'first_team')
    or (tg_op = 'UPDATE' and new.lifecycle_stage is distinct from old.lifecycle_stage)
  ) then
    raise exception 'a Player''s stage changes only through the Academy rules' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger players_protect_lifecycle_stage
  before insert or update of lifecycle_stage on kut.players
  for each row execute function kut.protect_player_lifecycle_stage();

-- 2. Tables -----------------------------------------------------------------------

-- The activation: a single row, the football week it was recorded in.
create table kut.academy_go_live (
  id boolean primary key default true check (id),
  week_start date not null check (extract(isodow from week_start) = 1),
  recorded_at timestamptz not null default now(),
  recorded_by uuid references kut.profiles(id) on delete set null
);

create table kut.academy_credits (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references kut.players(id) on delete cascade,
  granted_at timestamptz not null default now(),
  -- ISO Monday of the grant's football week (club time); expiry counts the
  -- counted weeks after it.
  granted_week date not null check (extract(isodow from granted_week) = 1),
  reason text not null check (char_length(reason) between 3 and 200),
  granted_by uuid references kut.profiles(id) on delete set null
);
create index academy_credits_player_idx on kut.academy_credits (player_id, granted_week);

create table kut.player_lifecycle_events (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references kut.players(id) on delete cascade,
  kind text not null check (kind in ('promotion', 'at_risk', 'retirement')),
  effective_week date not null check (extract(isodow from effective_week) = 1),
  reason text check ((kind = 'promotion') = (reason is not null) and (reason is null or reason in ('progress', 'admin'))),
  -- The card at the event, for the message and the Chronicle (a dated fact).
  live_ovr integer not null check (live_ovr between 0 and 99),
  rarity_tier text not null,
  undone_at timestamptz check (undone_at is null or kind = 'retirement'),
  created_at timestamptz not null default now(),
  created_by uuid references kut.profiles(id) on delete set null,
  unique (player_id, kind, effective_week)
);

-- Promotions and At risk warnings never change (Part L 29). A retirement may
-- only move its week or be undone and revived by the evaluator. Deletes are
-- the player's own cascade (admin_delete_player of an unused Player).
create function kut.protect_player_lifecycle_events()
returns trigger language plpgsql set search_path = kut, pg_catalog as $$
begin
  if tg_op = 'DELETE' then
    if exists (select 1 from kut.players where id = old.player_id) then
      raise exception 'lifecycle events are never deleted' using errcode = '42501';
    end if;
    return old;
  end if;
  if old.kind <> 'retirement' or new.kind <> old.kind or new.player_id <> old.player_id
    or new.reason is distinct from old.reason or new.created_at <> old.created_at then
    raise exception 'promotion and At risk events never change' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger player_lifecycle_events_protect
  before update or delete on kut.player_lifecycle_events
  for each row execute function kut.protect_player_lifecycle_events();

-- The evaluator's derived state, one row per Player, rewritten on every run.
create table kut.player_lifecycle (
  player_id uuid primary key references kut.players(id) on delete cascade,
  -- The last 8 counted weeks (ISO Mondays) at the evaluation.
  window_weeks date[] not null default '{}',
  -- Progress parts: real counted weeks in the window (after the retirement,
  -- for a comeback) and the grant weeks of the active credits counted.
  played_weeks date[] not null default '{}',
  credit_weeks date[] not null default '{}',
  progress integer not null default 0 check (progress >= 0),
  academy_visible boolean not null default false,
  fading boolean not null default false,
  -- The First Team clock; null for a Talent and before go-live.
  absent_weeks integer check (absent_weeks >= 0),
  at_risk boolean not null default false,
  clock_start date,
  retired_week date,
  promoted_week date,
  evaluated_at timestamptz not null default now()
);

-- 3. Predicates ----------------------------------------------------------------------

create function kut._football_week(p_day date default null)
returns date language sql stable set search_path = kut, pg_catalog as $$
  select date_trunc('week', coalesce(p_day, (now() at time zone 'Europe/Amsterdam')::date))::date
$$;

alter table kut.academy_credits alter column granted_week set default kut._football_week();

create function kut.academy_is_live()
returns boolean language sql stable security definer set search_path = kut, pg_catalog as $$
  select exists (select 1 from kut.academy_go_live)
$$;

-- "Can new copies be made" (ADR-165): packs, starter grants, account resets
-- and archetype rotation. is_active stays the admin's manual override.
create function kut.can_mint_copies(p_player kut.players)
returns boolean language sql immutable set search_path = kut, pg_catalog as $$
  select p_player.is_active and p_player.is_collectible and p_player.lifecycle_stage = 'first_team'
$$;

-- "Playable in Midweek": not Retired. Not the supply predicate.
create function kut.is_midweek_playable(p_player kut.players)
returns boolean language sql immutable set search_path = kut, pg_catalog as $$
  select p_player.lifecycle_stage <> 'retired'
$$;

-- 4. Access ---------------------------------------------------------------------------

alter table kut.academy_go_live enable row level security;
alter table kut.academy_credits enable row level security;
alter table kut.player_lifecycle_events enable row level security;
alter table kut.player_lifecycle enable row level security;
create policy "admins read the go-live record" on kut.academy_go_live
  for select to authenticated using (kut.is_admin());
create policy "admins read academy credits" on kut.academy_credits
  for select to authenticated using (kut.is_admin());
create policy "admins read lifecycle events" on kut.player_lifecycle_events
  for select to authenticated using (kut.is_admin());
-- Read through kut.player_directory (security invoker): members from go-live.
create policy "members read the lifecycle from go-live" on kut.player_lifecycle
  for select to authenticated
  using (kut.is_admin() or ((select kut.is_active_member()) and (select kut.academy_is_live())));
revoke all on kut.academy_go_live, kut.academy_credits, kut.player_lifecycle_events, kut.player_lifecycle
  from public, anon, authenticated;
grant select on kut.academy_go_live, kut.academy_credits, kut.player_lifecycle_events, kut.player_lifecycle
  to authenticated, service_role;

revoke all on function kut.protect_player_lifecycle_stage(), kut.protect_player_lifecycle_events(),
  kut.can_mint_copies(kut.players), kut.is_midweek_playable(kut.players) from public, anon, authenticated;
grant execute on function kut.can_mint_copies(kut.players), kut.is_midweek_playable(kut.players) to service_role;
revoke all on function kut._football_week(date), kut.academy_is_live() from public, anon;
grant execute on function kut._football_week(date), kut.academy_is_live() to authenticated, service_role;

-- 5. Message types -------------------------------------------------------------------

do $$ declare v_name text; begin
  select conname into v_name from pg_constraint
  where conrelid = 'kut.user_notifications'::regclass and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%event_type%' and pg_get_constraintdef(oid) ilike '%midweek_result%';
  if v_name is null then raise exception 'notification event_type constraint not found'; end if;
  execute format('alter table kut.user_notifications drop constraint %I', v_name);
end $$;
alter table kut.user_notifications add constraint user_notifications_event_type_check check (event_type in (
  'market_sale','market_purchase','attendance_reward','pack_opened','admin_notice','bibs_bonus','trade_offer','trade_response','session_report','session_results','report_correction','kudos_awarded','injury_check_in','midweek_result',
  'player_promoted','player_at_risk','player_retired'
));

-- 6. Helpers -----------------------------------------------------------------------------

-- The Live card now (30 / common before any published attendance).
create function kut._lifecycle_card(p_player_id uuid, out live_ovr integer, out rarity_tier text)
language sql stable security definer set search_path = kut, pg_catalog as $$
  select coalesce(state.live_ovr, 30), coalesce(state.rarity_tier, 'common')
  from (select 1) one
  left join kut.seasons season on season.is_active
  left join kut.player_season_state state on state.player_id = p_player_id and state.season_id = season.id
$$;

-- Progress = distinct real counted weeks in the last 8 counted weeks (only
-- after p_since, a retirement week, for a comeback) + active credits (at most
-- 2; for a comeback only those granted from the retirement week). Fading:
-- progress is exactly 2 and, without an appearance, the next counted week
-- takes a real week out of the window or expires a credit.
create function kut._lifecycle_progress(
  p_player_id uuid, p_counted date[], p_attended date[], p_now date, p_since date,
  out real_weeks date[], out credit_weeks date[], out total integer, out fading boolean)
language sql stable security definer set search_path = kut, pg_catalog as $$
  with window_weeks as (
    select counted_week from unnest(p_counted) counted_week
    where counted_week <= p_now order by counted_week desc limit 8
  ),
  real_window as (
    select coalesce(array_agg(counted_week order by counted_week), '{}') as weeks
    from window_weeks
    where counted_week = any(p_attended) and (p_since is null or counted_week > p_since)
  ),
  active_credits as (
    select credit.granted_week, used.weeks
    from kut.academy_credits credit
    cross join lateral (
      select count(*) as weeks from unnest(p_counted) counted_week
      where counted_week > credit.granted_week and counted_week <= p_now
    ) used
    where credit.player_id = p_player_id and credit.granted_week <= p_now
      and (p_since is null or credit.granted_week >= p_since)
      and used.weeks < 8
    order by credit.granted_at desc, credit.id desc
    limit 2
  )
  select real_window.weeks,
    coalesce((select array_agg(granted_week order by granted_week) from active_credits), '{}'),
    cardinality(real_window.weeks) + (select count(*) from active_credits)::integer,
    cardinality(real_window.weeks) + (select count(*) from active_credits)::integer = 2 and (
      ((select count(*) from window_weeks) = 8 and (select min(counted_week) from window_weeks) = any(real_window.weeks))
      or exists (select 1 from active_credits where active_credits.weeks = 7))
  from real_window
$$;

-- At risk and Retired go to the owners of copies, listed or escrowed copies
-- included (they keep owner_id); keyed to the event, so a re-run never re-sends.
create function kut._notify_lifecycle_owners(p_event_id uuid, p_absent integer)
returns void language plpgsql security definer set search_path = kut, pg_catalog as $$
declare v_event record;
begin
  select event.kind, event.player_id, player.display_name into v_event
  from kut.player_lifecycle_events event
  join kut.players player on player.id = event.player_id
  where event.id = p_event_id;

  insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
  select owner.user_id,
    case v_event.kind when 'at_risk' then 'player_at_risk' else 'player_retired' end,
    case v_event.kind when 'at_risk' then format('%s is at risk of retiring', v_event.display_name)
      else format('%s has retired', v_event.display_name) end,
    case v_event.kind
      when 'at_risk' then format('%s counted weeks without a game; at 12 they retire. %s either way, but a Retired card can''t play Midweek.',
        p_absent, case when owner.copies = 1 then 'Your copy stays yours' else format('Your %s copies stay yours', owner.copies) end)
      else format('12 counted weeks without a game. %s to keep or trade, but can''t play Midweek. A comeback brings %s back.',
        case when owner.copies = 1 then 'Your copy stays yours' else format('Your %s copies stay yours', owner.copies) end,
        case when owner.copies = 1 then 'it' else 'them' end)
    end,
    'lifecycle_event', p_event_id
  from (
    select card.owner_id as user_id, count(*) as copies
    from kut.user_cards card
    join kut.card_editions edition on edition.id = card.edition_id
    join kut.profiles profile on profile.id = card.owner_id and not profile.is_disabled
    where edition.player_id = v_event.player_id and card.burned_at is null
    group by card.owner_id
  ) owner
  on conflict (user_id, event_type, reference_type, reference_id)
    where reference_type is not null and reference_id is not null do nothing;
end $$;

-- Promote to the First Team: the Live edition if missing (never a copy),
-- collectible, the stage, a permanent event and, from go-live, a message to
-- every member. p_from is the stage left: 'talent', 'retired' or 'new'.
create function kut._promote_player(p_player_id uuid, p_from text, p_reason text, p_week date, p_actor uuid)
returns uuid language plpgsql security definer set search_path = kut, pg_catalog as $$
declare v_name text; v_card record; v_event uuid; v_tier text;
begin
  select display_name into v_name from kut.players where id = p_player_id for update;
  insert into kut.card_editions (player_id, edition_type, title, is_live)
  values (p_player_id, 'live', v_name || ' Live', true)
  on conflict do nothing;
  update kut.players set is_collectible = true, lifecycle_stage = 'first_team' where id = p_player_id;

  select * into v_card from kut._lifecycle_card(p_player_id);
  insert into kut.player_lifecycle_events (player_id, kind, effective_week, reason, live_ovr, rarity_tier, created_by)
  values (p_player_id, 'promotion', p_week, p_reason, v_card.live_ovr, v_card.rarity_tier, p_actor)
  on conflict (player_id, kind, effective_week) do nothing
  returning id into v_event;
  if v_event is null or not kut.academy_is_live() then return v_event; end if;

  v_tier := initcap(v_card.rarity_tier) || ' ' || v_card.live_ovr;
  insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
  select profile.id, 'player_promoted',
    case when p_from = 'retired' then format('%s is back in the First Team', v_name)
      else format('%s joins the First Team', v_name) end,
    case
      when p_from = 'retired' then format('Out of retirement with the same Live card: %s. It''s in packs again and can play Midweek.', v_tier)
      when p_from = 'talent' and p_reason = 'progress' then format('Promoted from the Academy with a Live card: %s. It''s in packs from today, and has a slot in your album.', v_tier)
      else format('A new Live card: %s. It''s in packs from today, and has a slot in your album.', v_tier)
    end,
    'lifecycle_event', v_event
  from kut.profiles profile
  where not profile.is_disabled
  on conflict (user_id, event_type, reference_type, reference_id)
    where reference_type is not null and reference_id is not null do nothing;
  return v_event;
end $$;

-- 7. The evaluator ---------------------------------------------------------------------

-- Re-derives the stage and the snapshot of one Player (or all) as of the
-- football week of p_today (default: today, club time). Promotions are read,
-- never rewritten; retirements and warnings are reconciled with the walk.
create function kut._evaluate_lifecycle(p_player_id uuid default null, p_today date default null)
returns integer language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_now date := kut._football_week(p_today);
  v_go_live date := (select week_start from kut.academy_go_live);
  v_counted date[]; v_window date[];
  v_player record; v_tick record; v_open record;
  v_attended date[]; v_injured date[]; v_promotions date[]; v_latest_promotion date;
  v_state text; v_run integer; v_reset date; v_retired date; v_warned date;
  v_real date[]; v_credits date[]; v_total integer; v_fading boolean;
  v_card record; v_event uuid; v_count integer := 0;
begin
  -- Counted weeks span every season: the lifecycle never resets.
  select coalesce(array_agg(counted.week order by counted.week), '{}') into v_counted
  from (
    select distinct date_trunc('week', session.session_date)::date as week
    from kut.match_sessions session
    where session.status = 'published' and session.session_date < v_now + 7
  ) counted;
  v_window := coalesce(v_counted[greatest(cardinality(v_counted) - 7, 1):cardinality(v_counted)], '{}');

  for v_player in
    select player.id, player.lifecycle_stage, player.is_active
    from kut.players player
    where p_player_id is null or player.id = p_player_id
    order by player.id
    for update
  loop
    v_count := v_count + 1;
    v_real := '{}'; v_credits := '{}'; v_total := 0; v_fading := false;
    v_run := null; v_reset := null; v_retired := null; v_warned := null;

    select coalesce(array_agg(distinct date_trunc('week', session.session_date)::date
        order by date_trunc('week', session.session_date)::date), '{}')
    into v_attended
    from kut.attendance attendance
    join kut.match_sessions session on session.id = attendance.session_id
    where attendance.player_id = v_player.id and session.status = 'published'
      and session.session_date < v_now + 7;

    -- A counted week overlapping an injury period is not absent. A period
    -- ends at its manual end or the first published appearance after its
    -- start, whichever is earlier (derived, so it moves with corrections).
    select coalesce(array_agg(counted_week order by counted_week), '{}') into v_injured
    from unnest(v_counted) counted_week
    where exists (
      select 1
      from kut.injury_periods period
      cross join lateral (
        select least(period.ended_on, (
          select min(session.session_date)
          from kut.attendance attendance
          join kut.match_sessions session on session.id = attendance.session_id
          where attendance.player_id = period.player_id and session.status = 'published'
            and session.session_date > period.started_on)) as ended_on
      ) effective
      where period.player_id = v_player.id
        and period.started_on <= counted_week + 6
        and (effective.ended_on is null or effective.ended_on >= counted_week));

    select coalesce(array_agg(event.effective_week order by event.effective_week), '{}') into v_promotions
    from kut.player_lifecycle_events event
    where event.player_id = v_player.id and event.kind = 'promotion';

    v_state := v_player.lifecycle_stage;
    if v_state = 'talent' then
      select real_weeks, credit_weeks, total, fading into v_real, v_credits, v_total, v_fading
      from kut._lifecycle_progress(v_player.id, v_counted, v_attended, v_now, null);
      if v_go_live is not null and v_player.is_active and v_total >= 3 and cardinality(v_real) >= 1 then
        perform kut._promote_player(v_player.id, 'talent', 'progress', v_now, null);
        v_promotions := v_promotions || v_now;
        v_state := 'first_team'; v_run := 0; v_reset := v_now;
      end if;
    elsif v_go_live is not null then
      -- The First Team clock runs from the latest of go-live, a promotion and
      -- an appearance. 8 absent counted weeks warn; the 12th retires, and
      -- after that only a new promotion returns the Player.
      v_state := 'first_team'; v_run := 0; v_reset := v_go_live;
      for v_tick in
        select tick.week, bool_or(tick.counted) as counted, bool_or(tick.promoted) as promoted
        from (
          select counted_week as week, true as counted, false as promoted
          from unnest(v_counted) counted_week where counted_week > v_go_live
          union all
          select promoted_week, false, true
          from unnest(v_promotions) promoted_week where promoted_week > v_go_live and promoted_week <= v_now
        ) tick
        group by tick.week
        order by tick.week
      loop
        if v_tick.promoted then
          v_state := 'first_team'; v_run := 0; v_reset := v_tick.week; v_retired := null; v_warned := null;
        elsif v_state = 'first_team' then
          if v_tick.week = any(v_attended) then
            v_run := 0; v_reset := v_tick.week; v_warned := null;
          elsif not (v_tick.week = any(v_injured)) then
            v_run := v_run + 1;
            if v_run = 8 then v_warned := v_tick.week; end if;
            if v_run >= 12 then v_state := 'retired'; v_retired := v_tick.week; end if;
          end if;
        end if;
      end loop;

      -- The open retirement episode: events after the latest promotion.
      v_latest_promotion := (select max(promoted_week) from unnest(v_promotions) promoted_week);
      select event.id, event.effective_week, event.undone_at into v_open
      from kut.player_lifecycle_events event
      where event.player_id = v_player.id and event.kind = 'retirement'
        and (v_latest_promotion is null or event.effective_week > v_latest_promotion)
      order by event.created_at desc, event.id desc
      limit 1;
      if v_state = 'retired' then
        if not found then
          select * into v_card from kut._lifecycle_card(v_player.id);
          insert into kut.player_lifecycle_events (player_id, kind, effective_week, live_ovr, rarity_tier)
          values (v_player.id, 'retirement', v_retired, v_card.live_ovr, v_card.rarity_tier)
          returning id into v_event;
          perform kut._notify_lifecycle_owners(v_event, 12);
        elsif v_open.undone_at is not null or v_open.effective_week <> v_retired then
          -- The same episode, moved or revived by a correction: no new message.
          update kut.player_lifecycle_events set undone_at = null, effective_week = v_retired where id = v_open.id;
        end if;
        update kut.players set lifecycle_stage = 'retired' where id = v_player.id and lifecycle_stage <> 'retired';

        select real_weeks, credit_weeks, total, fading into v_real, v_credits, v_total, v_fading
        from kut._lifecycle_progress(v_player.id, v_counted, v_attended, v_now, v_retired);
        if v_player.is_active and v_total >= 3 and cardinality(v_real) >= 1 then
          perform kut._promote_player(v_player.id, 'retired', 'progress', v_now, null);
          v_promotions := v_promotions || v_now;
          v_state := 'first_team'; v_run := 0; v_reset := v_now; v_retired := null; v_warned := null;
        end if;
      elsif found and v_open.undone_at is null then
        -- A correction removed the cause: the retirement is undone.
        update kut.player_lifecycle_events set undone_at = now() where id = v_open.id;
      end if;

      if v_state = 'first_team' and v_run >= 8 and not exists (
        select 1 from kut.player_lifecycle_events event
        where event.player_id = v_player.id and event.kind = 'at_risk' and event.effective_week > v_reset
      ) then
        select * into v_card from kut._lifecycle_card(v_player.id);
        insert into kut.player_lifecycle_events (player_id, kind, effective_week, live_ovr, rarity_tier)
        values (v_player.id, 'at_risk', v_warned, v_card.live_ovr, v_card.rarity_tier)
        returning id into v_event;
        perform kut._notify_lifecycle_owners(v_event, v_run);
      end if;
    end if;

    update kut.players set lifecycle_stage = v_state
    where id = v_player.id and lifecycle_stage is distinct from v_state;

    insert into kut.player_lifecycle as lifecycle (
      player_id, window_weeks, played_weeks, credit_weeks, progress, academy_visible, fading,
      absent_weeks, at_risk, clock_start, retired_week, promoted_week, evaluated_at)
    values (
      v_player.id, v_window, v_real, v_credits, v_total, v_total >= 2 and v_state <> 'first_team', v_fading and v_state <> 'first_team',
      v_run, coalesce(v_state = 'first_team' and v_run >= 8, false), v_reset, v_retired,
      (select max(promoted_week) from unnest(v_promotions) promoted_week), now())
    on conflict (player_id) do update set
      window_weeks = excluded.window_weeks, played_weeks = excluded.played_weeks,
      credit_weeks = excluded.credit_weeks, progress = excluded.progress,
      academy_visible = excluded.academy_visible, fading = excluded.fading,
      absent_weeks = excluded.absent_weeks, at_risk = excluded.at_risk,
      clock_start = excluded.clock_start, retired_week = excluded.retired_week,
      promoted_week = excluded.promoted_week, evaluated_at = excluded.evaluated_at;
  end loop;
  return v_count;
end $$;

revoke all on function kut._lifecycle_card(uuid), kut._lifecycle_progress(uuid, date[], date[], date, date),
  kut._notify_lifecycle_owners(uuid, integer), kut._promote_player(uuid, text, text, date, uuid),
  kut._evaluate_lifecycle(uuid, date) from public, anon, authenticated;
grant execute on function kut._evaluate_lifecycle(uuid, date) to service_role;

-- Founding First Team and any Talent-free history: a baseline snapshot.
select kut._evaluate_lifecycle();

-- 8. Re-evaluation after publish, correct, cancel and reactivate, and injuries -----

-- Source: 20260920010000_session_report_hardening.sql (adds the evaluation).
-- publish_session, correct_published_attendance_session, cancel_published_session
-- and reactivate_cancelled_session all end here, after their final state.
create or replace function kut.rebuild_season(p_season_id uuid)
returns integer language plpgsql security definer set search_path=kut,pg_catalog as $$
declare v_count integer;
begin
  if not kut.is_admin() and coalesce(auth.role(),'')<>'service_role' then
    raise exception 'admin or service access required' using errcode='42501';
  end if;
  v_count := kut._rebuild_season_core(p_season_id);
  perform kut._evaluate_lifecycle();
  return v_count;
end $$;

-- Source: 20260930000000_injury_protection.sql. Unlinked Players may be injured
-- (no message, no check-in); the Player is re-evaluated.
create or replace function kut.admin_start_injury(p_player_id uuid, p_started_on date, p_note text default null)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_today date := (now() at time zone 'Europe/Amsterdam')::date;
  v_user uuid; v_name text; v_period uuid;
begin
  if not kut.is_admin() then raise exception 'admin access required' using errcode = '42501'; end if;
  if p_player_id is null or p_started_on is null or p_started_on > v_today
    or (v_note is not null and char_length(v_note) > 200) then
    raise exception 'a player, an injury date no later than today and a note of at most 200 characters are required' using errcode = '22023';
  end if;
  select player.display_name, profile.id into v_name, v_user
  from kut.players player
  left join kut.profiles profile on profile.player_id = player.id and not profile.is_disabled
  where player.id = p_player_id;
  if v_name is null then raise exception 'player not found' using errcode = 'P0002'; end if;
  -- A Player without an account can be injured too (ADR-165), for lifecycle
  -- protection, the cast and Midweek fitness only: the check-in and its
  -- stipend stay a member action (ADR-082), and no message is sent.
  -- The stipend is a faucet; an admin never switches it on for themselves.
  if v_user = auth.uid() then raise exception 'you cannot put your own player in injury mode' using errcode = '42501'; end if;
  if exists (
    select 1 from kut.attendance a join kut.match_sessions s on s.id = a.session_id
    where a.player_id = p_player_id and s.status = 'published' and s.session_date > p_started_on
  ) then
    raise exception 'player has played since that date' using errcode = 'P0001';
  end if;

  -- A previous period whose Player has since returned is still open in the
  -- table (the active state is derived). Close it so the new one can start.
  update kut.injury_periods period
  set ended_on = greatest(period.started_on, least(v_today, (
        select min(s.session_date) from kut.attendance a join kut.match_sessions s on s.id = a.session_id
        where a.player_id = period.player_id and s.status = 'published' and s.session_date > period.started_on))),
      end_reason = 'returned to play'
  where period.player_id = p_player_id and period.ended_on is null
    and kut._active_injury_period(p_player_id) is distinct from period.id;

  begin
    insert into kut.injury_periods (player_id, started_on, note, started_by)
    values (p_player_id, p_started_on, v_note, auth.uid())
    returning id into v_period;
  exception when unique_violation then
    raise exception 'player is already in injury mode' using errcode = 'P0001';
  end;

  if v_user is not null then
    insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
    values (
      v_user, 'admin_notice', 'Injury mode on',
      'Get well soon! While you are out, check in from Home once every football week you sit out: you receive 100 KUT Coins and your card rating is protected for that week.',
      'injury_period', v_period
    )
    on conflict (user_id, event_type, reference_type, reference_id)
      where reference_type is not null and reference_id is not null do nothing;
  end if;
  perform kut._evaluate_lifecycle(p_player_id);

  return jsonb_build_object('period_id', v_period, 'player_id', p_player_id, 'display_name', v_name, 'started_on', p_started_on);
end $$;

-- Source: 20260930000000_injury_protection.sql. The Player is re-evaluated.
create or replace function kut.admin_end_injury(p_player_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_reason text := trim(coalesce(p_reason, ''));
  v_today date := (now() at time zone 'Europe/Amsterdam')::date;
  v_period record; v_user uuid; v_name text;
begin
  if not kut.is_admin() then raise exception 'admin access required' using errcode = '42501'; end if;
  if char_length(v_reason) not between 3 and 200 then
    raise exception 'a reason of 3-200 characters is required' using errcode = '22023';
  end if;
  select * into v_period from kut.injury_periods
  where player_id = p_player_id and ended_on is null for update;
  if not found then raise exception 'player is not in injury mode' using errcode = 'P0002'; end if;

  -- Protected weeks stay protected: ending a period never rewrites history, so
  -- no rebuild is needed here.
  update kut.injury_periods
  set ended_on = greatest(started_on, v_today), ended_by = auth.uid(), end_reason = v_reason
  where id = v_period.id;

  select player.display_name, profile.id into v_name, v_user
  from kut.players player
  left join kut.profiles profile on profile.player_id = player.id and not profile.is_disabled
  where player.id = p_player_id;
  if v_user is not null then
    insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
    values (v_user, 'admin_notice', 'Injury mode ended',
      format('An admin ended injury mode for your player. Reason: %s', v_reason),
      'injury_period_end', v_period.id)
    on conflict (user_id, event_type, reference_type, reference_id)
      where reference_type is not null and reference_id is not null do nothing;
  end if;

  perform kut._evaluate_lifecycle(p_player_id);
  return jsonb_build_object('period_id', v_period.id, 'player_id', p_player_id, 'display_name', v_name);
end $$;

-- 9. Admin actions ------------------------------------------------------------------------

-- Existing Players whose name is close to p_display_name: the same letters,
-- the same first name, or one name starting with the other (3+ letters).
create function kut.admin_similar_players(p_display_name text)
returns table (player_id uuid, slug text, display_name text, lifecycle_stage text, is_active boolean)
language plpgsql stable security definer set search_path = kut, pg_catalog as $$
#variable_conflict use_column
declare
  v_key text := regexp_replace(lower(coalesce(p_display_name, '')), '[^a-z0-9]+', '', 'g');
  v_first text := regexp_replace(lower(split_part(btrim(coalesce(p_display_name, '')), ' ', 1)), '[^a-z0-9]+', '', 'g');
begin
  if not kut.is_admin() then raise exception 'admin access required' using errcode = '42501'; end if;
  if v_key = '' then return; end if;
  return query
  select player.id, player.slug, player.display_name, player.lifecycle_stage, player.is_active
  from kut.players player
  cross join lateral (
    select regexp_replace(lower(player.display_name), '[^a-z0-9]+', '', 'g') as name_key,
      regexp_replace(lower(coalesce(player.full_name, '')), '[^a-z0-9]+', '', 'g') as full_key,
      regexp_replace(lower(split_part(btrim(player.display_name), ' ', 1)), '[^a-z0-9]+', '', 'g') as first_key
  ) keys
  where keys.name_key = v_key
    or keys.full_key = v_key
    or (v_first <> '' and keys.first_key = v_first)
    or (char_length(v_key) >= 3 and char_length(keys.name_key) >= 3
        and (keys.name_key like v_key || '%' or v_key like keys.name_key || '%'))
  order by player.display_name, player.id;
end $$;

-- The roster's "Add a Player" and attendance's add-on-the-spot: a Talent (the
-- default, no Live edition, 0-2 credits with a reason) or a direct First Team
-- Player. A similar existing name is refused unless p_allow_similar.
create function kut.admin_register_player(
  p_display_name text,
  p_archetype text default 'all_rounder',
  p_full_name text default null,
  p_stage text default 'talent',
  p_credits integer default 0,
  p_credit_reason text default null,
  p_allow_similar boolean default false
)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_display_name text := nullif(btrim(p_display_name), '');
  v_full_name text := nullif(btrim(coalesce(p_full_name, '')), '');
  v_reason text := nullif(btrim(coalesce(p_credit_reason, '')), '');
  v_base_slug text; v_slug text; v_suffix integer := 1;
  v_player_id uuid; v_season_id uuid; v_similar text;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;
  if v_display_name is null or char_length(v_display_name) > 80 then
    raise exception 'display name must be 1-80 characters' using errcode = '22023';
  end if;
  if p_archetype is null or p_archetype not in
     ('all_rounder','speedster','finisher','playmaker','defender','tank','goalkeeper') then
    raise exception 'invalid archetype: %', p_archetype using errcode = '22023';
  end if;
  if p_stage is null or p_stage not in ('talent', 'first_team') then
    raise exception 'a new Player starts as a Talent or in the First Team' using errcode = '22023';
  end if;
  if p_credits is null or p_credits not between 0 and 2 or (p_stage = 'first_team' and p_credits > 0) then
    raise exception 'a Talent starts with 0 to 2 credits, a First Team Player with none' using errcode = '22023';
  end if;
  if p_credits > 0 and (v_reason is null or char_length(v_reason) not between 3 and 200) then
    raise exception 'credits need a reason of 3-200 characters' using errcode = '22023';
  end if;
  if not coalesce(p_allow_similar, false) then
    select string_agg(similar_player.display_name, ', ') into v_similar
    from kut.admin_similar_players(v_display_name) similar_player;
    if v_similar is not null then
      raise exception 'a Player with a similar name exists: %', v_similar using errcode = 'P0001';
    end if;
  end if;

  v_base_slug := btrim(regexp_replace(lower(v_display_name), '[^a-z0-9]+', '-', 'g'), '-');
  if v_base_slug = '' then
    raise exception 'display name has no usable slug characters' using errcode = '22023';
  end if;
  v_slug := v_base_slug;
  while exists (select 1 from kut.players where slug = v_slug) loop
    v_suffix := v_suffix + 1;
    v_slug := v_base_slug || '-' || v_suffix;
  end loop;

  insert into kut.players (slug, display_name, full_name, archetype, is_collectible, lifecycle_stage)
  values (v_slug, v_display_name, v_full_name, p_archetype, false, case when p_stage = 'talent' then 'talent' else 'first_team' end)
  returning id into v_player_id;

  -- Baseline season state, as admin_add_player always did (30 OVR until they attend).
  select id into v_season_id from kut.seasons where is_active limit 1;
  if v_season_id is not null then
    perform kut._rebuild_season_core(v_season_id);
  end if;

  if p_stage = 'first_team' then
    perform kut._promote_player(v_player_id, 'new', 'admin', kut._football_week(), auth.uid());
  else
    insert into kut.academy_credits (player_id, reason, granted_by)
    select v_player_id, v_reason, auth.uid() from generate_series(1, p_credits);
  end if;
  perform kut._evaluate_lifecycle(v_player_id);

  return jsonb_build_object(
    'player_id', v_player_id,
    'slug', v_slug,
    'display_name', v_display_name,
    'archetype', p_archetype,
    'stage', p_stage,
    'credits', p_credits
  );
end $$;

-- Source: 20260906000000_goalkeeper_archetype.sql. Same signature and checks;
-- now the direct First Team route of admin_register_player (no name check, as
-- before), which also writes the promotion event with reason 'admin'.
create or replace function kut.admin_add_player(
  p_display_name text,
  p_archetype    text default 'all_rounder',
  p_full_name    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
begin
  return kut.admin_register_player(p_display_name, p_archetype, p_full_name, 'first_team', 0, null, true);
end;
$$;

-- Promote a Talent, or bring back a Retired Player: same Player ID and single
-- Live edition. A no-op on a First Team Player (retries never reset the
-- clock); never reactivates an inactive Player.
create function kut.admin_promote_player(p_player_id uuid)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare v_player record; v_event uuid;
begin
  if not kut.is_admin() then raise exception 'admin access required' using errcode = '42501'; end if;
  perform kut._evaluate_lifecycle(p_player_id);
  select id, display_name, lifecycle_stage, is_active into v_player
  from kut.players where id = p_player_id for update;
  if not found then raise exception 'player not found' using errcode = 'P0002'; end if;
  if v_player.lifecycle_stage = 'first_team' then
    return jsonb_build_object('player_id', p_player_id, 'display_name', v_player.display_name, 'stage', 'first_team', 'promoted', false);
  end if;
  if not v_player.is_active then
    raise exception 'reactivate the Player before promoting them' using errcode = 'P0001';
  end if;
  v_event := kut._promote_player(p_player_id, v_player.lifecycle_stage, 'admin', kut._football_week(), auth.uid());
  perform kut._evaluate_lifecycle(p_player_id);
  return jsonb_build_object('player_id', p_player_id, 'display_name', v_player.display_name, 'stage', 'first_team',
    'promoted', true, 'event_id', v_event);
end $$;

-- One audited credit for a Talent or a Retired Player; at most 2 active.
create function kut.admin_grant_academy_credit(p_player_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_reason text := btrim(coalesce(p_reason, ''));
  v_now date := kut._football_week();
  v_player record; v_credit uuid; v_active integer;
begin
  if not kut.is_admin() then raise exception 'admin access required' using errcode = '42501'; end if;
  if char_length(v_reason) not between 3 and 200 then
    raise exception 'a reason of 3-200 characters is required' using errcode = '22023';
  end if;
  perform kut._evaluate_lifecycle(p_player_id);
  select id, display_name, lifecycle_stage, is_active into v_player
  from kut.players where id = p_player_id for update;
  if not found then raise exception 'player not found' using errcode = 'P0002'; end if;
  if v_player.lifecycle_stage not in ('talent', 'retired') then
    raise exception 'credits are for Talents and Retired Players' using errcode = 'P0001';
  end if;
  if not v_player.is_active then
    raise exception 'reactivate the Player before giving a credit' using errcode = 'P0001';
  end if;
  select count(*) into v_active
  from kut.academy_credits credit
  where credit.player_id = p_player_id and credit.granted_week <= v_now
    and (select count(distinct date_trunc('week', session.session_date))
         from kut.match_sessions session
         where session.status = 'published'
           and session.session_date >= credit.granted_week + 7 and session.session_date < v_now + 7) < 8;
  if v_active >= 2 then
    raise exception 'a Player holds at most 2 active credits' using errcode = 'P0001';
  end if;

  insert into kut.academy_credits (player_id, reason, granted_by)
  values (p_player_id, v_reason, auth.uid())
  returning id into v_credit;
  perform kut._evaluate_lifecycle(p_player_id);
  return jsonb_build_object('player_id', p_player_id, 'credit_id', v_credit, 'active_credits', v_active + 1,
    'stage', (select lifecycle_stage from kut.players where id = p_player_id));
end $$;

-- Go-live: always the current football week, recorded once.
create function kut.admin_record_academy_go_live()
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare v_week date := kut._football_week();
begin
  if not kut.is_admin() then raise exception 'admin access required' using errcode = '42501'; end if;
  insert into kut.academy_go_live (week_start, recorded_by) values (v_week, auth.uid())
  on conflict (id) do nothing;
  if not found then raise exception 'the Academy is already live' using errcode = 'P0001'; end if;
  perform kut._evaluate_lifecycle();
  return jsonb_build_object('go_live_week', v_week);
end $$;

revoke all on function kut.admin_similar_players(text),
  kut.admin_register_player(text, text, text, text, integer, text, boolean),
  kut.admin_promote_player(uuid), kut.admin_grant_academy_credit(uuid, text),
  kut.admin_record_academy_go_live() from public, anon;
grant execute on function kut.admin_similar_players(text),
  kut.admin_register_player(text, text, text, text, integer, text, boolean),
  kut.admin_promote_player(uuid), kut.admin_grant_academy_credit(uuid, text),
  kut.admin_record_academy_go_live() to authenticated;

-- 10. Supply: new copies only of active First Team ---------------------------------

-- Source: 20261023000000_pack_tiers.sql (the predicate only).
create or replace function kut.pack_draw_pool()
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
    and kut.can_mint_copies(player)
$$;

-- Source: 20260903000000_drop_is_tradeable.sql (the predicate only).
create or replace function kut.grant_starter_pack(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_edition_ids uuid[];
begin
  perform 1 from kut.profiles where id = p_user_id and not is_disabled for update;
  if not found then
    raise exception 'active profile not found' using errcode = 'P0002';
  end if;

  if exists (select 1 from kut.profiles where id = p_user_id and starter_claimed_at is not null) then
    raise exception 'starter pack already claimed' using errcode = 'P0001';
  end if;

  select array_agg(id) into v_edition_ids
  from (
    select edition.id
    from kut.card_editions edition
    join kut.players player on player.id = edition.player_id
    where edition.is_live and kut.can_mint_copies(player)
    order by random()
    limit 3
  ) eligible;

  if coalesce(array_length(v_edition_ids, 1), 0) <> 3 then
    raise exception 'at least three eligible Live editions are required' using errcode = 'P0002';
  end if;

  update kut.profiles set starter_claimed_at = now() where id = p_user_id;
  insert into kut.wallets (user_id, balance) values (p_user_id, 0)
  on conflict (user_id) do nothing;
  update kut.wallets set balance = balance + 250, updated_at = now() where user_id = p_user_id;
  insert into kut.wallet_ledger (user_id, amount, reason, reference_type, reference_id, idempotency_key)
  values (p_user_id, 250, 'starter', 'profile', p_user_id, 'starter:' || p_user_id::text);
  insert into kut.user_cards (edition_id, owner_id, source)
  select edition_id, p_user_id, 'starter'
  from unnest(v_edition_ids) as edition_id;

  return jsonb_build_object('coins', 250, 'edition_ids', to_jsonb(v_edition_ids));
end;
$$;

-- Source: 20260911000000_trade_offers.sql (the predicate only).
create or replace function kut.admin_reset_account(
  p_user_id uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_caller_role text;
  v_target_role text;
  v_display_name text;
  v_prior record;
  v_old_balance bigint;
  v_edition_ids uuid[];
  v_burned integer;
  v_event_id uuid;
  v_offer record;
begin
  if not kut.is_admin() then
    raise exception 'admin access required' using errcode = '42501';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'you cannot reset your own account' using errcode = 'P0001';
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode = '22023';
  end if;

  select role into v_caller_role from kut.profiles where id = auth.uid();
  select role, display_name into v_target_role, v_display_name
  from kut.profiles where id = p_user_id for update;
  if v_target_role is null then
    raise exception 'account not found' using errcode = 'P0002';
  end if;
  if v_target_role = 'superadmin' then
    raise exception 'superadmin accounts cannot be reset here' using errcode = 'P0001';
  end if;
  if v_target_role = 'admin' and v_caller_role <> 'superadmin' then
    raise exception 'only a superadmin can reset an administrator account' using errcode = '42501';
  end if;

  select id, amount, detail into v_prior
  from kut.admin_account_events
  where action = 'account_reset'
    and target_user_id = p_user_id
    and detail ->> 'idempotency_key' = p_idempotency_key::text
  limit 1;
  if found then
    return jsonb_build_object(
      'user_id', p_user_id,
      'display_name', v_display_name,
      'already_processed', true,
      'event_id', v_prior.id,
      'net_wallet_change', v_prior.amount
    );
  end if;

  insert into kut.wallets (user_id, balance) values (p_user_id, 0)
  on conflict (user_id) do nothing;

  -- ADR-042: unwind every active trade offer this member is party to (as
  -- proposer or seller) before the wallet snapshot below.
  for v_offer in
    select id, proposer_id from kut.trade_offers
    where status = 'active' and (proposer_id = p_user_id or seller_id = p_user_id)
    for update
  loop
    perform kut._refund_trade_offer(v_offer.id);
    update kut.trade_offers set status = 'rejected', resolved_at = now() where id = v_offer.id;
    insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
    values (v_offer.proposer_id, 'trade_response', 'Trade offer cancelled',
      'A club reset cancelled this trade offer; any escrow was refunded.', 'trade_offer', v_offer.id);
  end loop;

  select coalesce(balance, 0) into v_old_balance from kut.wallets where user_id = p_user_id for update;
  v_old_balance := coalesce(v_old_balance, 0);

  -- Cancel the member's active listings first, so the
  -- prevent_burning_listed_card trigger does not block the burn below.
  update kut.market_listings
  set status = 'cancelled', cancelled_at = now()
  where seller_id = p_user_id and status = 'active';

  update kut.user_cards set burned_at = now()
  where owner_id = p_user_id and burned_at is null;
  get diagnostics v_burned = row_count;

  delete from kut.pack_opening_cards
  where opening_id in (select id from kut.pack_openings where user_id = p_user_id);
  delete from kut.pack_openings where user_id = p_user_id;

  delete from kut.user_notifications where user_id = p_user_id;

  if v_old_balance <> 0 then
    insert into kut.wallet_ledger (user_id, amount, reason, reference_type, reference_id, idempotency_key)
    values (
      p_user_id, -v_old_balance, 'admin_reset', 'profile', p_user_id,
      'admin-reset-clear:' || p_idempotency_key::text
    );
  end if;

  select array_agg(id) into v_edition_ids
  from (
    select edition.id
    from kut.card_editions edition
    join kut.players player on player.id = edition.player_id
    where edition.is_live and kut.can_mint_copies(player)
    order by random()
    limit 3
  ) eligible;
  if coalesce(array_length(v_edition_ids, 1), 0) <> 3 then
    raise exception 'at least three eligible Live editions are required' using errcode = 'P0002';
  end if;

  insert into kut.wallet_ledger (user_id, amount, reason, reference_type, reference_id, idempotency_key)
  values (
    p_user_id, 250, 'admin_reset', 'profile', p_user_id,
    'admin-reset-starter:' || p_idempotency_key::text
  );
  insert into kut.user_cards (edition_id, owner_id, source)
  select edition_id, p_user_id, 'starter' from unnest(v_edition_ids) as edition_id;

  update kut.wallets set balance = 250, updated_at = now() where user_id = p_user_id;

  update kut.profiles set starter_opened_at = null, updated_at = now() where id = p_user_id;

  insert into kut.admin_account_events (target_user_id, actor_id, action, amount, reason, detail)
  values (
    p_user_id, auth.uid(), 'account_reset', 250 - v_old_balance, null,
    jsonb_build_object(
      'idempotency_key', p_idempotency_key::text,
      'coins_removed', v_old_balance,
      'cards_burned', v_burned,
      'starter_edition_ids', to_jsonb(v_edition_ids)
    )
  )
  returning id into v_event_id;

  insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
  values (
    p_user_id, 'admin_notice', 'Club reset',
    'Your KUT club was reset by an admin. You''ve been given a fresh starter pack.',
    'admin_account_event', v_event_id
  );

  return jsonb_build_object(
    'user_id', p_user_id,
    'display_name', v_display_name,
    'already_processed', false,
    'event_id', v_event_id,
    'cards_burned', v_burned,
    'coins_removed', v_old_balance,
    'net_wallet_change', 250 - v_old_balance
  );
end;
$$;

-- Source: 20261015000000_midweek_archetype_rotation.sql (the predicate only:
-- a Talent or Retired Player is not rotated, Part L 27).
create or replace function kut._mm_rotate_archetypes(p_seed bytea)
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare v_changes jsonb; v_season_id uuid;
begin
  if p_seed is null then raise exception 'a rotation needs a seed' using errcode = '22004'; end if;

  with draws as (
    select player.id, player.archetype as from_archetype,
      kut._mm_rotation_archetype(p_seed, player.id) as to_archetype
    from kut.players player
    where kut.can_mint_copies(player)
      and not exists (select 1 from kut.profiles profile where profile.player_id = player.id)
    for update of player
  ),
  changed as (
    update kut.players player
    set archetype = draws.to_archetype
    from draws
    where player.id = draws.id and player.archetype <> draws.to_archetype
    returning player.id, draws.from_archetype, draws.to_archetype
  )
  select coalesce(jsonb_agg(jsonb_build_object('playerId', id, 'from', from_archetype, 'to', to_archetype)
    order by id), '[]'::jsonb)
  into v_changes
  from changed;

  if jsonb_array_length(v_changes) > 0 then
    select id into v_season_id from kut.seasons where is_active limit 1;
    if v_season_id is not null then
      perform kut._rebuild_season_core(v_season_id);
    end if;
  end if;
  return v_changes;
end $$;

-- 11. Midweek: Retired cards don't play -------------------------------------------

-- Source: 20261008000000_midweek_archetype_snapshot.sql. The lock leaves out
-- Retired cards (the authority); a Retired saved pick warns as unavailable.
create or replace function kut._mm_field(p_tournament_id uuid, p_as_of timestamptz)
returns jsonb language plpgsql stable security definer set search_path = kut, pg_catalog as $$
declare v_entrants jsonb; v_warnings jsonb;
begin
  with members as (
    select profile.id as user_id, profile.display_name
    from kut.profiles profile
    where not profile.is_disabled
      and not exists (
        select 1 from kut.midweek_opt_outs opt_out
        where opt_out.user_id = profile.id and opt_out.opted_out_at <= p_as_of)
  ),
  held as (
    select card.owner_id as user_id, card.id as card_id, edition.player_id,
      coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
      coalesce(snapshot.archetype, player.archetype) as archetype,
      edition.is_live and kut._active_injury_period(player.id) is not null as injured,
      kut.is_midweek_playable(player) as playable
    from kut.user_cards card
    join members on members.user_id = card.owner_id
    join kut.card_editions edition on edition.id = card.edition_id
    join kut.players player on player.id = edition.player_id
    left join kut.midweek_archetype_snapshots snapshot
      on snapshot.tournament_id = p_tournament_id and snapshot.player_id = player.id
    left join kut.seasons active_season on active_season.is_active
    left join kut.player_season_state state on state.player_id = player.id and state.season_id = active_season.id
    where card.burned_at is null
  ),
  -- Retired cards don't play: a saved one is dropped like a sold card.
  cards as (
    select user_id, card_id, player_id, ovr, archetype, injured from held where playable
  ),
  saved as (
    select squad.user_id, squad_card.slot, squad_card.card_id,
      exists (select 1 from cards where cards.card_id = squad_card.card_id and cards.user_id = squad.user_id) as kept,
      exists (select 1 from held where held.card_id = squad_card.card_id and held.user_id = squad.user_id) as still_owned
    from kut.midweek_squads squad
    join kut.midweek_squad_cards squad_card on squad_card.squad_id = squad.id
    where squad.tournament_id = p_tournament_id
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'userId', members.user_id,
      'saved', coalesce((
        select jsonb_agg(jsonb_build_object('cardId', cards.card_id, 'playerId', cards.player_id, 'ovr', cards.ovr,
          'archetype', cards.archetype, 'injured', cards.injured) order by saved.slot)
        from saved join cards on cards.card_id = saved.card_id
        where saved.user_id = members.user_id and saved.kept), '[]'::jsonb),
      'owned', (
        select jsonb_agg(jsonb_build_object('cardId', cards.card_id, 'playerId', cards.player_id, 'ovr', cards.ovr,
          'archetype', cards.archetype, 'injured', cards.injured) order by cards.card_id)
        from cards where cards.user_id = members.user_id)
    ) order by members.user_id), '[]'::jsonb),
    (select coalesce(jsonb_agg(jsonb_build_object('level', 'warning', 'message', format(
        case
          when lost.still_owned and exists (select 1 from saved kept where kept.user_id = lost.user_id and kept.kept)
            then '%s: the card saved in slot %s is no longer available for Midweek, so a trialist plays'
          when lost.still_owned
            then '%s: the card saved in slot %s is no longer available for Midweek, and none is left, so an auto squad plays'
          when exists (select 1 from saved kept where kept.user_id = lost.user_id and kept.kept)
            then '%s: the card saved in slot %s is no longer theirs, so a trialist plays'
          else '%s: the card saved in slot %s is no longer theirs, and none is left, so an auto squad plays' end,
        member.display_name, lost.slot)) order by member.display_name, lost.slot), '[]'::jsonb)
      from saved lost
      join members member on member.user_id = lost.user_id
      where not lost.kept and exists (select 1 from cards where cards.user_id = lost.user_id))
  into v_entrants, v_warnings
  from members
  where exists (select 1 from cards where cards.user_id = members.user_id);

  return jsonb_build_object('entrants', v_entrants, 'warnings', v_warnings);
end $$;

-- Source: 20261003000000_midweek_entry.sql. Rejects a Retired pick, even from
-- a stale client.
create or replace function kut.save_midweek_squad(p_card_ids uuid[])
returns jsonb language plpgsql security definer set search_path = kut, pg_catalog as $$
declare
  v_user uuid := auth.uid();
  v_count integer := coalesce(cardinality(p_card_ids), 0);
  v_tournament record; v_squad uuid; v_owned integer; v_players integer;
begin
  if v_user is null or not exists (select 1 from kut.profiles where id = v_user and not is_disabled) then
    raise exception 'an active KUT account is required' using errcode = '42501';
  end if;
  if exists (select 1 from kut.midweek_opt_outs where user_id = v_user) then
    raise exception 'you have opted out of Midweek Madness' using errcode = 'P0001';
  end if;
  if v_count not between 1 and 5
    or array_position(p_card_ids, null) is not null
    or (select count(distinct card_id) from unnest(p_card_ids) card_id) <> v_count
  then
    raise exception 'pick between one and five different cards' using errcode = '22023';
  end if;

  -- A shared lock: saves run side by side, but the worker's lock step (which
  -- takes the row for update) waits for them, and they wait for it.
  select id, week_start, lock_at into v_tournament
  from kut.midweek_tournaments
  where status = 'open'
  order by week_start
  limit 1
  for share;
  if not found then raise exception 'no Midweek Madness tournament is open' using errcode = 'P0002'; end if;
  if now() >= v_tournament.lock_at then raise exception 'squads are locked' using errcode = 'P0001'; end if;

  select count(*), count(distinct edition.player_id) into v_owned, v_players
  from kut.user_cards card
  join kut.card_editions edition on edition.id = card.edition_id
  where card.id = any(p_card_ids) and card.owner_id = v_user and card.burned_at is null;
  if v_owned <> v_count then
    raise exception 'you can only pick active cards you own' using errcode = '22023';
  end if;
  if v_players <> v_count then
    raise exception 'each card must be a different Player' using errcode = '22023';
  end if;
  if exists (
    select 1 from kut.user_cards card
    join kut.card_editions edition on edition.id = card.edition_id
    join kut.players player on player.id = edition.player_id
    where card.id = any(p_card_ids) and not kut.is_midweek_playable(player)
  ) then
    raise exception 'a Retired card can''t play Midweek' using errcode = '22023';
  end if;

  insert into kut.midweek_squads (tournament_id, user_id)
  values (v_tournament.id, v_user)
  on conflict (tournament_id, user_id) do update set saved_at = now()
  returning id into v_squad;
  delete from kut.midweek_squad_cards where squad_id = v_squad;
  insert into kut.midweek_squad_cards (squad_id, slot, card_id, player_id)
  select v_squad, picked.slot::smallint, card.id, edition.player_id
  from unnest(p_card_ids) with ordinality as picked(card_id, slot)
  join kut.user_cards card on card.id = picked.card_id
  join kut.card_editions edition on edition.id = card.edition_id;

  return jsonb_build_object(
    'tournament_id', v_tournament.id,
    'week_start', v_tournament.week_start,
    'lock_at', v_tournament.lock_at,
    'cards', v_count
  );
end $$;

-- 12. Views: appended columns, Retired out of rating lists, two projections --------

-- Source: 20260830000000_member_self_service_and_player_directory.sql. The
-- album roster: appends the stage and the At risk warning (false before go-live).
create or replace view kut.player_directory
with (security_invoker = true, security_barrier = true)
as
select
  p.id,
  p.slug,
  p.display_name,
  p.archetype,
  p.photo_path,
  p.created_at,
  coalesce(s.live_ovr, 30) as live_ovr,
  coalesce(s.pac, 30) as pac,
  coalesce(s.sho, 30) as sho,
  coalesce(s.pas, 30) as pas,
  coalesce(s.dri, 30) as dri,
  coalesce(s.def, 30) as def,
  coalesce(s.phy, 30) as phy,
  coalesce(s.rarity_tier, 'common') as rarity_tier,
  p.lifecycle_stage,
  coalesce(lifecycle.at_risk, false) as at_risk
from kut.players p
left join kut.seasons season on season.is_active
left join kut.player_season_state s on s.player_id = p.id and s.season_id = season.id
left join kut.player_lifecycle lifecycle on lifecycle.player_id = p.id
where p.is_active and p.is_collectible;

-- Source: 20260928000000_active_member_projection_gate.sql. Retired Players
-- leave the rating list.
create or replace view kut.public_live_ratings
with (security_invoker = false, security_barrier = true)
as
select * from (

select
  p.id,
  p.slug,
  p.display_name,
  p.archetype,
  state.live_ovr,
  state.pac,
  state.sho,
  state.pas,
  state.dri,
  state.def,
  state.phy,
  state.rarity_tier,
  p.photo_path
from kut.players p
join kut.player_season_state state on state.player_id = p.id
join kut.seasons season on season.id = state.season_id
where p.is_active
  and p.is_collectible
  and p.lifecycle_stage <> 'retired'
  and season.is_active

) gated
where kut.is_active_member();

-- Source: 20260902000000_starter_reveal_and_rating_snapshots.sql. Retired
-- Players leave Home's risers.
create or replace view kut.top_risers
with (security_invoker = true, security_barrier = true)
as
with ranked_weeks as (
  select season_id, week_start,
    dense_rank() over (partition by season_id order by week_start desc) as recency
  from (select distinct season_id, week_start from kut.player_rating_snapshots) distinct_weeks
),
current_week as (
  select snap.player_id, snap.season_id, snap.live_ovr
  from kut.player_rating_snapshots snap
  join ranked_weeks rw on rw.season_id = snap.season_id and rw.week_start = snap.week_start and rw.recency = 1
),
previous_week as (
  select snap.player_id, snap.season_id, snap.live_ovr
  from kut.player_rating_snapshots snap
  join ranked_weeks rw on rw.season_id = snap.season_id and rw.week_start = snap.week_start and rw.recency = 2
)
select
  player.id,
  player.slug,
  player.display_name,
  player.archetype,
  player.photo_path,
  state.live_ovr,
  state.pac, state.sho, state.pas, state.dri, state.def, state.phy,
  state.rarity_tier,
  (current_week.live_ovr - previous_week.live_ovr) as ovr_delta
from current_week
join previous_week
  on previous_week.player_id = current_week.player_id
 and previous_week.season_id = current_week.season_id
join kut.seasons season on season.id = current_week.season_id and season.is_active
join kut.players player on player.id = current_week.player_id
join kut.player_season_state state
  on state.player_id = current_week.player_id
 and state.season_id = current_week.season_id
where player.is_active
  and player.is_collectible
  and player.lifecycle_stage <> 'retired'
  and (current_week.live_ovr - previous_week.live_ovr) > 0
order by ovr_delta desc, state.live_ovr desc, player.display_name;

-- Source: 20261018000000_special_snapshot_tiers.sql. Appends the Player's stage
-- for the Retired stamp on current card surfaces.
create or replace view kut.my_collection_cards
with (security_invoker = true, security_barrier = true)
as
select card.id as card_id, card.edition_id, card.source, card.acquired_at,
  edition.title as edition_title, edition.edition_type, edition.is_live,
  player.id as player_id, player.slug as player_slug, player.display_name, player.archetype,
  coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
  coalesce(edition.snapshot_pac, state.pac, 30) as pac, coalesce(edition.snapshot_sho, state.sho, 30) as sho,
  coalesce(edition.snapshot_pas, state.pas, 30) as pas, coalesce(edition.snapshot_dri, state.dri, 30) as dri,
  coalesce(edition.snapshot_def, state.def, 30) as def, coalesce(edition.snapshot_phy, state.phy, 30) as phy,
  case when edition.is_live then coalesce(state.rarity_tier, 'common') else edition.snapshot_rarity_tier end as rarity_tier,
  round(10 * power(1.08::numeric, coalesce(edition.snapshot_ovr, state.live_ovr, 30) - 30) * case when edition.is_live then 1 else coalesce(edition.special_discard_multiplier, 1) end)::bigint as discard_value,
  listing.id as active_listing_id, listing.price as active_listing_price, listing.expires_at as active_listing_expires_at,
  player.photo_path,
  card.held_by_offer_id,
  player.lifecycle_stage as player_stage
from kut.user_cards card
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state on state.player_id = player.id and state.season_id = active_season.id
left join kut.market_listings listing on listing.card_id = card.id and listing.status = 'active' and listing.expires_at > now()
where card.owner_id = auth.uid() and card.burned_at is null;

-- Source: 20261018000000_special_snapshot_tiers.sql. Appends the stage: a
-- listing says the copy can't play Midweek while Retired.
create or replace view kut.active_market_listings
with (security_invoker = false, security_barrier = true)
as
select * from (

select listing.id as listing_id, listing.price, listing.listed_at, listing.expires_at,
  card.id as card_id, edition.id as edition_id, player.display_name, player.archetype,
  coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
  coalesce(edition.snapshot_pac, state.pac, 30) as pac, coalesce(edition.snapshot_sho, state.sho, 30) as sho,
  coalesce(edition.snapshot_pas, state.pas, 30) as pas, coalesce(edition.snapshot_dri, state.dri, 30) as dri,
  coalesce(edition.snapshot_def, state.def, 30) as def, coalesce(edition.snapshot_phy, state.phy, 30) as phy,
  case when edition.is_live then coalesce(state.rarity_tier, 'common') else edition.snapshot_rarity_tier end as rarity_tier,
  seller.display_name as seller_display_name,
  player.photo_path,
  listing.seller_id,
  edition.player_id,
  edition.is_live,
  case
    when coalesce(edition.snapshot_ovr, state.live_ovr) is not null
      then kut.card_discard_value(card.id)
  end as discard_value,
  player.lifecycle_stage as player_stage
from kut.market_listings listing
join kut.profiles seller on seller.id = listing.seller_id
join kut.user_cards card on card.id = listing.card_id
join kut.card_editions edition on edition.id = card.edition_id
join kut.players player on player.id = edition.player_id
left join kut.seasons active_season on active_season.is_active
left join kut.player_season_state state on state.player_id = player.id and state.season_id = active_season.id
where listing.status = 'active' and listing.expires_at > now() and card.burned_at is null

) gated
where kut.is_active_member();

-- The go-live week for members ("feature unavailable" without a row).
create view kut.academy_status
with (security_invoker = false, security_barrier = true)
as
select * from (
  select go_live.week_start as go_live_week, go_live.recorded_at
  from kut.academy_go_live go_live
) gated
where kut.is_active_member();

-- Every Player's stage and lifecycle: the Academy (visible Talents and
-- comebacks), profiles of every stage, and the admin roster's Stage and Clock
-- columns. Members from go-live (active Players only); admins always.
create view kut.player_lifecycle_public
with (security_invoker = false, security_barrier = true)
as
select * from (
  select player.id as player_id, player.slug, player.display_name, player.archetype, player.photo_path,
    player.is_active, player.lifecycle_stage,
    coalesce(state.live_ovr, 30) as live_ovr, coalesce(state.rarity_tier, 'common') as rarity_tier,
    coalesce(lifecycle.progress, 0) as progress,
    coalesce(cardinality(lifecycle.played_weeks), 0) as progress_weeks,
    coalesce(cardinality(lifecycle.credit_weeks), 0) as progress_credits,
    coalesce(lifecycle.academy_visible, false) as academy_visible,
    coalesce(lifecycle.fading, false) as fading,
    lifecycle.window_weeks, lifecycle.played_weeks, lifecycle.credit_weeks,
    lifecycle.absent_weeks, coalesce(lifecycle.at_risk, false) as at_risk,
    lifecycle.clock_start, lifecycle.retired_week, lifecycle.promoted_week
  from kut.players player
  left join kut.player_lifecycle lifecycle on lifecycle.player_id = player.id
  left join kut.seasons season on season.is_active
  left join kut.player_season_state state on state.player_id = player.id and state.season_id = season.id
  where player.is_active or kut.is_admin()
) gated
where kut.is_admin() or (kut.is_active_member() and kut.academy_is_live());

-- The Chronicle's "The roster" block: promotions and standing retirements from
-- go-live, with the card as it was at the event. At risk is not news.
create view kut.player_lifecycle_events_public
with (security_invoker = false, security_barrier = true)
as
select * from (
  select event.id, event.player_id, player.slug, player.display_name, event.kind, event.effective_week,
    event.reason, event.live_ovr, event.rarity_tier, event.created_at
  from kut.player_lifecycle_events event
  join kut.players player on player.id = event.player_id
  join kut.academy_go_live go_live on event.effective_week >= go_live.week_start
  where event.kind in ('promotion', 'retirement') and event.undone_at is null
) gated
where kut.is_active_member();

revoke all on kut.academy_status, kut.player_lifecycle_public, kut.player_lifecycle_events_public from public, anon;
grant select on kut.academy_status, kut.player_lifecycle_public, kut.player_lifecycle_events_public
  to authenticated, service_role;
