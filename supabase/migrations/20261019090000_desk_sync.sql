-- Desk sync (Phase 3 of docs/company-os-roadmap.md): the owner's Desk marks, his obligations and accounts, and the
-- Mac's last ledger reading, so the iPhone shows the same Desk and the server can remind while the Mac is off.
-- Rollback: docs/desk-sync.md. The obligation sweep and its schedule are in 20261019090100_obligation_sweep.sql.
--
-- What is here:
--   * desk_state: the owner's marks (Done, Snooze, Waiting on others, Dismiss): item ids, kinds, times, fact hashes and
--     dismiss reasons, as desk-state.json holds them. No titles. An item id of a section that names customers
--     (WorkTrack companies, website messages, licences) carries a hash instead of the source's own entry id.
--   * obligations / vendors: what the owner entered, as obligations.json holds it (his obligations, the dates he set,
--     Done with evidence, his accounts, the facts he recorded about accounts), plus the seed rows the app ships, so
--     the server knows their dates (entry = 'seed'; written by the app from code, never by hand).
--   * desk_ledger_reading / desk_items: the Mac's last reading of the ledgers (PRIORITIES.md and NEXT-ACTIONS lines:
--     title, product, file:line, severity), for the iPhone, which can't read them. Never a Daily Brief line.
--
-- What is never here: passwords, card numbers, keys or tokens (the app's forms never ask for them, and a row that
-- holds a key pattern is refused below), the titles of Daily Brief items. Free text the owner wrote (ledger lines,
-- dismiss reasons, his own titles, sources and evidence) is kept as written and can name people.
--
-- Sync rules (mirrored by DeskCloudMerge in LinumicCore):
--   * every row of desk_state, obligations and vendors has `version bigint`; a write names the version it was based on
--     and is refused when the row has moved on: push_* return the current row, so the app shows a conflict (both
--     sides) instead of overwriting either;
--   * rows are never deleted: undoing a mark or a Done writes a tombstone (deleted = true), as a new version;
--   * nothing is writable except through the push RPCs (security definer, admins only); the owner's tables are audited,
--     and audit_events keeps every version of their rows (after an undo, and after the rollback too).

-- MARK: Checks shared by the tables

-- A string holds something that reads as a key or token (the patterns of ContinuityBundle.forbiddenPatterns that
-- matter here). The app checks the same before it sends; this is the server's own refusal.
create or replace function private.desk_sync_has_secret(t text)
returns boolean language sql immutable set search_path = ''
as $$
  select t is not null and (
       t ~ '-----BEGIN [A-Z0-9 ]+-----'
    or t ~ 'LNM1\.[A-Za-z0-9_-]{20,}'
    or t ~ 'github_pat_[A-Za-z0-9_]{20,}'
    or t ~ 'gh[pousr]_[A-Za-z0-9]{30,}'
    or t ~ 'sk-ant-[A-Za-z0-9_-]{20,}'
    or t ~ 'sb_secret_[A-Za-z0-9_-]{10,}'
    or t ~ 'AIza[0-9A-Za-z_-]{35}'
    or t ~ 'AGE-SECRET-KEY-1[0-9A-Z]{50,}'
    or t ~ 'eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{16,}'
    or t ~ '[sr]k_live_[0-9A-Za-z]{16,}'
    or t ~ 'AKIA[0-9A-Z]{16}')
$$;

create or replace function private.nonblank(t text)
returns boolean language sql immutable set search_path = ''
as $$ select coalesce(length(btrim(t)) > 0, false) $$;

