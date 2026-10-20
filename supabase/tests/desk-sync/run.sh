#!/bin/bash
# Runs every migration on a throwaway local Postgres (16+) with the Sentinel suite's stand-ins for Supabase's auth,
# Vault, pg_cron and pg_net (../sentinel/stubs.sql), then the Desk sync behaviour checks (behaviour.sql), two devices
# writing the same new row at the same moment (two sessions), then the rollback exactly as docs/desk-sync.md prints it
# (its first sql block under "## Rollback") and what it must leave (after-rollback.sql). Then, on a second throwaway
# database, the same rollback after only the first migration was applied. Nothing touches the live project.
# SUPABASE_DEFAULTS picks Supabase's default privileges in `public` (../grants/defaults-*.sql): old (the live project
# before 2026-10-30, the default), opt-in (from 2026-10-30) or none (no automatic grant).
#
#   supabase/tests/desk-sync/run.sh                          # from the repository root; needs initdb, pg_ctl and psql
#   SUPABASE_DEFAULTS=none supabase/tests/desk-sync/run.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
PORT=${DESK_SYNC_TEST_PORT:-54331}
DEFAULTS="$REPO/supabase/tests/grants/defaults-${SUPABASE_DEFAULTS:-old}.sql"
[[ -f "$DEFAULTS" ]] || { echo "SUPABASE_DEFAULTS must be old, opt-in or none" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'pg_ctl -D "$TMP/data" stop -m immediate >/dev/null 2>&1 || true; pg_ctl -D "$TMP/data2" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

run() { psql -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"; }
notices() { sed -n 's/.*NOTICE: *//p; /ERROR/p; /PASSED/p'; }
start() {
  initdb -D "$TMP/$1" -U postgres --auth=trust >/dev/null
  pg_ctl -D "$TMP/$1" -o "-p $PORT -c unix_socket_directories='' -c listen_addresses=127.0.0.1" -l "$TMP/$1.log" start >/dev/null
  run -f "$REPO/supabase/tests/sentinel/stubs.sql"
  run -f "$DEFAULTS"
}
migrate() {
  for f in "$@"; do
    # pg_cron and pg_net are stubbed.
    grep -v '^create extension' "$f" > "$TMP/migration.sql"
    run -f "$TMP/migration.sql"
  done >/dev/null
}
awk '/^## Rollback/ { on = 1 } on && /^```sql/ { inside = 1; next } inside && /^```/ { exit } inside' \
  "$REPO/docs/desk-sync.md" > "$TMP/rollback.sql"
[[ -s "$TMP/rollback.sql" ]] || { echo "No rollback SQL found in docs/desk-sync.md" >&2; exit 1; }

start data
migrate "$REPO"/supabase/migrations/*.sql
fixture="$REPO/Packages/LinumicCore/Tests/LinumicCoreTests/Fixtures/desk-sync-sweep.json"
run -v fixture="$(cat "$fixture")" -f "$HERE/behaviour.sql" 2>&1 | notices

# Two devices write the same new row at the same moment: the first holds its insert open for two seconds, the second
# waits on it and must be answered "stale" with the first one's row (not "invalid" with a duplicate-key error).
as_admin="set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';"
for push in "push_desk_state('[{\"id\":\"ledger.velro|race|checkbox\",\"expectedVersion\":0,\"data\":{\"kind\":\"done\",\"at\":\"2026-10-19T10:00:00Z\",\"factHash\":\"0123456789abcdef\"}}]', 'macOS')" \
            "push_obligations('[{\"id\":\"date:owner.race\",\"entry\":\"date\",\"key\":\"owner.race\",\"expectedVersion\":0,\"data\":{\"obligationID\":\"owner.race\",\"due\":\"2026-11-01\",\"source\":\"sample letter\",\"enteredAt\":\"2026-10-19T10:00:00Z\"}}]', 'macOS')" \
            "push_vendors('[{\"id\":\"facts:race\",\"entry\":\"facts\",\"key\":\"race\",\"expectedVersion\":0,\"data\":{\"edits\":[{\"accountID\":\"race\",\"renewal\":\"2026-12-01\",\"renewalSource\":\"bill\",\"enteredAt\":\"2026-10-19T10:00:00Z\"}]}}]', 'macOS')"; do
  name=${push%%(*}
  run -c "begin; $as_admin select public.$push; select pg_sleep(2); commit;" >/dev/null &
  first=$!
  # Until the first session holds its new row (it is in pg_sleep, inside its transaction).
  for _ in $(seq 50); do
    [[ $(run -At -c "select count(*) from pg_stat_activity where query like '%pg_sleep(2)%' and pid <> pg_backend_pid()") == 1 ]] && break
    sleep 0.1
  done
  second=$(run -At -c "$as_admin select (r->0->>'status') || '|' || coalesce(r->0->'row'->>'version', '-') from (select public.$push as r) x;" | tail -1)
  wait "$first"
  [[ "$second" == "stale|1" ]] || { echo "FAIL: $name: the second of two writes at the same moment answered $second, not stale with the first's row" >&2; exit 1; }
  echo "ok: $name: two first writes at the same moment: the second is stale, with the first's row"
done

run -f "$TMP/rollback.sql" >/dev/null
run -f "$HERE/after-rollback.sql" 2>&1 | notices
pg_ctl -D "$TMP/data" stop -m fast >/dev/null

# Only the first migration applied (the second failed or was never run): the same rollback, the same checks.
start data2
migrate $(ls "$REPO"/supabase/migrations/*.sql | grep -v '_obligation_sweep\.sql$')
run -q -c "insert into auth.users values ('00000000-0000-0000-0000-00000000000a'); insert into public.app_admins (user_id) values ('00000000-0000-0000-0000-00000000000a');"
PGOPTIONS='-c client_min_messages=warning' run -f "$TMP/rollback.sql" >/dev/null
echo "ok: the rollback runs after only 20261019090000_desk_sync.sql"
run -f "$HERE/after-rollback.sql" 2>&1 | notices
