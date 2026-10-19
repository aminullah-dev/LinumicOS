# Desk sync (همگام‌سازی میز کار)

Phase 3 of [company-os-roadmap.md](company-os-roadmap.md): the Desk and the obligations on every device, and reminders
while the Mac is off.

**Status, 2026-10-19:** built on the branch `feat/desk-sync`, tested on a scratch Postgres and in LinumicCore.
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
- **Reminders while the Mac is off.** The Sentinel's daily 06:15 UTC job also sweeps the synced obligations and writes
  one event per obligation and lead window (30, 14, 7, 1 days, and on the day), keyed `obligation:<id>:<due>:<lead>`,
  the same key as the app's own notification, so a re-run never writes it twice and a device that already alerted does
  not alert again.

## What goes to the cloud, and what never does

| Table | Holds | Never |
|---|---|---|
| `desk_state` | per Desk item: its id, the mark's kind and time, the fact hash, a snooze's end, a dismissal's reason | titles, details, or a customer's entry id: in the Brief sections that name customers (WorkTrack companies, website messages, licences) the id's subject is a hash (`h-…`), and the server refuses one in clear |
| `obligations` | the owner's rows, dates (with source), Done (with evidence), as `obligations.json` holds them; the seed rows the app ships (id, title, product, day, lead days; their sources stay in the app) | a row without its source or evidence, a row that reads as a key |
| `vendors` | the owner's accounts and, per account, the facts recorded on its card (renewal, holder, cost, each with its source); the seed accounts' names | passwords, logins, card numbers (the forms never ask for them), a row that reads as a key |
| `desk_ledger_reading`, `desk_items` | the Mac's last reading: per ledger its state and counts; per line its id, title, product, file:line, severity, due day, fact hash | the lines under a line, its detail; the text of a line that holds an email address, a phone number in `+…`, `(…)` or `0…` form, or a key (sent as "(withheld)"); any Daily Brief line |

Before anything is sent the app checks every row against the key and token patterns of the continuity export
(`ContinuityBundle.forbiddenPatterns`); a match is not sent and is listed in Settings → Account as not accepted. The
server checks the same patterns again. Ledger lines can name people: the withholding catches addresses, numbers and
keys, not names. Turning off "Send the ledgers' lines for iPhone and iPad" (Settings → Account, Mac) sends an empty
reading once, which empties the cloud copy.

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
- Only an undo the owner made is a deletion: "Restore" on the Desk (`DeskState.restored`) and "Reopen" of a Done
  (`ObligationsFile.reopened`). It is sent as a tombstone (a new version), never a deleted row.
- A mark this device drops because it no longer applies here (a snooze that ended, a changed fact, a line gone from a
  ledger that was read) stays in the cloud for a device where it still applies, and is not taken in again here until
  it changes there.
- The facts recorded about one account are kept together when the two devices recorded different things (a renewal
  on one, a cost on the other); recording the same thing differently is a conflict.
- A change the owner makes while a sync is running is never overwritten by that sync; the next sync sees both.
- Seed rows go up once per seed revision; a newer app's rows are left alone; they are never taken into
  `obligations.json`.

## Reminders while the Mac is off

`private.sentinel_obligation_sweep()` (in `20261019090100_obligation_sweep.sql`) builds the schedule as the app's
register does: the seed and the owner's rows, with the owner's date when he set one; each account's renewal once its
day is recorded; Done for that due day closes it. Lead days as the app's (`Obligation.usableLeadDays`); severity as
the app's (overdue or within a day critical, 7 and 14 days warning, 30 days info). Live rows (domains, certificates,
licences, restore tests, the continuity export) are read on the devices and are not in it; licences have their own
sweep. The app's `ObligationAlerts` and the server's sweep are tested on the same fixture
(`Fixtures/desk-sync-sweep.json`) and name the same keys.

The events reach the app through Server watch (`sentinel_recent_events(…, include_obligations => true)`). An event
whose key this device already alerted about is not alerted again; one it did not is alerted and recorded, so the
device's own alert for that window does not follow. The app of 2026-10-18 calls the function with two arguments and
gets no obligation events (it could not read the new kind).

## Objects

