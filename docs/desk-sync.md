# Desk sync (همگام‌سازی میز کار)

Phase 3 of [company-os-roadmap.md](company-os-roadmap.md): the Desk and the obligations on every device, and reminders
while the Mac is off.

**Status, 2026-10-20:** built on the branch `feat/desk-sync`, tested on a scratch Postgres and in LinumicCore; the
second review's fixes are in (see "Second review" below).
**Not applied** to the live Supabase project (`mczuclgfqxffcbiwvecf`): the two migrations wait for the owner's
approval (steps below). Until they are applied the app says "not deployed yet" and the Desk works as before, on each
device alone.

## What it does

- **The same Desk on the iPhone.** The owner's marks (Done, Snooze, Waiting on others, Dismiss with its reason), his
  obligations and accounts (what he added, the dates he set, Done with evidence, the facts recorded on an account's
  card) sync between his devices. Done on the Mac is seen on the iPhone.
- **The Mac's ledgers on the iPhone, dated.** The iPhone can't read the PRIORITIES.md files and NEXT-ACTIONS. The Mac
  sends its last reading (each line's title, product, file:line and severity); the iPhone shows those lines with the
  Mac's read time, a "The Mac's reading" badge, and "Stale" plus a sentence once the reading is older than an hour.
- **Two devices, never last-writer-wins.** A row both devices changed differently is a conflict: each device keeps its
  own version, the server keeps the one written first, and the Desk shows both ("Changed on two devices") until the
  owner keeps one. Nothing is written over and nothing is deleted.
- **Reminders while the Mac is off.** A daily job of its own at 06:16 UTC (a minute after the Sentinel's licence sweep,
  which is left exactly as it is) sweeps the synced obligations and writes one event per obligation and lead window
  (30, 14, 7, 1 days, and on the day), keyed `obligation:<id>:<due>:<lead>`, the same key as the app's own
  notification, so a re-run never writes it twice and a device that already alerted does not alert again.

## What goes to the cloud, and what never does

| Table | Holds | Never |
|---|---|---|
| `desk_state` | per Desk item: its id, the mark's kind and time, the fact hash, a snooze's end, a dismissal's reason | titles, details, or a customer's entry id: in the Brief sections that name customers (WorkTrack companies, website messages, licences) the id's subject is a hash (`h-…`), and the server refuses one in clear |
| `obligations` | the owner's rows, dates (with source), Done (with evidence), as `obligations.json` holds them; the seed rows the app ships (id, title, product, day, lead days; their sources stay in the app) | a row without its source or evidence, a day that is not a real `YYYY-MM-DD` day, a date on an account's renewal row (that day is set on the account's card), the seed's `domain.linumic.com` (the Monitor's reading replaces it), a row that reads as a key |
| `vendors` | the owner's accounts and, per account, the facts recorded on its card (renewal, holder, cost, each with its source); the seed accounts' names | passwords, logins, card numbers (the forms never ask for them), a renewal that is not a real day, a row that reads as a key |
| `desk_ledger_reading`, `desk_items` | the Mac's last reading: per ledger its state and counts; per line its id, title, product, file:line, severity, due day, fact hash; whether the owner turned ledger lines off | the lines under a line, its detail; the text of a line that holds an email address, a phone number in `+…`, `(…)` or `0…` form, or a key (sent as "(withheld)"); any Daily Brief line; a line or a ledger list that reads as a key (refused) |

Before anything is sent the app checks every row against the key and token patterns of the continuity export
(`ContinuityBundle.forbiddenPatterns`); a match is not sent and is listed in Settings → Account as not accepted. The
server checks the same patterns again. Ledger lines can name people: the withholding catches addresses, numbers and
keys, not names. Dismiss reasons and the owner's own titles, sources and evidence are free text and are stored as he
wrote them, except on Sales items, whose dismiss reason is one of five fixed tokens (`sales.reason.*`, docs/sales.md):
the app refuses any other and sends anything else as "another reason". Only the Daily Brief's customer ids are hashed
(Sales ids carry a hash of their own) and its titles never sent. Turning off "Send the ledgers'
lines for iPhone and iPad" (Settings → Account, Mac) sends an empty reading once, marked as turned off, which empties
the cloud copy; turning it on again reads the ledgers and sends a new reading.

**History.** `desk_state`, `obligations` and `vendors` are audited: `audit_events` keeps every version of their rows
(before and after each write), and it is append-only for the app. A tombstone, turning ledger lines off (the ledger
tables are not audited) and the rollback below do not remove that history. If the owner ever needs it gone, in the SQL
editor (as `postgres`): `delete from public.audit_events where table_name in ('desk_state', 'obligations', 'vendors');`

## How a row is merged (`DeskCloudMerge`, LinumicCore)

Each row is merged on its own, from what this device and the server last agreed on (the base, in `desk-sync.json`),
what this device holds now, and what the server holds now:

| This device | Server | Result |
|---|---|---|
| unchanged | unchanged | nothing |
| changed | unchanged | sent with the version it is based on |
| unchanged | changed | taken in |
| changed | changed, the same | taken in |
| changed | changed, differently | **conflict**: both kept and shown; the owner keeps one |

- Every write names the version it is based on. The server refuses a write whose row has moved on and answers the row
  as it is (`stale`), so a race between two devices ends as a conflict, never an overwrite.
- A row missing on the server (restored from an older copy) is sent again; a row missing on this device (a lost
  `desk-state.json`) is taken in again. Neither is read as a deletion.
- A row the server holds that this version of the app can't read (a later version wrote it, for example with an area
  this one does not know) is left alone by id: never sent over, never read as missing, its base kept; Settings says
  how many there are. The push answers are read one by one, so such a row never fails the sync.
- The pull names the set of tables (`epoch`). When they were made anew (rolled back and applied again, versions from 1
  again), each device forgets what it had agreed with the old ones and merges from nothing: a row that differs is a
  conflict, never read as "unchanged" because its version number matches.
- Only an undo the owner made is a deletion: "Restore" on the Desk (`DeskState.restored`) and "Reopen" of a Done
  (`ObligationsFile.reopened`). It is sent as a tombstone (a new version), never a deleted row.
- A mark this device drops because it no longer applies here (a snooze that ended, a changed fact, a line gone from a
  ledger that was read) stays in the cloud for a device where it still applies, and is not taken in again here until
  it changes there.
- The facts recorded about one account are kept together when the two devices recorded different things (a renewal
  on one, a cost on the other); recording the same thing differently is a conflict.
- A change the owner makes while a sync is running is never overwritten by that sync; the next sync sees both. A
  conflict choice and a mark dropped as no longer applying, made while a sync runs, are applied again on top of what
  the sync left (the conflict buttons are disabled while it runs).
- Seed rows go up once per seed revision; a newer app's rows are left alone; they are never taken into
  `obligations.json`. A seed row a live reading replaces on the devices (`domain.linumic.com`) is not sent; revision 4
  makes a copy an earlier revision sent a tombstone. A test pins what is sent of the seed to `ObligationSeed.revision`, so a
  corrected seed row without a new revision fails CI.
- Times are each device's own clock (a mark's time, the order of an account's facts). A device whose clock is more
  than 5 minutes from the server's is told so in Settings → Account. The Mac's ledger reading is ordered by its version,
  never by its time, and a time ahead of the server's is stored as the server's.

## Reminders while the Mac is off

`private.sentinel_obligation_sweep()` (in `20261019090100_obligation_sweep.sql`) builds the schedule as the app's
register does: the seed and the owner's rows, with the owner's date when he set one; each account's renewal once its
day is recorded; Done for that due day closes it. Lead days as the app's (`Obligation.usableLeadDays`); severity as
the app's (overdue or within a day critical, 7 and 14 days warning, 30 days info). Live rows (domains, certificates,
licences, restore tests, the continuity export) are read on the devices and are not in it, and neither is a seed row
with a live row's id (`private.is_live_obligation_id`, the same prefixes as `ObligationsBuilder.liveIDPrefixes`), even
one an app sent; licences have their own sweep. The app's `ObligationAlerts` and the server's sweep are tested on the
same fixture (`Fixtures/desk-sync-sweep.json`, with a domain the Monitor read) and name the same keys.

It runs as its own pg_cron job, `sentinel-obligations` at 06:16 UTC. pg_cron runs each job in its own transaction, so
a failure in this sweep can never roll back the licence sweep's events (`sentinel-licences`, 06:15, not changed). The
server refuses a day that is not a real `YYYY-MM-DD` day ('tomorrow', 'infinity', '2026-02-30') in every row the sweep
reads, and the sweep reads every day through `private.iso_day`, which skips one that is not a day instead of failing,
so one bad row written by hand cannot stop it either.

The events reach the app through Server watch (`sentinel_recent_events(…, include_obligations => true)`). Each is read
against this device's register first: it is notified only when the obligation is still open here and still due on the
event's day; one Done here for that day is acknowledged on the server (the reminder is answered), and one re-dated or
unknown here is not notified. The line counts the days from the event's due day to today, never the days left when
the sweep wrote it. An event whose key this device already alerted about is not alerted again; one it did not is
recorded, so the device's own alert for that window does not follow. The app of 2026-10-18 calls the function with two
arguments and gets no obligation events (it could not read the new kind), and its overview count leaves them out too
(`sentinel_overview` counts them apart, as `unacknowledgedObligations`), so it never shows a count it can't clear.

## Objects

| Object | Kind | Who can use it |
|---|---|---|
| `desk_state`, `obligations`, `vendors` | tables, RLS on, audited (`audit_events`), `version bigint` bumped on every write by a trigger | admins read; nobody writes directly, not even an admin |
| `desk_ledger_reading`, `desk_items` | tables, RLS on, not audited (a copy of files the Mac reads every 30 minutes) | admins read; nobody writes directly |
| `desk_sync_pull()` | security invoker + `assert_admin()`; answers the rows, the ledger reading and `epoch` | admins |
| `push_desk_state(changes, device)`, `push_obligations(…)`, `push_vendors(…)` | security definer, checks `private.is_admin()`; per row `applied`, `stale` (with the row; also for the second of two first writes at the same moment) or `invalid` | admins |
| `replace_desk_items(expected_version, reading)` | security definer, checks `private.is_admin()`; `applied`, `unchanged`, `stale` or `invalid` | admins (the Mac) |
| `private.is_iso_day(text)`, `private.iso_day(text)`, `private.desk_sync_epoch()` | immutable helpers; the epoch is made anew each time the first migration is applied | |
| `private.sentinel_obligation_sweep(today)`, `private.obligation_schedule()`, `private.is_live_obligation_id(text)` | pg_cron (postgres) only | |
| `sentinel_events.kind` | + `obligationDue` | |
| `sentinel_recent_events(max_rows, include_acknowledged, include_obligations = false)` | replaces the two-argument function | admins |
| `sentinel_overview(hours)` | same signature; `unacknowledged` leaves obligation events out, `unacknowledgedObligations` counts them | admins |
| cron job `sentinel-obligations` | 06:16 UTC: `select private.sentinel_obligation_sweep()` (`sentinel-licences` at 06:15 is not changed) | |

The Security Advisor will list the four push/replace functions as SECURITY DEFINER callable by `authenticated`
(intended, like `ack_sentinel_event`: each checks `private.is_admin()` first and is the only way to write).

## In the app

- `DeskSyncModel` (App): runs `DeskCloudSync.sync` (LinumicCore) when signed in, a few seconds after each mark, Done or
  ledger reading, and as the automation job **Desk sync** (every 30 minutes, network, 2-minute time limit, also in
  iOS background refresh; before the ledgers, which still run just before the Brief). Remembers the bases, the
  conflicts and the Mac's reading in `desk-sync.json` next to the inventory.
- The Desk: a "Cloud sync" line under the header, the "Changed on two devices" card with "Keep this device's" and
  "Keep the other's", and on iPhone and iPad the Mac's ledger lines with their reading time.
- Settings → Account: the sync's state (with its date), rows the server did not accept, rows a later version wrote, a
  clock far from the server's, and (Mac) the ledger-lines switch.
- Server watch: obligation events read against this device's register (above).

## Owner steps (needs approval; changes the live project)

Status 2026-10-20 (04:25 UTC): **applied**, with the owner present, through the Supabase MCP's `apply_migration`
(history: `20261020042517 desk_sync`, `20261020042617 obligation_sweep`; an earlier no-op probe left
`20261020003945 desk_sync_probe`, `select 1`). Two earlier tries at 00:40 UTC, while the owner was away, answered
"Invalid or expired requestState" and changed nothing. Checked right after:
- the five tables exist with row-level security on, one read policy each, seven triggers;
- five `sentinel-%` jobs, all `postgres` and active; `sentinel-licences` unchanged at 06:15, `sentinel-obligations`
  at 06:16; `sentinel_recent_events(max_rows, include_acknowledged, include_obligations)`;
- the md5 of every function body (22) and of every table constraint matches a local apply of these files
  (PostgreSQL 16), so the live objects are byte for byte the reviewed SQL;
- `private.sentinel_obligation_sweep()` run twice: 0 and 0 (no obligations synced yet);
- security advisors: only the intended SECURITY DEFINER push RPCs (each checks `private.is_admin()`), the Sentinel's
  own two, and the project-wide leaked-password setting that was there before.

1. **Approve and apply the migrations**, in order, **the same way the Sentinel was applied** (the Supabase MCP's
   `apply_migration`, as on 2026-10-19; the same role then owns every Sentinel job): first
   `supabase/migrations/20261019090000_desk_sync.sql`, then `supabase/migrations/20261019090100_obligation_sweep.sql`.
   Each must apply whole or not at all: `apply_migration`, the CLI and the SQL editor run a file in one transaction;
   with `psql`, use `psql --single-transaction -f …`. The first adds the five tables and the RPCs; the second adds the
   `obligationDue` kind, the sweep and its own job, replaces `sentinel_recent_events` and changes the overview's count.
   Nothing existing is deleted; licences, the inventory and the 06:15 licence job are not touched.
2. **Check the objects and the schedule:**
   ```sql
   select tablename, rowsecurity from pg_tables
     where schemaname = 'public' and tablename in ('desk_state','obligations','vendors','desk_ledger_reading','desk_items');
   select jobid, jobname, username, schedule, command, active from cron.job where jobname like 'sentinel-%' order by jobname;
   -- expect five rows, all with the same username and active:
   --   sentinel-licences    | 15 6 * * *  | select private.sentinel_licence_sweep()      (as before)
   --   sentinel-obligations | 16 6 * * *  | select private.sentinel_obligation_sweep()
   --   sentinel-prune, sentinel-round, sentinel-snapshot (as before)
   select pg_get_function_identity_arguments('public.sentinel_recent_events'::regproc);
   -- expect: max_rows integer, include_acknowledged boolean, include_obligations boolean
   ```
   A second `sentinel-licences` row, or a username that differs from the others, means the migration ran as another
   role than the Sentinel's: stop and tell the developer before the next 06:15.
3. **Install the app from this branch on the Mac and the iPhone**, signed in (Settings → Account). On each, Settings →
   Account → "Sync Now". Expect "Desk and obligations: Synced …" and, on the Mac, Automation → Desk sync "… sent".
4. **Check what reached the server:**
   ```sql
   select count(*) filter (where not deleted) as marks, count(*) filter (where deleted) as undone from public.desk_state;
   select entry, count(*) from public.obligations group by entry order by entry;   -- seed: 7 at revision 4
   select entry, count(*) from public.vendors group by entry order by entry;       -- seed: 11
   select read_at, item_count, written_on from public.desk_ledger_reading;
   -- no customer's id in clear:
   select id from public.desk_state where id ~ '^brief\.(worktrack|siteMessages|licences)\|' and id !~ '\|h-[0-9a-f]{16}\|';
   ```
5. **The three "done when" checks of the roadmap:**
   - Done on the Mac, seen on the iPhone: mark a ledger line Done on the Mac, "Sync Now" on both; on the iPhone the
     line is under "You marked it, the ledger isn't ticked yet", with "The Mac's reading" and its time.
   - A conflict, not an overwrite: put the iPhone in airplane mode, Snooze a line there; Dismiss the same line on the
     Mac and sync; take the iPhone out of airplane mode and sync. The iPhone's Desk shows "Changed on two devices" with
     both; nothing changed on the Mac until one is kept.
   - An event with the Mac off, once: with an obligation due within 30 days (the seed's WorkTrack queue end,
     2026-10-26, qualifies until then), run the sweep twice and look:
     ```sql
     select private.sentinel_obligation_sweep();   -- the new events
     select private.sentinel_obligation_sweep();   -- 0: nothing twice
     select occurred_at, severity, title, dedup_key from public.sentinel_events
       where kind = 'obligationDue' order by occurred_at desc limit 10;
     ```
     The iPhone's Server watch shows them; one the iPhone already alerted about is not alerted again.
6. **Security advisors:** Dashboard → Advisors → Security: only the intended SECURITY DEFINER notes for the push
   functions above.

## Tests that ran (2026-10-20)

- `swift test --package-path Packages/LinumicCore`: every test passes, the 557 before this change and 51 Desk sync
  tests: merging one row, cloud keys and undo intents, two devices against an in-memory server with the SQL's rules
  (Done travels; concurrent edits become conflicts; Done with evidence and its reopen; account facts kept together;
  restore vs prune; a server or a file that lost rows; a change made during a sync; the seed once per revision;
  refusals; nothing that reads as a key leaves the device; hashed ids; a row a later app rewrote; a server made anew; a
  clock far from the server's; a date on an account's renewal row; a seed row sent first by the other device), the
  ledger reading (withholding, ids and fact hashes match the Mac's, lines turned off, a reading it can't read), the
  client against answers recorded from the real SQL and against a pull and push answers it can't fully read, the
  sweep parity fixture (with a domain the Monitor read), the live prefixes and event kinds against the migration, the
  seed pinned to its revision, the server's reminders read against the register (after a synced Done, days late,
  re-dated), the overview's counts, and the job's settings. `tools/test/persian-calendar.sh` passes the same suite.
