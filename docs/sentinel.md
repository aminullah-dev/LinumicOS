# Sentinel (server-side checks)

**Status, 2026-10-19:** **deployed** to the live Supabase project (`mczuclgfqxffcbiwvecf`) on 2026-10-19 at 00:57 UTC,
after the owner's approval; the evidence is under "Deployed" below. The deploy steps are kept for a redeploy.
Phase 3 of the roadmap adds an obligation sweep to the daily job (`20261019090100_obligation_sweep.sql`, below and in
[desk-sync.md](desk-sync.md)); it is **not applied yet** and waits for the owner's approval.

The Monitor in the app only checks while the app is open. The Sentinel runs the same checks on Supabase, so they keep
running while the Mac is off or asleep:

- **Every 10 minutes:** one plain, unauthenticated GET to each of the Monitor's 15 public URLs, judged exactly as the
  app judges them (`MonitorEvaluator`).
- **Daily, 06:15 UTC (10:45 Kabul):** licences in the `licences` ledger that expire within 30, 7 or 1 days, or expired
  in the last 30 days. Once `20261019090100_obligation_sweep.sql` is applied, the same job then sweeps the obligations
  synced from the devices: one `obligationDue` event per obligation entering a 30, 14, 7 or 1-day window or reaching
  its day, keyed `obligation:<id>:<due>:<lead>` like the app's own notification ([desk-sync.md](desk-sync.md)).
- **Weekly, Sundays 02:30 UTC:** a copy of `export_inventory()` in `inventory_snapshots`, newest 12 kept. Supabase Free
  has no point-in-time recovery, so this is the only server-side history of the inventory.
- **Daily, 03:45 UTC:** rounds and checks older than 14 days are pruned. Events and snapshots are kept.

Events are written **only when something changes**: a target goes down (two failed rounds in a row), comes back, a
licence crosses a threshold, or (with the obligation sweep) an obligation enters a lead window. Each event has a unique
`dedup_key`, so a re-run never repeats one.

## How it fits together

```
pg_cron ── every 10 min ──> private.sentinel_invoke()
                               │ pg_net POST + x-sentinel-secret (from Vault)
                               v
                     Edge Function `sentinel` ── GET x15 ──> public URLs (no credentials)
                               │ checks secret: sentinel_secret_ok()        (service role)
                               │ writes round:   sentinel_record_round()    (service role)
                               v
     sentinel_rounds / sentinel_checks / sentinel_target_state / sentinel_events
                               ^
                               │ sentinel_overview(), sentinel_recent_events(),
                               │ ack_sentinel_event(), request_sentinel_round()   (admins only)
                      Linumic OS (SentinelClient)
```

Files:

| What | Where |
|---|---|
| Tables, RLS, recording, licence sweep, snapshot, pruning, reading RPCs | `supabase/migrations/20261018090000_sentinel.sql` |
| pg_cron jobs, pg_net call, Vault secret, "Check now" RPC | `supabase/migrations/20261018090100_sentinel_schedule.sql` |
| Obligation sweep, the `obligationDue` kind, `sentinel_recent_events` with obligations, the 06:15 job running both sweeps (Phase 3, not applied yet) | `supabase/migrations/20261019090100_obligation_sweep.sql` |
| Edge Function (targets copied from `MonitorCatalog`) | `supabase/functions/sentinel/` |
| Swift models, client, summary | `Packages/LinumicCore/Sources/LinumicCore/Sentinel/` |
| Tests | `SentinelTests.swift` (Swift), `supabase/functions/sentinel/evaluate_test.ts` (Deno), `supabase/tests/sentinel/` (SQL) |

## Objects

| Object | Kind | Who can use it |
|---|---|---|
| `sentinel_rounds`, `sentinel_checks`, `sentinel_target_state`, `sentinel_events`, `inventory_snapshots` | tables, RLS on | admins read (`private.is_admin()`); nobody writes through the API |
| `sentinel_record_round(round jsonb)` | security definer | `service_role` only (the Edge Function) |
| `sentinel_secret_ok(candidate text)` | security definer | `service_role` only |
| `sentinel_overview(hours int = 24)` | security invoker + `assert_admin()` | admins |
| `sentinel_recent_events(max_rows int = 50, include_acknowledged bool = true)` | security invoker + `assert_admin()` | admins; after `20261019090100` it takes a third argument, `include_obligations bool = false`, so the app of 2026-10-18 (two arguments) gets no event of a kind it can't read |
| `private.sentinel_obligation_sweep(today)`, `private.obligation_schedule()` (after `20261019090100`) | security definer / invoker | pg_cron (postgres) only |
| `ack_sentinel_event(event_id bigint)` | security definer, checks `private.is_admin()` | admins; audited in `audit_events` |
| `request_sentinel_round()` | security definer, checks `private.is_admin()` | admins; at most once every 2 minutes |
| `private.sentinel_invoke`, `private.sentinel_licence_sweep`, `private.take_inventory_snapshot`, `private.sentinel_prune` | security definer | pg_cron (postgres) only |
| `private.sentinel_manual_requests` | table | nobody through the API |
| Vault secrets `sentinel_secret`, `sentinel_function_url` | Vault | the functions above |
| cron jobs `sentinel-round`, `sentinel-licences`, `sentinel-snapshot`, `sentinel-prune` | pg_cron | |