| Object | Kind | Who can use it |
|---|---|---|
| `desk_state`, `obligations`, `vendors` | tables, RLS on, audited (`audit_events`), `version bigint` bumped on every write by a trigger | admins read; nobody writes directly, not even an admin |
| `desk_ledger_reading`, `desk_items` | tables, RLS on, not audited (a copy of files the Mac reads every 30 minutes) | admins read; nobody writes directly |
| `desk_sync_pull()` | security invoker + `assert_admin()` | admins |
| `push_desk_state(changes, device)`, `push_obligations(…)`, `push_vendors(…)` | security definer, checks `private.is_admin()`; per row `applied`, `stale` (with the row) or `invalid` | admins |
| `replace_desk_items(expected_version, reading)` | security definer, checks `private.is_admin()`; `applied`, `unchanged`, `stale`, `older` or `invalid` | admins (the Mac) |
| `private.sentinel_obligation_sweep(today)`, `private.obligation_schedule()` | pg_cron (postgres) only | |
| `sentinel_events.kind` | + `obligationDue` | |
| `sentinel_recent_events(max_rows, include_acknowledged, include_obligations = false)` | replaces the two-argument function | admins |
| cron job `sentinel-licences` | 06:15 UTC: `select private.sentinel_licence_sweep(), private.sentinel_obligation_sweep()` | |

The Security Advisor will list the four push/replace functions as SECURITY DEFINER callable by `authenticated`
(intended, like `ack_sentinel_event`: each checks `private.is_admin()` first and is the only way to write).

## In the app

- `DeskSyncModel` (App): runs `DeskCloudSync.sync` (LinumicCore) when signed in, a few seconds after each mark, Done or
  ledger reading, and as the automation job **Desk sync** (every 30 minutes, network, 2-minute time limit, also in
  iOS background refresh; before the ledgers, which still run just before the Brief). Remembers the bases, the
  conflicts and the Mac's reading in `desk-sync.json` next to the inventory.
- The Desk: a "Cloud sync" line under the header, the "Changed on two devices" card with "Keep this device's" and
  "Keep the other's", and on iPhone and iPad the Mac's ledger lines with their reading time.
- Settings → Account: the sync's state, rows the server did not accept, and (Mac) the ledger-lines switch.

## Owner steps (needs approval; changes the live project)

1. **Approve and apply the migrations**, in order, with the Supabase CLI linked to the project or in the SQL editor:
   `supabase/migrations/20261019090000_desk_sync.sql`, then `supabase/migrations/20261019090100_obligation_sweep.sql`.
   The first adds the five tables and the RPCs; the second adds the `obligationDue` kind, the sweep, replaces
   `sentinel_recent_events` and changes the 06:15 job. Nothing existing is deleted; licences and the inventory are
   not touched.
2. **Check the objects and the schedule:**
   ```sql
   select tablename, rowsecurity from pg_tables
     where schemaname = 'public' and tablename in ('desk_state','obligations','vendors','desk_ledger_reading','desk_items');
   select jobname, schedule, command from cron.job where jobname = 'sentinel-licences';
   -- expect: 15 6 * * * | select private.sentinel_licence_sweep(), private.sentinel_obligation_sweep()
   select pg_get_function_identity_arguments('public.sentinel_recent_events'::regproc);
   -- expect: max_rows integer, include_acknowledged boolean, include_obligations boolean
   ```
3. **Install the app from this branch on the Mac and the iPhone**, signed in (Settings → Account). On each, Settings →
   Account → "Sync Now". Expect "Desk and obligations: Synced …" and, on the Mac, Automation → Desk sync "… sent".
