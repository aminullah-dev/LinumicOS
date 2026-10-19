#!/bin/bash
# Runs every migration on a throwaway local Postgres (16+) with the Sentinel suite's stand-ins for Supabase's auth,
# Vault, pg_cron and pg_net (../sentinel/stubs.sql), then the Desk sync behaviour checks (behaviour.sql), then the
# rollback exactly as docs/desk-sync.md prints it (its first sql block under "## Rollback") and what it must leave
# (after-rollback.sql). Nothing touches the live project.
#
#   supabase/tests/desk-sync/run.sh           # from the repository root; needs initdb, pg_ctl and psql on PATH
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
PORT=${DESK_SYNC_TEST_PORT:-54331}
TMP=$(mktemp -d)
trap 'pg_ctl -D "$TMP/data" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

initdb -D "$TMP/data" -U postgres --auth=trust >/dev/null
pg_ctl -D "$TMP/data" -o "-p $PORT -c unix_socket_directories='' -c listen_addresses=127.0.0.1" -l "$TMP/log" start >/dev/null
run() { psql -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"; }

run -f "$REPO/supabase/tests/sentinel/stubs.sql"
for f in "$REPO"/supabase/migrations/*.sql; do
  # pg_cron and pg_net are stubbed.
  grep -v '^create extension' "$f" > "$TMP/migration.sql"
  run -f "$TMP/migration.sql"
done >/dev/null
fixture="$REPO/Packages/LinumicCore/Tests/LinumicCoreTests/Fixtures/desk-sync-sweep.json"
run -v fixture="$(cat "$fixture")" -f "$HERE/behaviour.sql" 2>&1 | sed -n 's/.*NOTICE: *//p; /ERROR/p; /PASSED/p'
awk '/^## Rollback/ { on = 1 } on && /^```sql/ { inside = 1; next } inside && /^```/ { exit } inside' \
  "$REPO/docs/desk-sync.md" > "$TMP/rollback.sql"
[[ -s "$TMP/rollback.sql" ]] || { echo "No rollback SQL found in docs/desk-sync.md" >&2; exit 1; }
run -f "$TMP/rollback.sql" >/dev/null
run -f "$HERE/after-rollback.sql" 2>&1 | sed -n 's/.*NOTICE: *//p; /ERROR/p; /PASSED/p'
