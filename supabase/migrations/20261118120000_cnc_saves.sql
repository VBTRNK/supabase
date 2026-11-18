-- Crime & Crown: cloud saves by code (VBTRNK/cnc docs/design.md, "Cloud saves";
-- ADR-009). Catalogued in VBTRNK/supabase; this file and the catalogue's copy
-- are byte-identical.
--
-- No accounts: a player keeps a run in the cloud under a random code (16
-- Crockford base32 characters, 80 bits) and enters it on another device. The
-- code is the key, so the database stores only its SHA-256. Nothing touches
-- auth, and nobody reads or writes the table directly: the browser (role
-- `anon`, publishable key) calls two functions.
--
-- cnc.put_save accepts a save only while the revision it descends from is
-- still current, and advances the revision in the same statement. A first save
-- never overwrites an existing one. A retry of an accepted upload (same id,
-- same base, same save) is answered as saved; an upload id reused for anything
-- else is refused. The database sets the revision and the time.
--
-- Revisions come from one sequence, so no number is ever used twice, not even
-- by a save created again under a code whose save was deleted: a base a device
-- holds matches only the save it came from. Pruning deletes rows and never
-- resets the sequence (no truncate ... restart identity, no setval).
--
-- Open writes are bounded so they can't fill the database other tools share
-- (provisional): a save is at most 64 KiB, at most 60 new codes are admitted an
-- hour and 2000 in all. Every save is created on one path, serialized under a
-- lock after the caps, so they hold under concurrent calls and while rows are
-- deleted. Both caps count the saves still stored: deleting a save less than an
-- hour old frees hourly room too, so pruning deletes only saves created more
-- than an hour ago. At 2000 codes the saves total at most 125 MiB of JSON before
-- storage overhead. When a cap is reached, new codes are refused with hint
-- `busy` and existing codes keep working; the owner can raise the caps or
-- delete stale rows (by updated_at) in a later migration. The size check runs
-- after the request is parsed, so request volume itself is bounded only by the
-- project's API gateway (ADR-009).
--
-- Every refusal raises SQLSTATE 22023 (HTTP 400 through PostgREST).
--
-- Hosted steps outside this migration (the owner): add `cnc` to the Data API's
-- exposed schemas.
--
-- Rollback (nothing else depends on this schema):
--   drop schema cnc cascade;

create schema if not exists cnc;
revoke all on schema cnc from public;
grant usage on schema cnc to anon;

create sequence cnc.revisions as bigint;
revoke all on sequence cnc.revisions from public, anon, authenticated;

create table cnc.saves (
  code_hash bytea primary key check (octet_length(code_hash) = 32),
  revision bigint not null check (revision >= 1),
  -- The revision the latest upload descended from; null when it created the save.
  upload_base bigint,
  format_version integer not null check (format_version >= 1),
  upload_id uuid not null,
  save jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index saves_created_idx on cnc.saves (created_at);

-- Row-level security with no policy: no client role sees or changes a row.
alter table cnc.saves enable row level security;
revoke all on table cnc.saves from public, anon, authenticated;

-- The hash of a well-formed code; refuses anything else.
create function cnc.code_hash(p_code text)
returns bytea
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_code is null or p_code !~ '^[0-9A-HJKMNP-TV-Z]{16}$' then
    raise exception 'not a cloud code' using errcode = '22023';
  end if;
  return pg_catalog.sha256(pg_catalog.convert_to(p_code, 'UTF8'));
end;
$$;

-- Returns {"revision", "upload_id", "save", "format_version", "updated_at"},
-- or null when no save has this code.
create function cnc.get_save(p_code text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'revision', s.revision,
    'upload_id', s.upload_id,
    'save', s.save,
    'format_version', s.format_version,
    'updated_at', s.updated_at)
  from cnc.saves as s
  where s.code_hash = cnc.code_hash(p_code)
$$;

-- Returns {"outcome": "saved" | "conflict", "revision": n, "updated_at": t}.
-- On a conflict, revision is the current one (null when there is no save yet).
create function cnc.put_save(p_code text, p_base bigint, p_upload uuid, p_save jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  key bytea := cnc.code_hash(p_code);
  cur cnc.saves%rowtype;
begin
  if p_upload is null
     or jsonb_typeof(p_save) is distinct from 'object'
     or p_save ->> 'format' is distinct from 'crime-and-crown-save'
     or jsonb_typeof(p_save -> 'version') is distinct from 'number'
     or (p_save ->> 'version') !~ '^[1-9][0-9]{0,8}$'
     or jsonb_typeof(p_save -> 'state') is distinct from 'object' then
    raise exception 'not a Crime & Crown save' using errcode = '22023';
  end if;
  if octet_length(p_save::text) > 65536 then
    raise exception 'save too big' using errcode = '22023';
  end if;

  if p_base is null then
    -- A first save never touches an existing save; it is answered from it below.
    select * into cur from cnc.saves as s where s.code_hash = key;
    if not found then
      -- Every save is created here, under one lock and after the caps: concurrent calls
      -- can't pass them together, and a save deleted meanwhile can't open a way around them.
      perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cnc.saves admission', 0));
      select * into cur from cnc.saves as s where s.code_hash = key;
      if not found then
        if (select count(*) from cnc.saves as s where s.created_at > now() - interval '1 hour') >= 60
           or (select count(*) from cnc.saves) >= 2000 then
          raise exception 'too many new cloud saves' using errcode = '22023', hint = 'busy';
        end if;
        insert into cnc.saves (code_hash, revision, format_version, upload_id, save)
        values (key, pg_catalog.nextval('cnc.revisions'), (p_save ->> 'version')::integer, p_upload, p_save)
        returning * into cur;
        return pg_catalog.jsonb_build_object('outcome', 'saved', 'revision', cur.revision, 'updated_at', cur.updated_at);
      end if;
    end if;
  else
    update cnc.saves as s
    set revision = pg_catalog.nextval('cnc.revisions'),
        upload_base = s.revision,
        format_version = (p_save ->> 'version')::integer,
        upload_id = p_upload,
        save = p_save,
        updated_at = now()
    where s.code_hash = key and s.revision = p_base and s.upload_id is distinct from p_upload
    returning * into cur;
    if found then
      return pg_catalog.jsonb_build_object('outcome', 'saved', 'revision', cur.revision, 'updated_at', cur.updated_at);
    end if;
    select * into cur from cnc.saves as s where s.code_hash = key;
  end if;

  -- Nothing was written. cur is the save under the code, if any.
  if cur.upload_id is distinct from p_upload then
    return pg_catalog.jsonb_build_object('outcome', 'conflict', 'revision', cur.revision, 'updated_at', cur.updated_at);
  end if;
  -- The latest accepted upload has this id: a retry whose reply was lost, unless
  -- the id was reused for another save or another base.
  if cur.save is distinct from p_save or cur.upload_base is distinct from p_base then
    raise exception 'upload id reused for another save' using errcode = '22023';
  end if;
  return pg_catalog.jsonb_build_object('outcome', 'saved', 'revision', cur.revision, 'updated_at', cur.updated_at);
end;
$$;

revoke all on function cnc.code_hash(text) from public, anon, authenticated;
revoke all on function cnc.get_save(text) from public, anon, authenticated;
revoke all on function cnc.put_save(text, bigint, uuid, jsonb) from public, anon, authenticated;
grant execute on function cnc.get_save(text) to anon;
grant execute on function cnc.put_save(text, bigint, uuid, jsonb) to anon;
