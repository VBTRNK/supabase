-- ADR-152 / #286. Access-only: no DML, grant or view changes.
-- Restrictive SELECT policies AND membership with the existing permissive
-- scopes, including ALL admin policies; they never grant additional rows.
-- Profiles stay readable by their owner so login can detect a disabled account.
-- Admin-only policies already require an enabled admin. Service role bypasses
-- RLS, and definer projections keep their existing membership gates.
-- Rollback: drop "active membership required for reads" on the listed tables;
-- restore the photo SELECT predicate to bucket_id = 'player-photos'.

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'players', 'seasons', 'match_sessions', 'attendance', 'player_season_state',
    'card_editions', 'user_cards', 'wallets', 'wallet_ledger', 'attendance_rewards',
    'pack_definitions', 'pack_openings', 'pack_opening_cards', 'market_listings',
    'market_sales', 'user_notifications', 'player_rating_snapshots', 'bibs_rewards',
    'trade_offers', 'trade_offer_cards', 'card_wants', 'trade_availability',
    'kudos_categories', 'session_surveys', 'session_survey_eligibility',
    'session_reports', 'session_kudos', 'session_report_requests',
    'session_report_rewards', 'session_report_results', 'injury_check_ins'
  ] loop
    execute format(
      'create policy "active membership required for reads" on kut.%I
       as restrictive for select to authenticated
       using ((select kut.is_active_member()))', v_table
    );
  end loop;
end $$;

-- Scope this to our private bucket: Storage is shared with other tools.
alter policy "member reads player photos" on storage.objects
  using (bucket_id = 'player-photos' and (select kut.is_active_member()));
