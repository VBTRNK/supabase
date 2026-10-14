-- ADR-162 / #264: Safe Hands is an ordinary kudos category with one session winner.
-- Only surveys opened by the new trigger gain the fourth slot. Existing ballots,
-- results, rewards and rating history are untouched; no historical backfill.
-- Ship the tolerant frontend first. Hosted application is catalogue-only.

insert into kut.kudos_categories(id,slug,title,description) values
('10000000-0000-4000-8000-000000000008','safe-hands','Safe Hands','Who impressed you most in goal?');

alter table kut.session_surveys drop constraint session_surveys_category_ids_check;
alter table kut.session_surveys drop constraint session_surveys_rules_version_check;
alter table kut.session_surveys add constraint session_surveys_ballot_version_check check (
  (rules_version=2 and cardinality(category_ids)=3 and not ('10000000-0000-4000-8000-000000000008'::uuid=any(category_ids)))
  or (rules_version=3 and cardinality(category_ids)=4
      and category_ids[4]='10000000-0000-4000-8000-000000000008'::uuid
      and not ('10000000-0000-4000-8000-000000000008'::uuid=any(category_ids[1:3])))
);
-- Keep default 2 for existing three-slot callers; the opening trigger writes 3.

do $$ declare v_constraint text; begin
  select conname into strict v_constraint from pg_constraint
  where conrelid='kut.session_kudos'::regclass and contype='u'
    and pg_get_constraintdef(oid)='UNIQUE (session_id, nominator_player_id, recipient_player_id)';
  execute format('alter table kut.session_kudos drop constraint %I',v_constraint);
end $$;
create unique index session_kudos_regular_nominee_unique
on kut.session_kudos(session_id,nominator_player_id,recipient_player_id)
where category_id<>'10000000-0000-4000-8000-000000000008'::uuid;

create or replace function kut._open_session_survey()
returns trigger language plpgsql security definer set search_path=kut,pg_catalog as $$
declare v_categories uuid[]; v_seed uuid := gen_random_uuid();
begin
  if new.status='published' and new.rating_rules_version=2 and (old.status is distinct from 'published') then
    select array_agg(id order by usage_count, tie_break) into v_categories from (
      select category.id,
        (select count(*) from kut.session_surveys survey where category.id=any(survey.category_ids)
          and exists(select 1 from kut.match_sessions prior where prior.id=survey.session_id and prior.season_id=new.season_id)) as usage_count,
        md5(v_seed::text || category.id::text) as tie_break
      from kut.kudos_categories category where category.id<>'10000000-0000-4000-8000-000000000008'::uuid order by usage_count, tie_break limit 3
    ) picked;
    insert into kut.session_surveys(session_id,opened_at,closes_at,category_ids,selection_seed,rules_version)
    values(new.id,new.published_at,new.published_at+interval '24 hours',array_append(v_categories,'10000000-0000-4000-8000-000000000008'::uuid),v_seed,3)
    on conflict(session_id) do nothing;
    insert into kut.session_survey_eligibility(session_id,player_id,user_id)
    select new.id,a.player_id,p.id from kut.attendance a
    left join kut.profiles p on p.player_id=a.player_id and not p.is_disabled
    where a.session_id=new.id on conflict do nothing;
    insert into kut.user_notifications(user_id,event_type,title,body,reference_type,reference_id)
    select e.user_id,'session_report',
      case when kut._uses_combined_count(new.session_date) then 'Goals + Assists & kudos' else 'Goals & kudos' end,'Your session report is open for 24 hours. Complete it to receive 50 KUT Coins.','match_session',new.id
    from kut.session_survey_eligibility e where e.session_id=new.id and e.user_id is not null
    on conflict(user_id,event_type,reference_type,reference_id) where reference_type is not null and reference_id is not null do nothing;
  elsif new.status='cancelled' then
    update kut.session_surveys set status='cancelled', finalized_at=null where session_id=new.id;
  end if;
  return new;
end $$;

