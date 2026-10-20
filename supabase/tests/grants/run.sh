#!/bin/bash
# Replays every migration on a throwaway local Postgres (16+), once for each of Supabase's default-privilege settings
# in `public` (defaults-*.sql), and checks that every table and sequence there ends with exactly the live project's
# Data API grants (matrix.sql):
#   old     the live project until 2026-10-30: every new table, sequence and function goes to anon, authenticated and
#           service_role;
#   opt-in  Supabase's default from 2026-10-30, by the statements Supabase publishes;
#   none    no automatic grant at all.
# It also checks four things. Under old (built like the live project) the state already matches before the grants
# migration, and the migration changes no ACL. Running it again changes nothing. Under opt-in and none, without it,
# grants are missing (so this check can fail). Last, the Sentinel and Desk sync behaviour suites run under none.
# Nothing touches the live project.
#
#   supabase/tests/grants/run.sh              # from the repository root; needs initdb, pg_ctl and psql on PATH
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
PORT=${GRANTS_TEST_PORT:-54333}
TMP=$(mktemp -d)
trap 'pg_ctl -D "$TMP/data" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
GRANTS=$(ls "$REPO"/supabase/migrations/*_explicit_data_api_grants.sql)

run() { psql -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"; }
notices() { sed -n 's/.*NOTICE: *//p; /ERROR/,$p'; }
start() {
  rm -rf "$TMP/data"
  initdb -D "$TMP/data" -U postgres --auth=trust >/dev/null
  pg_ctl -D "$TMP/data" -o "-p $PORT -c unix_socket_directories='' -c listen_addresses=127.0.0.1" -l "$TMP/log" start >/dev/null
  run -f "$REPO/supabase/tests/sentinel/stubs.sql"
  run -f "$HERE/defaults-$1.sql"
}
stop() { pg_ctl -D "$TMP/data" stop -m fast >/dev/null; }
migrate() {
  for f in "$@"; do
    # pg_cron and pg_net are stubbed.
    grep -v '^create extension' "$f" > "$TMP/migration.sql"
    run -f "$TMP/migration.sql"
  done >/dev/null
}
before_grants() { ls "$REPO"/supabase/migrations/*.sql | awk -v g="$GRANTS" '$0 < g'; }
after_grants() { ls "$REPO"/supabase/migrations/*.sql | awk -v g="$GRANTS" '$0 > g'; }
matrix() { run -v expect="$1" -f "$HERE/matrix.sql" 2>&1 | notices; }
# Every ACL in `public` (tables, views, sequences, functions), to compare before and after.
acls() {
  run -At -c "select string_agg(format('%s %s %s', c.relkind, c.relname, coalesce(c.relacl::text, '-')), E'\n' order by c.relname)
              from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'S', 'f')
              union all
              select string_agg(format('f %s %s', p.oid::regprocedure, coalesce(p.proacl::text, '-')), E'\n' order by p.oid::regprocedure::text)
              from pg_proc p where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)"
}

for mode in old opt-in none; do
  echo "== Supabase defaults: $mode"
  start "$mode"
  migrate $(before_grants)
  if [[ $mode == old ]]; then
    echo "  before the grants migration:"
    matrix match | sed 's/^/  /'
  else
    echo "  without the grants migration:"
    matrix mismatch | sed 's/^/  /'
  fi
  acls > "$TMP/before"
  migrate "$GRANTS"
  acls > "$TMP/after"
  if [[ $mode == old ]]; then
    diff -u "$TMP/before" "$TMP/after" >&2 || { echo "FAIL: the grants migration changed an ACL on a database built like the live one" >&2; exit 1; }
    echo "  ok: the grants migration changes no ACL on a database built like the live one"
  fi
  migrate "$GRANTS"
  acls > "$TMP/again"
  diff -u "$TMP/after" "$TMP/again" >&2 || { echo "FAIL: running the grants migration again changed an ACL" >&2; exit 1; }
  echo "  ok: running it again changes nothing"
  migrate $(after_grants)
  matrix match | sed 's/^/  /'
  stop
done

echo "== The Sentinel and Desk sync behaviour suites under none"
SUPABASE_DEFAULTS=none "$REPO/supabase/tests/sentinel/run.sh" | grep PASSED
SUPABASE_DEFAULTS=none "$REPO/supabase/tests/desk-sync/run.sh" | grep PASSED
echo "ALL GRANTS CHECKS PASSED"