-- A real day written as the app writes a KeyDay, "YYYY-MM-DD". Not 'tomorrow', 'infinity', '2026-02-30' or a time:
-- every day the sweep reads passes this first, so one bad row can never stop it.
create or replace function private.is_iso_day(t text)
returns boolean language plpgsql immutable set search_path = ''
as $$
begin
  return coalesce(t ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' and to_char(t::date, 'YYYY-MM-DD') = t, false);
exception when data_exception then
  return false;
end $$;

-- The day `t` names, or null when it is not one (is_iso_day).
create or replace function private.iso_day(t text)
returns date language sql immutable set search_path = ''
as $$ select case when private.is_iso_day(t) then t::date end $$;

-- A cost as the account sheet accepts it: an amount above zero, a three-letter currency, a cycle and its bill.
create or replace function private.cost_ok(c jsonb)
returns boolean language sql immutable set search_path = ''
as $$
  select c is null or jsonb_typeof(c) = 'null' or (
    jsonb_typeof(c) = 'object' and jsonb_typeof(c->'amount') = 'number' and (c->>'amount')::numeric > 0
    and coalesce(c->>'currency', '') ~ '^[A-Z]{3}$' and c->>'cycle' in ('monthly', 'yearly', 'once')
    and private.nonblank(c->>'source'))
$$;

-- An obligation entry as the app writes it (ObligationsFile): a row of the owner's (or of the seed) with a title, a
-- source and the day it was recorded; a date with its source; a Done with its evidence.
create or replace function private.obligation_entry_ok(entry text, oid text, due date, d jsonb)
returns boolean language sql immutable set search_path = ''
as $$
  select case entry
    when 'row' then oid like 'owner.%' and d->>'id' = oid and d->>'origin' = 'owner'
                    and private.nonblank(d->>'title') and private.nonblank(d->>'source') and d ? 'recordedOn'
                    and (d->>'due' is null or private.is_iso_day(d->>'due'))
                    and (d->>'due') is not distinct from to_char(due, 'YYYY-MM-DD')
    when 'seed' then d->>'id' = oid and d->>'origin' = 'seed'
                    and private.nonblank(d->>'title') and private.nonblank(d->>'source') and d ? 'recordedOn'
                    and (d->>'due' is null or private.is_iso_day(d->>'due'))
                    and (d->>'due') is not distinct from to_char(due, 'YYYY-MM-DD')
    -- An account's renewal day is set on the account's card (vendors), never as a date here.
    when 'date' then d->>'obligationID' = oid and oid !~ '^account\..+\.renewal$'
                    and private.is_iso_day(d->>'due') and d->>'due' = to_char(due, 'YYYY-MM-DD')
                    and private.nonblank(d->>'source') and d ? 'enteredAt'
    when 'done' then d->>'obligationID' = oid and (d->>'due' is null or private.is_iso_day(d->>'due'))
                    and (d->>'due') is not distinct from to_char(due, 'YYYY-MM-DD')
                    and private.nonblank(d->>'evidence') and private.is_iso_day(d->>'on') and d ? 'enteredAt'
    else false end
$$;

-- An account entry as the app writes it: the owner's account or a seed account (a name, a source, the day recorded;
-- a holder or cost only with its source, a renewal only as a real day with its source), or the facts he recorded about
-- one account (every edit for it).
create or replace function private.vendor_entry_ok(entry text, aid text, d jsonb)
returns boolean language sql immutable set search_path = ''
as $$
  select case entry
    when 'account' then aid like 'owner.%' and d->>'id' = aid and d->>'origin' = 'owner'
                        and private.nonblank(d->>'name') and private.nonblank(d->>'source') and d ? 'recordedOn'
                        and (d->>'holder' is null or private.nonblank(d->>'holderSource'))
                        and (d->>'renewal' is null or (private.nonblank(d->>'renewalSource') and private.is_iso_day(d->>'renewal')))
                        and private.cost_ok(d->'cost')
    when 'seed' then d->>'id' = aid and d->>'origin' = 'seed' and private.nonblank(d->>'name')
                     and private.nonblank(d->>'source') and d ? 'recordedOn'
                     and (d->>'renewal' is null or (private.nonblank(d->>'renewalSource') and private.is_iso_day(d->>'renewal')))
    when 'facts' then jsonb_typeof(d->'edits') = 'array' and jsonb_array_length(d->'edits') between 1 and 500
                      and not exists (
                        select 1 from jsonb_array_elements(d->'edits') e
                        where jsonb_typeof(e) <> 'object' or e->>'accountID' is distinct from aid or not (e ? 'enteredAt')
                           or (e->>'renewal' is not null and not private.nonblank(e->>'renewalSource'))
                           or (e->>'renewal' is not null and not private.is_iso_day(e->>'renewal'))
                           or (e->>'holder' is not null and not private.nonblank(e->>'holderSource'))
                           or not private.cost_ok(e->'cost'))
    else false end
$$;

revoke execute on function private.desk_sync_has_secret(text), private.nonblank(text), private.is_iso_day(text),
  private.iso_day(text), private.cost_ok(jsonb), private.obligation_entry_ok(text, text, date, jsonb),
  private.vendor_entry_ok(text, text, jsonb)
  from public, anon, authenticated;