create or replace function kut.submit_session_report(
  p_session_id uuid, p_goals integer, p_nominations jsonb,
  p_expected_revision integer, p_idempotency_key uuid, p_intent text default 'submit'
) returns jsonb language plpgsql security definer set search_path=kut,pg_catalog as $$
declare
  v_user uuid:=auth.uid(); v_player uuid; v_survey record; v_report record; v_cat uuid;
  v_recipient uuid; v_skips uuid[]:='{}'; v_result jsonb; v_ledger uuid:=gen_random_uuid();
  v_rewarded boolean:=false; v_revision integer; v_present integer; v_distinct integer; v_intent text;
begin
  if v_user is null then raise exception 'authentication required' using errcode='42501'; end if;
  if p_idempotency_key is null or p_intent not in ('draft','submit') or p_expected_revision < 0
    or (p_goals is not null and (p_goals<0 or p_goals>99)) or jsonb_typeof(coalesce(p_nominations,'{}'))<>'object'
    then raise exception 'invalid report input' using errcode='22023'; end if;
  select result into v_result from kut.session_report_requests where user_id=v_user and idempotency_key=p_idempotency_key;
  if found then return v_result; end if;
  select * into v_survey from kut.session_surveys where session_id=p_session_id for update;
  if not found then raise exception 'session survey not found' using errcode='P0002'; end if;
  if v_survey.status<>'open' or now()>=v_survey.closes_at then raise exception 'reports are closed' using errcode='P0001'; end if;
  select profile.player_id into v_player from kut.profiles profile join kut.attendance a on a.player_id=profile.player_id and a.session_id=p_session_id where profile.id=v_user and not profile.is_disabled;
  if v_player is null then raise exception 'linked attendee not found' using errcode='42501'; end if;
  insert into kut.session_survey_eligibility(session_id,player_id,user_id) values(p_session_id,v_player,v_user)
  on conflict(session_id,player_id) do update set user_id=excluded.user_id where session_survey_eligibility.user_id is null;
  select * into v_report from kut.session_reports where session_id=p_session_id and player_id=v_player for update;
  v_revision:=case when found then v_report.revision else 0 end;
  -- KB-020 / ADR-078: a submitted report never goes back to draft. The
  -- promotion happens here, above the validation below, so an edit to a
  -- submitted report is held to the same completeness rules that earned it
  -- rather than being rewritten under the weaker draft rules.
  v_intent:=case when v_report.status='submitted' then 'submit' else p_intent end;
  if v_revision<>p_expected_revision then
    return jsonb_build_object('conflict',true,'revision',v_revision,'rewarded',exists(select 1 from kut.session_report_rewards where session_id=p_session_id and player_id=v_player));
  end if;
  if exists(select 1 from jsonb_object_keys(coalesce(p_nominations,'{}')) key where not (key=any(v_survey.category_ids::text[]))) then
    raise exception 'the report categories changed' using errcode='22023';
  end if;
  for v_cat in select unnest(v_survey.category_ids) loop
    if p_nominations ? v_cat::text then
      if jsonb_typeof(p_nominations->v_cat::text)='null' then v_skips:=array_append(v_skips,v_cat);
      elsif jsonb_typeof(p_nominations->v_cat::text)='string' then
        begin v_recipient:=(p_nominations->>v_cat::text)::uuid; exception when invalid_text_representation then raise exception 'invalid nominee' using errcode='22023'; end;
        if v_recipient=v_player or not exists(select 1 from kut.attendance where session_id=p_session_id and player_id=v_recipient) then raise exception 'nominee must be another attendee' using errcode='22023'; end if;
      else raise exception 'invalid nominee' using errcode='22023'; end if;
    elsif v_intent='submit' then raise exception 'every category needs a nominee or Skip' using errcode='22023'; end if;
  end loop;
  select count(*),count(distinct value) into v_present,v_distinct from jsonb_each_text(p_nominations) where value is not null and key<>'10000000-0000-4000-8000-000000000008';
  if v_present<>v_distinct then raise exception 'each teammate can be nominated only once' using errcode='22023'; end if;
  if v_intent='submit' and p_goals is null then raise exception 'goals must be explicitly reported' using errcode='22023'; end if;
  insert into kut.session_reports(session_id,player_id,submitted_by,goals,status,explicit_skips,submitted_at,revision)
  values(p_session_id,v_player,v_user,p_goals,v_intent, v_skips,case when v_intent='submit' then now() end,v_revision+1)
  on conflict(session_id,player_id) do update set goals=excluded.goals,status=excluded.status,explicit_skips=excluded.explicit_skips,submitted_at=case when excluded.status='submitted' then coalesce(session_reports.submitted_at,now()) end,updated_at=now(),revision=session_reports.revision+1;
  delete from kut.session_kudos where session_id=p_session_id and nominator_player_id=v_player;
  for v_cat in select unnest(v_survey.category_ids) loop
    if p_nominations ? v_cat::text and jsonb_typeof(p_nominations->v_cat::text)='string' then
      insert into kut.session_kudos(session_id,nominator_player_id,category_id,recipient_player_id)
      values(p_session_id,v_player,v_cat,(p_nominations->>v_cat::text)::uuid);
    end if;
  end loop;
  if v_intent='submit' then
    insert into kut.session_report_rewards(session_id,player_id,user_id,amount,ledger_id)
    values(p_session_id,v_player,v_user,v_survey.reward_amount,v_ledger) on conflict do nothing;
    if found then
      v_rewarded:=true;
      insert into kut.wallets(user_id,balance) values(v_user,0) on conflict do nothing;
      insert into kut.wallet_ledger(id,user_id,amount,reason,reference_type,reference_id,idempotency_key)
      values(v_ledger,v_user,v_survey.reward_amount,'session_report_reward','match_session',p_session_id,'report:'||p_session_id::text||':'||v_player::text);
      update kut.wallets set balance=balance+v_survey.reward_amount,updated_at=now() where user_id=v_user;
    end if;
  end if;
  v_result:=jsonb_build_object('conflict',false,'revision',v_revision+1,'status',v_intent,'rewarded',v_rewarded,'reward_already_received',exists(select 1 from kut.session_report_rewards where session_id=p_session_id and player_id=v_player));
  insert into kut.session_report_requests(user_id,idempotency_key,session_id,result) values(v_user,p_idempotency_key,p_session_id,v_result);
  return v_result;