- `supabase/tests/desk-sync/run.sh`: every migration on a throwaway Postgres 16 with the Sentinel suite's stand-ins
  for auth, Vault, pg_cron (named jobs keyed by name and role, as pg_cron does) and pg_net, then the behaviour checks
  (roles, versions and stale writes, tombstones, the refusals including days that are not days, audit, the ledger
  reading and a Mac clock ahead, the sweep on the parity fixture, the event reading and the overview, the schedule, and
  both 06:15/06:16 jobs run as pg_cron runs them with bad rows present: the licence event is still written), two
  sessions writing the same new row at the same moment in each push function (the second is answered `stale` with the
  first's row), then the rollback below exactly as printed here and the checks of what it leaves; then the same
  rollback on a second database where only the first migration was applied. `supabase/tests/sentinel/run.sh` still
  passes with the new migrations in place.
- macOS and iOS Simulator builds (`CODE_SIGNING_ALLOWED=NO`), and `tools/l10n/check_catalog.py` (Dari for every new
  string).
- **Not run:** the real Supabase (PostgREST, pg_cron, RLS with real JWTs) and two real devices. Steps 2 to 5 above are
  the first real run.

## Second review (2026-10-20)

- A row a later app wrote no longer fails the whole sync; it is left alone by id (above).
- The obligation sweep is its own job; the licence job is not touched. Days that are not days are refused, and skipped.
- Server watch reads each obligation event against this device's register, and words the days from today.
- The Desk's sync line says when this device last synced, and how many conflicts wait, never that the devices match.
- `domain.linumic.com` is no longer sent for the sweep (revision 4), and the sweep skips seed rows with live ids.
- The Dari summary says only what is enforced about names.
- Minor: two first writes at the same moment answer `stale`; a date on an account's renewal row is not synced; a clock
  far from the server's is reported, and a Mac reading dated ahead is stored at the server's time; conflict choices
  and drops made during a sync are kept; the overview counts obligation events apart; the pull's `epoch`; the
  rollback works after only the first migration and runs in one transaction; the pg_cron stand-in keys jobs by name and
  role; the ledger subject and source list are checked for keys; the history kept in `audit_events` is stated; the
  Settings line shows the date; "turned off" is an explicit flag, and a reading the app can't read is said so; the seed
  is pinned to its revision by a test.

## Limits

- One owner, two kinds of device. The written-on column says "the Mac" or "iPhone or iPad", nothing more.
- Rows are never deleted on the server; a mark dropped everywhere stays as a row. The tables stay small (marks and
  entries the owner made), well inside the Free plan.
- A conflict is shown on the device that found it (the second to sync); the first device sees the outcome once the
  owner chooses.
- Account facts are ordered by the time each device recorded them, on its own clock, here and in the sweep; a clock
  far from the server's is reported, not corrected.
- A row a later app version wrote is left alone by this one until it is updated: a change made here to that row stays
  here until then.

## Rollback

Run in the SQL editor (one transaction: it changes everything or nothing). It removes everything the two migrations
added and puts the Sentinel back as it was on 2026-10-19 (no `sentinel-obligations` job, the 06:15 licence job as it
always was, `sentinel_recent_events` with two arguments, `sentinel_overview` counting every event). It also works when
only the first migration was applied. The synced marks, obligations, accounts and the ledger reading are deleted with
their tables; every device keeps its own copy in `desk-state.json` and `obligations.json`, so nothing the owner entered
is lost. `audit_events` keeps the history of the rows (see "History" above to remove it). Applying the migrations
again later makes a new `epoch`: each device then forgets the versions it knew and merges from nothing, so nothing
needs removing on the devices.

```sql
begin;

-- 1. The obligation sweep (20261019090100_obligation_sweep.sql); nothing here fails if it was never applied.
select cron.unschedule(jobid) from cron.job where jobname = 'sentinel-obligations';
drop function if exists private.sentinel_obligation_sweep(date);
drop function if exists private.obligation_schedule();
drop function if exists private.is_live_obligation_id(text);
drop function if exists private.usable_lead_days(jsonb);
delete from public.sentinel_events where kind = 'obligationDue';
alter table public.sentinel_events drop constraint sentinel_events_kind_check;
alter table public.sentinel_events add constraint sentinel_events_kind_check
  check (kind in ('targetDown', 'targetRecovered', 'licenceExpiring', 'licenceExpired'));
drop function if exists public.sentinel_recent_events(int, boolean, boolean);
create or replace function public.sentinel_recent_events(max_rows int default 50, include_acknowledged boolean default true)
returns jsonb language plpgsql stable security invoker set search_path = ''
as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id', e.id, 'occurredAt', public.iso8601(e.occurred_at), 'kind', e.kind, 'severity', e.severity,
      'subject', e.subject, 'product', e.product, 'title', e.title, 'detail', e.detail,
      'acknowledgedAt', public.iso8601(e.acknowledged_at))) order by e.occurred_at desc, e.id desc)
    from (select * from public.sentinel_events x
          where include_acknowledged or x.acknowledged_at is null
          order by x.occurred_at desc, x.id desc limit greatest(1, least(max_rows, 500))) e), '[]'::jsonb);
end $$;
revoke execute on function public.sentinel_recent_events(int, boolean) from public, anon;
grant execute on function public.sentinel_recent_events(int, boolean) to authenticated;
-- sentinel_overview as 20261018090000_sentinel.sql has it (one count of every unacknowledged event).
create or replace function public.sentinel_overview(hours int default 24)
returns jsonb language plpgsql stable security invoker set search_path = ''
as $$
begin
  perform public.assert_admin();
  return jsonb_build_object(
    'generatedAt', public.iso8601(now()),
    'windowHours', hours,
    'lastRound', (select jsonb_build_object('id', r.id, 'startedAt', public.iso8601(r.started_at),
                         'finishedAt', public.iso8601(r.finished_at), 'source', r.source, 'targetCount', r.target_count,
                         'upCount', r.up_count, 'degradedCount', r.degraded_count, 'downCount', r.down_count)
                  from public.sentinel_rounds r order by r.started_at desc limit 1),
    'targets', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'targetID', s.target_id, 'product', s.product, 'state', s.state, 'consecutiveFailures', s.consecutive_failures,
        'since', public.iso8601(s.since), 'lastCheckedAt', public.iso8601(s.last_checked_at),
        'lastFailureAt', public.iso8601(s.last_failure_at), 'lastFailure', s.last_failure,
        'samples', w.samples, 'available', w.available, 'avgLatencyMS', w.avg_latency,
        'lastLatencyMS', lc.latency_ms, 'lastCheckState', lc.state)) order by s.product, s.target_id)
      from public.sentinel_target_state s
      left join lateral (
        select count(*)::int as samples,
               (count(*) filter (where k.state in ('up', 'degraded')))::int as available,
               round(avg(k.latency_ms))::int as avg_latency
        from public.sentinel_checks k
        where k.target_id = s.target_id and k.checked_at >= now() - make_interval(hours => hours)
      ) w on true
      left join lateral (
        select k.latency_ms, k.state from public.sentinel_checks k
        where k.target_id = s.target_id order by k.checked_at desc limit 1
      ) lc on true), '[]'::jsonb),
    'unacknowledged', (select count(*) from public.sentinel_events e where e.acknowledged_at is null),
    'snapshotCount', (select count(*) from public.inventory_snapshots),
    'lastSnapshot', (select jsonb_build_object('id', i.id, 'createdAt', public.iso8601(i.created_at), 'bytes', i.bytes,
                                               'schemaVersion', i.schema_version)
                     from public.inventory_snapshots i order by i.created_at desc limit 1)
  );
end $$;

-- 2. Desk sync (20261019090000_desk_sync.sql)
drop function if exists public.replace_desk_items(bigint, jsonb);
drop function if exists public.push_vendors(jsonb, text);
drop function if exists public.push_obligations(jsonb, text);
drop function if exists public.push_desk_state(jsonb, text);
drop function if exists public.desk_sync_pull();
drop function if exists private.desk_mark_json(public.desk_state);
drop function if exists private.obligation_json(public.obligations);
drop function if exists private.vendor_json(public.vendors);
drop table if exists public.desk_items, public.desk_ledger_reading, public.vendors, public.obligations, public.desk_state;
drop function if exists private.desk_sync_bump();
drop function if exists private.desk_sync_epoch();
drop function if exists private.vendor_entry_ok(text, text, jsonb);
drop function if exists private.obligation_entry_ok(text, text, date, jsonb);
drop function if exists private.cost_ok(jsonb);
drop function if exists private.iso_day(text);
drop function if exists private.is_iso_day(text);
drop function if exists private.nonblank(text);
drop function if exists private.desk_sync_has_secret(text);

commit;
```

## For the owner (دری)

- با ورود به ابر، علامت‌های «میز کار» (انجام شد، تعویق، منتظر دیگران، کنار گذاشتن با دلیل)، تعهدات و حساب‌ها میان مک و آیفون همگام می‌شوند. «انجام شد» در مک، در آیفون هم دیده می‌شود.
- آیفون دفترها را خودش نمی‌خواند؛ آخرین خواندن مک را با زمانش نشان می‌دهد. اگر از یک ساعت کهنه‌تر باشد، «کهنه» می‌گوید.
- اگر یک مورد را در دو دستگاه جدا از هم تغییر دهید، هیچ‌کدام پاک یا رونویسی نمی‌شود: کارت «تغییر در دو دستگاه» در «میز کار» هر دو را نشان می‌دهد تا خودتان یکی را نگه دارید.
- وقتی مک خاموش است، سرور هر روز ساعت ۱۰:۴۶ کابل، در کاری جدا از بررسی لایسنس‌ها (۱۰:۴۵)، تعهدات را بررسی می‌کند و برای هر پنجره (۳۰، ۱۴، ۷، ۱ روز و روز سررسید) فقط یک رویداد ثبت می‌کند. اگر یکی از این دو کار خطا بدهد، دیگری کارش را می‌کند. یادآوری‌ای که در این دستگاه «انجام شد» خورده باشد یا تاریخش عوض شده باشد اعلان نمی‌شود.
- شناسهٔ مشتریان در بخش‌های «گزارش روز» به شکل hash ذخیره می‌شود و عنوان موردهای «گزارش روز» به ابر نمی‌رود. سطرهای دفترها، دلیل‌های کنار گذاشتن و عنوان‌هایی که خودتان می‌نویسید ممکن است نام اشخاص را داشته باشند و همان‌طور که نوشته‌اید ذخیره می‌شوند؛ از سطرهای دفتر فقط متنی که ایمیل، شماره تلفن یا کلید دارد پنهان می‌شود، و هر چیزی که شبیه کلید یا توکن باشد اصلاً فرستاده نمی‌شود.
- تاریخچهٔ هر تغییر در جدول audit_events می‌ماند، حتی پس از برگرداندن (rollback)؛ پاک کردنش دستور جداگانه دارد (بخش History در بالا).
- وضع ۲۰۲۶-۱۰-۲۰ (۰۴:۲۵ UTC): هر دو migration با حضور شما اجرا شد. پنج جدول با RLS، پنج کار `sentinel-…` با یک کاربر، و متن همهٔ ۲۲ تابع با فایل یکی است. یک سطر بی‌اثر `desk_sync_probe` از تلاش پیشین در تاریخچه مانده است.
- کار شما: تأیید و اجرای دو migration به همان روشی که Sentinel اجرا شد (مراحل بالا)، بررسی پنج کار `sentinel-…` با یک username، سپس «اکنون همگام کن» در هر دو دستگاه.