The two security-definer RPCs that admins call check `private.is_admin()` directly: inside a security-definer function
`current_user` is the owner, which `assert_admin()` would wave through.

The secret is generated inside the database (32 random bytes) and never leaves it: the Edge Function keeps no copy and
asks `sentinel_secret_ok()` whether the header it received is right. The function is deployed with JWT verification
off, because pg_cron calls it with the secret instead of a user token.

## Using it from the app

```swift
let client = SentinelClient(config: supabaseConfig, token: { try await sessionManager.accessToken() })
let overview = try await client.overview(hours: 24)          // SentinelOverview
let summary = SentinelSummary.make(overview, now: .now)       // health, down/slow/flapping, drift, snapshot
let events = try await client.events(limit: 50, includeAcknowledged: false)  // [SentinelEvent], newest first, obligations included
                                                                              // (asked as before when the server is older)
try await client.acknowledge(eventID: event.id)
let accepted = try await client.requestRound()                // false = asked within the last 2 minutes
```

Suggested display (the app layer decides):

- **Health line** from `SentinelSummary.health`:
  - `.notRunning`: "Server checks are not deployed yet". Not an error, and never shown as all-up.
  - `.stale(lastRoundAt)`: "Server checks stopped at …". The schedule or the function is broken; show the stale
    numbers greyed.
  - `.down(count)`, `.slow(count)`, `.allUp`.
- **Per target:** the server's `state`, `uptime` (nil means no samples, never 0 %), last check time and latency, and
  `lastFailure`. `flapping` targets failed the latest check once but are not down yet.
- **Events:** localize from `kind` + `detail`; `title` is English and written by the server. "Seen" calls
  `acknowledge`. Unacknowledged critical events are the ones to notify about. An `obligationDue` event carries the
  obligation's own title (or the account's name with `renewal`), its day, days left, window and key; the app skips the
  notification when it already alerted that key itself, and records it otherwise.
- **Backups:** `lastSnapshotAt`, plus `snapshotOverdue` when rounds run but the weekly copy is missing or older than
  8 days.
- **Drift:** `missingFromServer` and `unknownToApp` should both be empty. A non-empty list means `MonitorCatalog` and
  `supabase/functions/sentinel/targets.ts` disagree. `SentinelParityTests` fails the build in that case.
- `SupabaseError.notAuthorized` means the signed-in Apple ID is not in `app_admins`.

## Deployed (2026-10-19 00:57 UTC)

Approved by the owner and applied to `mczuclgfqxffcbiwvecf` through the Supabase MCP: migrations `sentinel` and
`sentinel_schedule`, Edge Function `sentinel` version 1 (JWT verification off). Evidence:
- First round (manual): 15 targets, 15 up, function reply `{"recorded":{"events":0,"roundID":1},"up":15,...}` (HTTP 200).
- Calls without the secret or with a wrong one: HTTP 401.
- `inventory_snapshots` id 1: 169,127 bytes, schema 2. Licence sweep: 0 events (nothing within 30 days).
- `cron.job`: sentinel-round, sentinel-licences, sentinel-snapshot, sentinel-prune, all active.
- Security advisors: `ack_sentinel_event` and `request_sentinel_round` are SECURITY DEFINER callable by `authenticated`
  (intended: both check `private.is_admin()` first). The other warning (leaked password protection) predates this.

The snapshots live in the same database, so they cover mistakes and bad imports, not the loss of the project itself.
The app's daily local backup (automation.md) is outside Supabase but on the same Mac; the copy off the Mac is the
encrypted continuity export ([continuity.md](continuity.md)).

## Owner deploy steps (needs approval; changes the live project)

1. **Apply the migrations**, in order, with the Supabase CLI linked to the project or in the SQL editor:
   `20261018090000_sentinel.sql`, then `20261018090100_sentinel_schedule.sql`. The second one enables `pg_cron` and
   `pg_net`, creates the two Vault secrets and schedules the four jobs.