end $$;

create or replace function kut._finalize_one_session(p_session_id uuid)
returns void language plpgsql security definer set search_path=kut,pg_catalog as $$
declare v_survey record; v_player uuid; v_goals integer; v_qualified uuid[]; v_turnout integer; v_goal_form numeric; v_kudos_form numeric; v_season uuid; v_pre_ovr jsonb; v_session_date date; v_combined boolean; v_safe_hands_winner uuid;
begin
  select * into v_survey from kut.session_surveys where session_id=p_session_id for update;
  if not found or v_survey.status='cancelled' then return; end if;
  select count(distinct r.player_id) into v_turnout from kut.session_reports r
  where r.session_id=p_session_id and r.status='submitted' and exists(select 1 from kut.session_kudos k where k.session_id=r.session_id and k.nominator_player_id=r.player_id);
  -- The ballot snapshot is the cutover: never infer an award for an old survey.
  if v_turnout>=3 and '10000000-0000-4000-8000-000000000008'::uuid=any(v_survey.category_ids) then
    with votes as (
      select k.recipient_player_id,count(distinct k.nominator_player_id) as nominations
      from kut.session_kudos k
      join kut.session_reports r on r.session_id=k.session_id and r.player_id=k.nominator_player_id and r.status='submitted'
      where k.session_id=p_session_id and k.category_id='10000000-0000-4000-8000-000000000008'::uuid
      group by k.recipient_player_id
    ), leaders as (
      select recipient_player_id from votes where nominations>=2 and nominations=(select max(nominations) from votes)
    )
    select (array_agg(recipient_player_id))[1] into v_safe_hands_winner from leaders having count(*)=1;
  end if;
  delete from kut.session_report_results where session_id=p_session_id;
  for v_player in select player_id from kut.attendance where session_id=p_session_id loop
    select case when o.session_id is not null then o.goals else r.goals end into v_goals
    from (select 1) anchor left join kut.session_reports r on r.session_id=p_session_id and r.player_id=v_player and r.status='submitted'
    left join kut.session_goal_overrides o on o.session_id=p_session_id and o.player_id=v_player;
    if v_turnout>=3 then
      select coalesce(array_agg(category_id order by category_id),'{}') into v_qualified from (
        select category_id from kut.session_kudos where session_id=p_session_id and recipient_player_id=v_player
          and (category_id<>'10000000-0000-4000-8000-000000000008'::uuid or v_player=v_safe_hands_winner)
        group by category_id having count(distinct nominator_player_id)>=2
      ) q;
    else v_qualified:='{}'; end if;
    v_goal_form:=case when coalesce(v_goals,0)=0 then 0 when v_goals=1 then 1 when v_goals=2 then 1.25 else 1.5 end;
    v_kudos_form:=case cardinality(v_qualified) when 0 then 0 when 1 then 1 when 2 then 1.5 else 2 end;
    insert into kut.session_report_results(session_id,player_id,effective_goals,goal_form,kudos_form,session_input,qualified_category_ids)
    values(p_session_id,v_player,v_goals,v_goal_form,v_kudos_form,least(3.5,v_goal_form+v_kudos_form),v_qualified);
  end loop;
  update kut.session_surveys set status='finalized',finalized_at=now(),revision=revision+1 where session_id=p_session_id;
  -- ADR-101: the session date (read with the season) picks the notices' wording.
  select season_id,session_date into v_season,v_session_date from kut.match_sessions where id=p_session_id;
  v_combined:=kut._uses_combined_count(v_session_date);
  select coalesce(jsonb_object_agg(player_id::text,live_ovr),'{}'::jsonb) into v_pre_ovr
  from kut.player_season_state where season_id=v_season;
  perform kut._rebuild_season_core(v_season);
  insert into kut.user_notifications(user_id,event_type,title,body,reference_type,reference_id)
  select e.user_id,'session_results','Session report ready',
    case when v_combined then 'Reported G+A and recognized kudos are now in the Chronicle.'
         else 'Reported goals and recognized kudos are now in the Chronicle.' end,'match_session',p_session_id
  from kut.session_survey_eligibility e where e.session_id=p_session_id and e.user_id is not null
  on conflict(user_id,event_type,reference_type,reference_id) where reference_type is not null and reference_id is not null do nothing;
  insert into kut.user_notifications(user_id,event_type,title,body,reference_type,reference_id)
  select e.user_id,'kudos_awarded','Kudos awarded',
    'Teammates recognized you for ' || kut._join_names(named.titles) || ' this session.'
    || case when moved.delta > 0 then
         format(' %s lifted your card rating +%s OVR this week.',
           case when coalesce(rr.effective_goals,0) > 0
                then format('Your %s and these kudos',
                     case when v_combined then rr.effective_goals||' G+A'
                          when rr.effective_goals=1 then '1 goal' else rr.effective_goals||' goals' end)
                else 'These kudos' end,
           moved.delta)
       else '' end,
    'match_session',p_session_id
  from kut.session_report_results rr
  join kut.session_survey_eligibility e on e.session_id=rr.session_id and e.player_id=rr.player_id and e.user_id is not null
  join kut.player_season_state post on post.player_id=rr.player_id and post.season_id=v_season
  cross join lateral (
    -- Ballot order, so the notice lists the categories the way the member saw them.
    select array_agg(c.title order by array_position(v_survey.category_ids,c.id)) as titles
    from kut.kudos_categories c where c.id = any(rr.qualified_category_ids)
  ) named
  cross join lateral (
    select post.live_ovr - coalesce((v_pre_ovr->>rr.player_id::text)::integer, post.live_ovr) as delta
  ) moved
  where rr.session_id=p_session_id and cardinality(rr.qualified_category_ids)>0
  on conflict(user_id,event_type,reference_type,reference_id) where reference_type is not null and reference_id is not null do nothing;
end $$;

revoke all on function kut.submit_session_report(uuid,integer,jsonb,integer,uuid,text) from public,anon;
grant execute on function kut.submit_session_report(uuid,integer,jsonb,integer,uuid,text) to authenticated,service_role;
revoke execute on function kut._finalize_one_session(uuid) from public,anon,authenticated;