-- A value made anew each time this file is applied. desk_sync_pull answers it, so a device that remembers row versions
-- of an earlier set of these tables (applied, rolled back, applied again: versions start at 1 again) forgets them and
-- merges from nothing instead of reading a new version 5 as the version 5 it knew.
do $$
begin
  execute format('create or replace function private.desk_sync_epoch() returns text language sql immutable set search_path = '''' as %L',
                 'select ' || quote_literal(gen_random_uuid()::text));
end $$;
revoke execute on function private.desk_sync_epoch() from public, anon;
grant execute on function private.desk_sync_epoch() to authenticated;

-- MARK: Tables

create table public.desk_state (
  -- The Desk item id, "<origin>|<subject>|<kind>". In the sections that name customers the subject is "h-<hash>".
  id text primary key,
  kind text check (kind in ('done', 'snoozed', 'waiting', 'dismissed')),
  marked_at timestamptz,
  fact_hash text check (fact_hash ~ '^[0-9a-f]{16}$'),
  snoozed_until timestamptz,
  reason text check (reason is null or (length(btrim(reason)) between 1 and 500 and not private.desk_sync_has_secret(reason))),
  deleted boolean not null default false,
  version bigint not null default 1 check (version >= 1),
  written_on text not null check (written_on in ('macOS', 'iOS')),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  check (length(id) <= 300 and id ~ '^[a-z][A-Za-z0-9._-]*\|.+\|[A-Za-z0-9._-]+$' and id !~ '[[:cntrl:]]'),
  check (id !~ '^brief\.(worktrack|siteMessages|licences)\|'
         or id ~ '^brief\.(worktrack|siteMessages|licences)\|h-[0-9a-f]{16}\|[A-Za-z0-9._-]+$'),
  check (case when deleted
              then kind is null and marked_at is null and fact_hash is null and snoozed_until is null and reason is null
              else kind is not null and marked_at is not null and fact_hash is not null
                   and (snoozed_until is not null) = (kind = 'snoozed') and (reason is not null) = (kind = 'dismissed')
         end)
);

create table public.obligations (
  -- "<entry>:<obligation id>", and for a Done "|<the due day it closes, or ->".
  id text primary key check (length(id) <= 300),
  entry text not null check (entry in ('row', 'seed', 'date', 'done')),
  obligation_id text not null check (length(obligation_id) <= 200 and obligation_id ~ '^[A-Za-z0-9][A-Za-z0-9._:@-]*$'),
  -- row / seed: its due day (null: unknown); date: the day set; done: the due day it closes (null: an undated row).
  due date,
  data jsonb check (data is null or (jsonb_typeof(data) = 'object' and octet_length(data::text) <= 16384
                                     and not private.desk_sync_has_secret(data::text))),
  -- Seed rows only: ObligationSeed.revision of the app that wrote it; a newer revision replaces an older one.
  seed_revision int check (seed_revision is null or seed_revision >= 1),
  deleted boolean not null default false,
  version bigint not null default 1 check (version >= 1),
  written_on text not null check (written_on in ('macOS', 'iOS')),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  check (deleted = (data is null)),
  check ((entry = 'seed') = (seed_revision is not null)),
  check (entry <> 'done' or not deleted or due is not null or id like '%|-'),
  check (id = entry || ':' || obligation_id
              || case when entry = 'done' then '|' || coalesce(to_char(due, 'YYYY-MM-DD'), '-') else '' end),
  check (deleted or private.obligation_entry_ok(entry, obligation_id, due, data))
);
create index on public.obligations (obligation_id);

create table public.vendors (
  -- "<entry>:<account id>".
  id text primary key check (length(id) <= 300),
  entry text not null check (entry in ('account', 'seed', 'facts')),
  account_id text not null check (length(account_id) <= 200 and account_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]*$'),
  data jsonb check (data is null or (jsonb_typeof(data) = 'object' and octet_length(data::text) <= 65536
                                     and not private.desk_sync_has_secret(data::text))),
  seed_revision int check (seed_revision is null or seed_revision >= 1),
  deleted boolean not null default false,
  version bigint not null default 1 check (version >= 1),
  written_on text not null check (written_on in ('macOS', 'iOS')),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  check (deleted = (data is null)),
  check ((entry = 'seed') = (seed_revision is not null)),
  check (id = entry || ':' || account_id),
  check (deleted or private.vendor_entry_ok(entry, account_id, data))
);

-- The Mac's last reading of the ledgers: one header row (versioned) and its lines.
create table public.desk_ledger_reading (
  id int primary key default 1 check (id = 1),
  -- When the Mac read the files; never later than when the server received it (a Mac clock running ahead).
  read_at timestamptz not null,
  -- Per ledger: {id, path, state, open, ticked, today, thisWeek, skipped, day} as the Mac read it.
  sources jsonb not null check (jsonb_typeof(sources) = 'array' and jsonb_array_length(sources) <= 50
                                and not private.desk_sync_has_secret(sources::text)),
  -- The owner turned ledger lines off on the Mac: the reading is empty on purpose.
  lines_off boolean not null default false,
  -- SHA-256 (hex) of the lines as sent, so an unchanged reading only moves the time.
  digest text not null check (digest ~ '^[0-9a-f]{64}$'),
  item_count int not null check (item_count >= 0),
  version bigint not null default 1 check (version >= 1),
  written_on text not null check (written_on = 'macOS'),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);

create table public.desk_items (
  -- The Desk item id of a ledger or NEXT-ACTIONS line ("ledger.<id>|…" or "next-actions|…"); never a Brief line.
  id text primary key check (length(id) <= 300 and id ~ '^(ledger\.[a-z0-9-]+|next-actions)\|.+\|[A-Za-z0-9._-]+$'),
  title text not null check (length(title) between 1 and 2000 and not private.desk_sync_has_secret(title)),
  -- True when the Mac kept the line's text back (it held an address, a phone number or a key): the title then says so.
  title_withheld boolean not null default false,
  domain text not null check (length(domain) between 1 and 100),
  domain_name text not null check (length(domain_name) between 1 and 100),
  severity text not null check (severity in ('high', 'normal', 'info')),
  kind text not null check (kind in ('task', 'source')),
  kind_key text not null check (kind_key ~ '^[A-Za-z0-9._-]{1,60}$'),
  subject text not null check (length(subject) <= 300 and not private.desk_sync_has_secret(subject)),
  file text check (file is null or (file like '~/%' and length(file) <= 300)),
  line int check (line is null or line > 0),
  due date,
  horizon text check (horizon is null or horizon in ('today', 'thisWeek')),
  owner_action boolean not null default false,
  fact_hash text not null check (fact_hash ~ '^[0-9a-f]{16}$'),
  sort_order int not null
);

-- Every write bumps the version and the time, whoever makes it.
create or replace function private.desk_sync_bump()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.version := 1;
  else
    new.version := old.version + 1;
  end if;
  new.updated_at := now();
  return new;
end $$;
revoke execute on function private.desk_sync_bump() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['desk_state', 'obligations', 'vendors', 'desk_ledger_reading']
  loop
    execute format('create trigger %I before insert or update on public.%I for each row execute function private.desk_sync_bump()', t || '_bump', t);
  end loop;
  -- The owner's own entries are audited (who, when, before and after). The ledger reading is not: it is a copy of
  -- files the Mac reads every 30 minutes, and auditing it would copy every line into audit_events each time.
  foreach t in array array['desk_state', 'obligations', 'vendors']
  loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_trigger()', t || '_audit', t);
  end loop;
  -- Row-level security: admins read; nobody writes through the API (the push RPCs below are security definer and
  -- check private.is_admin()); the anon key reaches nothing.
  foreach t in array array['desk_state', 'obligations', 'vendors', 'desk_ledger_reading', 'desk_items']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "admins read %1$s" on public.%1$I for select to authenticated using ((select private.is_admin()))', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke insert, update, delete, truncate on public.%I from authenticated', t);
  end loop;
end $$;

-- MARK: Reading (admins)

-- One row in the shape the app syncs: {id, entry, version, deleted, data, seedRevision, writtenOn, updatedAt}.
create or replace function private.desk_mark_json(d public.desk_state)
returns jsonb language sql stable set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', d.id, 'entry', 'mark', 'version', d.version, 'deleted', d.deleted,
    'data', case when d.deleted then null else jsonb_strip_nulls(jsonb_build_object(
              'kind', d.kind, 'at', public.iso8601(d.marked_at), 'factHash', d.fact_hash,
              'until', public.iso8601(d.snoozed_until), 'reason', d.reason)) end,
    'writtenOn', d.written_on, 'updatedAt', public.iso8601(d.updated_at)))
$$;

create or replace function private.obligation_json(o public.obligations)
returns jsonb language sql stable set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', o.id, 'entry', o.entry, 'key', o.obligation_id, 'version', o.version, 'deleted', o.deleted, 'data', o.data,
    'seedRevision', o.seed_revision, 'writtenOn', o.written_on, 'updatedAt', public.iso8601(o.updated_at)))
$$;

create or replace function private.vendor_json(v public.vendors)
returns jsonb language sql stable set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', v.id, 'entry', v.entry, 'key', v.account_id, 'version', v.version, 'deleted', v.deleted, 'data', v.data,
    'seedRevision', v.seed_revision, 'writtenOn', v.written_on, 'updatedAt', public.iso8601(v.updated_at)))
$$;
revoke execute on function private.desk_mark_json(public.desk_state), private.obligation_json(public.obligations),
  private.vendor_json(public.vendors) from public, anon;
grant execute on function private.desk_mark_json(public.desk_state), private.obligation_json(public.obligations),
  private.vendor_json(public.vendors) to authenticated;

-- Everything the app syncs, in one call: {"serverTime", "epoch", "deskState": [...], "obligations": [...],
-- "vendors": [...], "ledger": {version, readAt, digest, linesOff, writtenOn, updatedAt, sources, items: [...]} | null}.
create or replace function public.desk_sync_pull()
returns jsonb language plpgsql stable security invoker set search_path = ''
as $$
begin
  perform public.assert_admin();
  return jsonb_build_object(
    'serverTime', public.iso8601(now()),
    'epoch', private.desk_sync_epoch(),
    'deskState', coalesce((select jsonb_agg(private.desk_mark_json(d) order by d.id) from public.desk_state d), '[]'::jsonb),
    'obligations', coalesce((select jsonb_agg(private.obligation_json(o) order by o.id) from public.obligations o), '[]'::jsonb),
    'vendors', coalesce((select jsonb_agg(private.vendor_json(v) order by v.id) from public.vendors v), '[]'::jsonb),
    'ledger', (select jsonb_build_object(
        'version', r.version, 'readAt', public.iso8601(r.read_at), 'digest', r.digest, 'itemCount', r.item_count,
        'linesOff', r.lines_off,
        'writtenOn', r.written_on, 'updatedAt', public.iso8601(r.updated_at), 'sources', r.sources,
        'items', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'id', i.id, 'title', i.title, 'titleWithheld', i.title_withheld, 'domain', i.domain,
            'domainName', i.domain_name, 'severity', i.severity, 'kind', i.kind, 'kindKey', i.kind_key,
            'subject', i.subject, 'file', i.file, 'line', i.line, 'due', to_char(i.due, 'YYYY-MM-DD'),
            'horizon', i.horizon, 'ownerAction', i.owner_action, 'factHash', i.fact_hash)) order by i.sort_order)
          from public.desk_items i), '[]'::jsonb))
      from public.desk_ledger_reading r where r.id = 1));
end $$;
revoke execute on function public.desk_sync_pull() from public, anon;
grant execute on function public.desk_sync_pull() to authenticated;

-- MARK: Writing (admins, one version at a time)

-- Each push takes {"changes": [{id, expectedVersion, data | null, …}], "device": "macOS" | "iOS"} and answers, per
-- change, {"id", "status": "applied" | "stale" | "invalid", "row": <the row as it is now> | null, "message"}:
--   * expectedVersion is the version the change is based on (0: a row the device has not seen on the server);
--   * stale: the row moved on (or was never there for a version > 0, or another device wrote it first at the same
--     moment); nothing was written, and "row" is what the server holds, so the app can show both sides;
--   * invalid: the row breaks a rule above (no source, no evidence, a key pattern, a bad id); nothing was written;
--   * data null writes a tombstone (deleted = true). A tombstone for a row that was never on the server writes nothing.

create or replace function public.push_desk_state(changes jsonb, device text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  c jsonb;
  cur public.desk_state%rowtype;
  expected bigint;
  d jsonb;
  out jsonb := '[]'::jsonb;
begin
  -- Not assert_admin(): inside a security-definer function current_user is the owner, which it would accept.
  if not coalesce(private.is_admin(), false) then
    raise exception 'Not authorised: Linumic OS admins only' using errcode = '42501';
  end if;
  if jsonb_typeof(changes) is distinct from 'array' or jsonb_array_length(changes) > 500 then
    raise exception 'changes must be a JSON array of at most 500 rows' using errcode = '22023';
  end if;
  if device is null or device not in ('macOS', 'iOS') then
    raise exception 'device must be macOS or iOS' using errcode = '22023';
  end if;
  for c in select * from jsonb_array_elements(changes) loop
    begin
      expected := coalesce((c->>'expectedVersion')::bigint, -1);
      d := case when jsonb_typeof(c->'data') = 'object' then c->'data' end;
      select * into cur from public.desk_state where id = c->>'id' for update;
      if not found then
        if expected <> 0 then
          out := out || jsonb_build_object('id', c->>'id', 'status', 'stale', 'row', null);
        elsif d is null then
          out := out || jsonb_build_object('id', c->>'id', 'status', 'applied', 'row', null);
        else
          -- Another device may write the same new row at the same moment: its row wins and this one is stale.
          insert into public.desk_state (id, kind, marked_at, fact_hash, snoozed_until, reason, deleted, written_on)
          values (c->>'id', d->>'kind', (d->>'at')::timestamptz, d->>'factHash', (d->>'until')::timestamptz,
                  d->>'reason', false, device)
          on conflict (id) do nothing
          returning * into cur;
          if found then
            out := out || jsonb_build_object('id', cur.id, 'status', 'applied', 'row', private.desk_mark_json(cur));
          else
            select * into cur from public.desk_state where id = c->>'id';
            out := out || jsonb_build_object('id', c->>'id', 'status', 'stale', 'row', private.desk_mark_json(cur));
          end if;
        end if;
      elsif cur.version <> expected then
        out := out || jsonb_build_object('id', cur.id, 'status', 'stale', 'row', private.desk_mark_json(cur));
      else
        update public.desk_state set
          kind = d->>'kind', marked_at = (d->>'at')::timestamptz, fact_hash = d->>'factHash',
          snoozed_until = (d->>'until')::timestamptz, reason = d->>'reason', deleted = d is null,
          written_on = device, updated_by = (select auth.uid())
        where id = cur.id
        returning * into cur;
        out := out || jsonb_build_object('id', cur.id, 'status', 'applied', 'row', private.desk_mark_json(cur));
      end if;
    exception when integrity_constraint_violation or data_exception then
      out := out || jsonb_build_object('id', c->>'id', 'status', 'invalid', 'row', null, 'message', sqlerrm);
    end;
  end loop;
  return out;
end $$;
revoke execute on function public.push_desk_state(jsonb, text) from public, anon;
grant execute on function public.push_desk_state(jsonb, text) to authenticated;

-- Changes: {id, entry, key, expectedVersion, data | null, seedRevision}. The due day is read from data (a tombstone
-- keeps the row's own).
create or replace function public.push_obligations(changes jsonb, device text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  c jsonb;
  cur public.obligations%rowtype;
  expected bigint;
  d jsonb;
  out jsonb := '[]'::jsonb;
begin
  if not coalesce(private.is_admin(), false) then
    raise exception 'Not authorised: Linumic OS admins only' using errcode = '42501';
  end if;
  if jsonb_typeof(changes) is distinct from 'array' or jsonb_array_length(changes) > 500 then
    raise exception 'changes must be a JSON array of at most 500 rows' using errcode = '22023';
  end if;
  if device is null or device not in ('macOS', 'iOS') then
    raise exception 'device must be macOS or iOS' using errcode = '22023';
  end if;
  for c in select * from jsonb_array_elements(changes) loop
    begin
      expected := coalesce((c->>'expectedVersion')::bigint, -1);
      d := case when jsonb_typeof(c->'data') = 'object' then c->'data' end;
      select * into cur from public.obligations where id = c->>'id' for update;
      if not found then
        if expected <> 0 then
          out := out || jsonb_build_object('id', c->>'id', 'status', 'stale', 'row', null);
        elsif d is null then
          out := out || jsonb_build_object('id', c->>'id', 'status', 'applied', 'row', null);
        else
          insert into public.obligations (id, entry, obligation_id, due, data, seed_revision, written_on)
          values (c->>'id', c->>'entry', c->>'key', (d->>'due')::date, d, (c->>'seedRevision')::int, device)
          on conflict (id) do nothing
          returning * into cur;
          if found then
            out := out || jsonb_build_object('id', cur.id, 'status', 'applied', 'row', private.obligation_json(cur));
          else
            select * into cur from public.obligations where id = c->>'id';
            out := out || jsonb_build_object('id', c->>'id', 'status', 'stale', 'row', private.obligation_json(cur));
          end if;
        end if;
      elsif cur.version <> expected then
        out := out || jsonb_build_object('id', cur.id, 'status', 'stale', 'row', private.obligation_json(cur));
      elsif c->>'entry' is distinct from cur.entry or c->>'key' is distinct from cur.obligation_id then
        raise exception 'the entry or key of % cannot change', cur.id using errcode = '23514';
      else
        update public.obligations set
          due = case when d is null then cur.due else (d->>'due')::date end, data = d, deleted = d is null,
          seed_revision = case when cur.entry = 'seed' then coalesce((c->>'seedRevision')::int, cur.seed_revision) end,
          written_on = device, updated_by = (select auth.uid())
        where id = cur.id
        returning * into cur;
        out := out || jsonb_build_object('id', cur.id, 'status', 'applied', 'row', private.obligation_json(cur));
      end if;
    exception when integrity_constraint_violation or data_exception then
      out := out || jsonb_build_object('id', c->>'id', 'status', 'invalid', 'row', null, 'message', sqlerrm);
    end;
  end loop;
  return out;
end $$;
revoke execute on function public.push_obligations(jsonb, text) from public, anon;
grant execute on function public.push_obligations(jsonb, text) to authenticated;

-- Changes: {id, entry, key, expectedVersion, data | null, seedRevision}.
create or replace function public.push_vendors(changes jsonb, device text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  c jsonb;
  cur public.vendors%rowtype;
  expected bigint;
  d jsonb;
  out jsonb := '[]'::jsonb;
begin
  if not coalesce(private.is_admin(), false) then
    raise exception 'Not authorised: Linumic OS admins only' using errcode = '42501';
  end if;
  if jsonb_typeof(changes) is distinct from 'array' or jsonb_array_length(changes) > 500 then
    raise exception 'changes must be a JSON array of at most 500 rows' using errcode = '22023';
  end if;
  if device is null or device not in ('macOS', 'iOS') then
    raise exception 'device must be macOS or iOS' using errcode = '22023';
  end if;
  for c in select * from jsonb_array_elements(changes) loop
    begin
      expected := coalesce((c->>'expectedVersion')::bigint, -1);
      d := case when jsonb_typeof(c->'data') = 'object' then c->'data' end;
      select * into cur from public.vendors where id = c->>'id' for update;
      if not found then
        if expected <> 0 then
          out := out || jsonb_build_object('id', c->>'id', 'status', 'stale', 'row', null);
        elsif d is null then
          out := out || jsonb_build_object('id', c->>'id', 'status', 'applied', 'row', null);
        else
          insert into public.vendors (id, entry, account_id, data, seed_revision, written_on)
          values (c->>'id', c->>'entry', c->>'key', d, (c->>'seedRevision')::int, device)
          on conflict (id) do nothing
          returning * into cur;
          if found then
            out := out || jsonb_build_object('id', cur.id, 'status', 'applied', 'row', private.vendor_json(cur));
          else
            select * into cur from public.vendors where id = c->>'id';
            out := out || jsonb_build_object('id', c->>'id', 'status', 'stale', 'row', private.vendor_json(cur));
          end if;
        end if;
      elsif cur.version <> expected then
        out := out || jsonb_build_object('id', cur.id, 'status', 'stale', 'row', private.vendor_json(cur));
      elsif c->>'entry' is distinct from cur.entry or c->>'key' is distinct from cur.account_id then
        raise exception 'the entry or key of % cannot change', cur.id using errcode = '23514';
      else
        update public.vendors set
          data = d, deleted = d is null,
          seed_revision = case when cur.entry = 'seed' then coalesce((c->>'seedRevision')::int, cur.seed_revision) end,
          written_on = device, updated_by = (select auth.uid())
        where id = cur.id
        returning * into cur;
        out := out || jsonb_build_object('id', cur.id, 'status', 'applied', 'row', private.vendor_json(cur));
      end if;
    exception when integrity_constraint_violation or data_exception then
      out := out || jsonb_build_object('id', c->>'id', 'status', 'invalid', 'row', null, 'message', sqlerrm);
    end;
  end loop;
  return out;
end $$;
revoke execute on function public.push_vendors(jsonb, text) from public, anon;
grant execute on function public.push_vendors(jsonb, text) to authenticated;

-- The Mac's ledger reading: {readAt, digest, linesOff, sources: [...], items: [...]}, replacing the one of
-- `expected_version` (0 when there is none yet). Answers {"status": "applied" | "unchanged" | "stale" | "invalid",
-- "version", "readAt", "message"}. The version orders the writes (one Mac), not the Mac's clock: a reading is never
-- refused for its time, and a time ahead of the server's is stored as the server's, so one reading from a Mac whose
-- clock ran ahead never holds back the next ones. A reading whose lines are unchanged (same digest) only moves the
-- time and the per-ledger counts ("unchanged").
create or replace function public.replace_desk_items(expected_version bigint, reading jsonb)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  cur public.desk_ledger_reading%rowtype;
  incoming timestamptz;
  n int;
begin
  if not coalesce(private.is_admin(), false) then
    raise exception 'Not authorised: Linumic OS admins only' using errcode = '42501';
  end if;
  begin
    incoming := least((reading->>'readAt')::timestamptz, now());
    if incoming is null or jsonb_typeof(reading->'items') is distinct from 'array' or jsonb_array_length(reading->'items') > 2000 then
      raise exception 'reading needs readAt and at most 2000 items' using errcode = '22023';
    end if;
    n := jsonb_array_length(reading->'items');
    select * into cur from public.desk_ledger_reading where id = 1 for update;
    if found and cur.version <> expected_version or not found and expected_version <> 0 then
      return jsonb_build_object('status', 'stale', 'version', coalesce(cur.version, 0), 'readAt', public.iso8601(cur.read_at));
    end if;
    if found and cur.digest = reading->>'digest' and cur.item_count = n then
      update public.desk_ledger_reading set read_at = incoming, sources = reading->'sources',
                                            lines_off = coalesce((reading->>'linesOff')::boolean, false), written_on = 'macOS',
                                            updated_by = (select auth.uid())
      where id = 1 returning * into cur;
      return jsonb_build_object('status', 'unchanged', 'version', cur.version, 'readAt', public.iso8601(cur.read_at));
    end if;
    insert into public.desk_ledger_reading as r (id, read_at, sources, lines_off, digest, item_count, written_on)
    values (1, incoming, reading->'sources', coalesce((reading->>'linesOff')::boolean, false), reading->>'digest', n, 'macOS')
    on conflict (id) do update set read_at = excluded.read_at, sources = excluded.sources, lines_off = excluded.lines_off,
                                   digest = excluded.digest, item_count = excluded.item_count, written_on = 'macOS',
                                   updated_by = (select auth.uid())
    returning * into cur;
    delete from public.desk_items where true;
    insert into public.desk_items (id, title, title_withheld, domain, domain_name, severity, kind, kind_key, subject, file,
                                   line, due, horizon, owner_action, fact_hash, sort_order)
    select x->>'id', x->>'title', coalesce((x->>'titleWithheld')::boolean, false), x->>'domain', x->>'domainName',
           x->>'severity', x->>'kind', x->>'kindKey', coalesce(x->>'subject', ''), x->>'file', (x->>'line')::int,
           (x->>'due')::date, x->>'horizon', coalesce((x->>'ownerAction')::boolean, false), x->>'factHash', i::int
    from jsonb_array_elements(reading->'items') with ordinality as t(x, i);
    return jsonb_build_object('status', 'applied', 'version', cur.version, 'readAt', public.iso8601(cur.read_at));
  exception when integrity_constraint_violation or data_exception then
    return jsonb_build_object('status', 'invalid', 'message', sqlerrm);
  end;
end $$;
revoke execute on function public.replace_desk_items(bigint, jsonb) from public, anon;
grant execute on function public.replace_desk_items(bigint, jsonb) to authenticated;