2. **Deploy the function with JWT verification off:**
   `supabase functions deploy sentinel --project-ref mczuclgfqxffcbiwvecf --no-verify-jwt`
   `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are provided by the platform; no secret needs setting.
3. **Run one round now** in the SQL editor and check that it lands. Rounds are asynchronous, so wait about 30 s:
   ```sql
   select private.sentinel_invoke('manual');
   -- after ~30 s:
   select id, started_at, target_count, up_count, degraded_count, down_count from public.sentinel_rounds order by id desc limit 1;
   select status_code, content::text from net._http_response order by id desc limit 1;  -- the function's reply
   select target_id, state, status_code, latency_ms, reason from public.sentinel_checks
     where round_id = (select max(id) from public.sentinel_rounds) order by target_id;
   ```
   Expect `target_count = 15`.
4. **Take the first snapshot and run the licence sweep once** instead of waiting for Sunday and the morning:
   ```sql
   select private.take_inventory_snapshot();
   select private.sentinel_licence_sweep();
   select id, created_at, bytes, schema_version from public.inventory_snapshots order by id desc;
   ```
5. **Check the schedule and the security advisors:**
   ```sql
   select jobname, schedule, active from cron.job where jobname like 'sentinel-%';
   select jobname, status, return_message, start_time from cron.job_run_details
     where jobid in (select jobid from cron.job where jobname like 'sentinel-%') order by start_time desc limit 10;
   ```
   Dashboard → Advisors → Security: no new findings for the `sentinel_*` objects.

Free plan budget: about 4,320 function calls and 65,000 check rows a month (pruned to the last 14 days, about 30,000
rows). It is not verified whether this scheduled traffic keeps a Free project from being paused for inactivity.

**Local stack instead of live:** apply the migrations, then point the URL at the local function:
`select vault.update_secret((select id from vault.secrets where name = 'sentinel_function_url'), 'http://host.docker.internal:54321/functions/v1/sentinel');`

## Tests that ran (2026-10-18)

- `swift test --package-path Packages/LinumicCore`: 396 tests passed, including 14 Sentinel tests. These are the client
  against recorded RPC JSON, the summary rules, and parity of `targets.ts` with `MonitorCatalog`: every id, URL,
  product, health rule and slow threshold.
- `deno check` on the function, and `deno test supabase/functions/sentinel/` (7 evaluator tests).
- `supabase/tests/sentinel/run.sh`: every migration in the repository on a throwaway Postgres 16, with stand-ins for
  Supabase's auth, Vault, pg_cron and pg_net, then 46 behaviour checks:
  - state changes and events, and no duplicates;
  - every API role refused where it should be;
  - acknowledging, the audit row, and the 2-minute limit on "Check now";
  - the secret check;
  - licence thresholds across days;
  - the 12-snapshot limit and pruning;
  - re-running the schedule file.
- The rollback SQL below, on the same throwaway database: no Sentinel table, function, secret or job was left, and
  `licences` was untouched.
- **Not run:** the real `pg_cron`, `pg_net`, Vault and Edge runtime. The Supabase CLI and Docker are not installed on
  this Mac. Step 3 above is the first real end-to-end run.

## Rollback

If `20261019090100_obligation_sweep.sql` (Phase 3) is applied, roll it back first with the SQL in
[desk-sync.md](desk-sync.md#rollback): it puts `sentinel_recent_events` and the 06:15 job back as they were here.

Run in the SQL editor. It removes everything the two migrations added; the `licences` ledger and the inventory are not
touched. Snapshots are deleted with their table, so export the last one first if it's needed.

```sql
select cron.unschedule(j) from unnest(array['sentinel-round', 'sentinel-licences', 'sentinel-snapshot', 'sentinel-prune']) j
  where exists (select 1 from cron.job where jobname = j);
drop function if exists public.request_sentinel_round();
drop function if exists private.sentinel_invoke(text);
drop function if exists public.sentinel_secret_ok(text);
drop table if exists private.sentinel_manual_requests;
delete from vault.secrets where name in ('sentinel_secret', 'sentinel_function_url');
drop function if exists public.ack_sentinel_event(bigint);
drop function if exists public.sentinel_recent_events(int, boolean);
drop function if exists public.sentinel_overview(int);
drop function if exists private.sentinel_prune(interval);
drop function if exists private.take_inventory_snapshot();
drop function if exists private.sentinel_licence_sweep(date);
drop function if exists public.sentinel_record_round(jsonb);
drop table if exists public.sentinel_events, public.sentinel_target_state, public.sentinel_checks,
  public.sentinel_rounds, public.inventory_snapshots;
-- Only if nothing else uses them:
-- drop extension if exists pg_net; drop extension if exists pg_cron;
```

Then delete the function: `supabase functions delete sentinel --project-ref mczuclgfqxffcbiwvecf`.