4. **Check what reached the server:**
   ```sql
   select count(*) filter (where not deleted) as marks, count(*) filter (where deleted) as undone from public.desk_state;
   select entry, count(*) from public.obligations group by entry order by entry;   -- seed: 8 at revision 3
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

## Tests that ran (2026-10-19)

- `swift test --package-path Packages/LinumicCore`: every test passes, the 557 before this change and 36 new Desk sync
  tests: merging one row, cloud keys and undo intents, two devices against an in-memory server with the SQL's rules
  (Done travels; concurrent edits become conflicts; Done with evidence and its reopen; account facts kept together;
  restore vs prune; a server or a file that lost rows; a change made during a sync; the seed once per revision;
  refusals; nothing that reads as a key leaves the device; hashed ids), the ledger reading (withholding, ids and fact
  hashes match the Mac's), the client against answers recorded from the real SQL, the sweep parity fixture, the event
  kinds against the migration, and the job's settings. `tools/test/persian-calendar.sh` passes the same suite.
- `supabase/tests/desk-sync/run.sh`: every migration on a throwaway Postgres 16 with the Sentinel suite's stand-ins
  for auth, Vault, pg_cron and pg_net, then 79 behaviour checks (roles, versions and stale writes, tombstones, the
  refusals, audit, the ledger reading, the sweep on the parity fixture, the event reading and the schedule), then the
  rollback below exactly as printed here and 9 checks of what it leaves. `supabase/tests/sentinel/run.sh` still
  passes with the new migrations in place.
- macOS and iOS Simulator builds (`CODE_SIGNING_ALLOWED=NO`), and `tools/l10n/check_catalog.py` (Dari for every new
  string).
- **Not run:** the real Supabase (PostgREST, pg_cron, RLS with real JWTs) and two real devices. Steps 2 to 5 above are
  the first real run.

## Limits

- One owner, two kinds of device. The written-on column says "the Mac" or "iPhone or iPad", nothing more.
- Rows are never deleted on the server; a mark dropped everywhere stays as a row. The tables stay small (marks and
  entries the owner made), well inside the Free plan.
- A conflict is shown on the device that found it (the second to sync); the first device sees the outcome once the
  owner chooses.
- Re-running `20261018090100_sentinel_schedule.sql` after these migrations would put the licence sweep back on its own
  in the 06:15 job; run the `cron.schedule` line of `20261019090100_obligation_sweep.sql` again after it.

## Rollback

Run in the SQL editor. It removes everything the two migrations added and puts the Sentinel back as it was on
2026-10-19 (the 06:15 job runs the licence sweep only; `sentinel_recent_events` takes two arguments again). The synced
marks, obligations, accounts and the ledger reading are deleted with their tables; every device keeps its own copy in
`desk-state.json` and `obligations.json`, so nothing the owner entered is lost. `audit_events` keeps the history of
the rows (it is append-only).

```sql
-- 1. The obligation sweep (20261019090100_obligation_sweep.sql)
select cron.schedule('sentinel-licences', '15 6 * * *', $$select private.sentinel_licence_sweep()$$);
drop function if exists private.sentinel_obligation_sweep(date);
drop function if exists private.obligation_schedule();
drop function if exists private.usable_lead_days(jsonb);
delete from public.sentinel_events where kind = 'obligationDue';
alter table public.sentinel_events drop constraint sentinel_events_kind_check;
alter table public.sentinel_events add constraint sentinel_events_kind_check
  check (kind in ('targetDown', 'targetRecovered', 'licenceExpiring', 'licenceExpired'));
drop function if exists public.sentinel_recent_events(int, boolean, boolean);
create function public.sentinel_recent_events(max_rows int default 50, include_acknowledged boolean default true)
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
drop function if exists private.vendor_entry_ok(text, text, jsonb);
drop function if exists private.obligation_entry_ok(text, text, date, jsonb);
drop function if exists private.cost_ok(jsonb);
drop function if exists private.nonblank(text);
drop function if exists private.desk_sync_has_secret(text);
```

## For the owner (دری)

- با ورود به ابر، علامت‌های «میز کار» (انجام شد، تعویق، منتظر دیگران، کنار گذاشتن با دلیل)، تعهدات و حساب‌ها میان مک و آیفون همگام می‌شوند. «انجام شد» در مک، در آیفون هم دیده می‌شود.
- آیفون دفترها را خودش نمی‌خواند؛ آخرین خواندن مک را با زمانش نشان می‌دهد. اگر از یک ساعت کهنه‌تر باشد، «کهنه» می‌گوید.
- اگر یک مورد را در دو دستگاه جدا از هم تغییر دهید، هیچ‌کدام پاک یا رونویسی نمی‌شود: کارت «تغییر در دو دستگاه» در «میز کار» هر دو را نشان می‌دهد تا خودتان یکی را نگه دارید.
- وقتی مک خاموش است، سرور هر روز ساعت ۱۰:۴۵ کابل تعهدات را بررسی می‌کند و برای هر پنجره (۳۰، ۱۴، ۷، ۱ روز و روز سررسید) فقط یک رویداد ثبت می‌کند.
- در ابر عنوان موردهای «گزارش روز»، نام مشتری، رمز، کلید یا شمارهٔ کارت ذخیره نمی‌شود. سطری از دفتر که ایمیل، شمارهٔ تلفن یا کلید داشته باشد بدون متنش فرستاده می‌شود.
- کار شما: تأیید و اجرای دو migration (مراحل بالا)، سپس «اکنون همگام کن» در هر دو دستگاه.
