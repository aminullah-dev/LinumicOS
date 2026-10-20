#!/bin/bash
# Runs every migration on a throwaway local Postgres (16+) with stand-ins for Supabase's auth, Vault, pg_cron and
# pg_net (stubs.sql), then the Sentinel behaviour checks (behaviour.sql). Nothing touches the live project.
# SUPABASE_DEFAULTS picks Supabase's default privileges in `public` (../grants/defaults-*.sql): old (the live project
# before 2026-10-30, the default), opt-in (from 2026-10-30) or none (no automatic grant).
#
#   supabase/tests/sentinel/run.sh                           # from the repository root; needs initdb, pg_ctl and psql
#   SUPABASE_DEFAULTS=none supabase/tests/sentinel/run.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
PORT=${SENTINEL_TEST_PORT:-54329}
DEFAULTS="$REPO/supabase/tests/grants/defaults-${SUPABASE_DEFAULTS:-old}.sql"
[[ -f "$DEFAULTS" ]] || { echo "SUPABASE_DEFAULTS must be old, opt-in or none" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'pg_ctl -D "$TMP/data" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

initdb -D "$TMP/data" -U postgres --auth=trust >/dev/null
pg_ctl -D "$TMP/data" -o "-p $PORT -c unix_socket_directories='' -c listen_addresses=127.0.0.1" -l "$TMP/log" start >/dev/null
run() { psql -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"; }

run -f "$HERE/stubs.sql"
run -f "$DEFAULTS"
for f in "$REPO"/supabase/migrations/*.sql; do
  if [[ "$f" == *_sentinel_schedule.sql ]]; then
    # pg_cron and pg_net are stubbed; behaviour.sql re-runs this copy to prove the file is re-runnable.
    grep -v '^create extension' "$f" > "$HERE/schedule.sql"
    run -f "$HERE/schedule.sql"
  else
    run -f "$f"
  fi
done >/dev/null
run -f "$HERE/behaviour.sql" 2>&1 | sed -n 's/.*NOTICE: *//p; /ERROR/p; /PASSED/p'
rm -f "$HERE/schedule.sql"
