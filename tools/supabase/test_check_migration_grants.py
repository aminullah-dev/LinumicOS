#!/usr/bin/env python3
"""Tests for check_migration_grants.py, with mutations that prove it fires.

Each test copies the repository's migrations (or none) to a temporary folder, changes or adds one file, and runs the
check there. Nothing in supabase/migrations is changed.

    python3 tools/supabase/test_check_migration_grants.py        # from the repository root
"""
import contextlib, importlib.util, io, os, shutil, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
spec = importlib.util.spec_from_file_location("check_migration_grants", os.path.join(HERE, "check_migration_grants.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
MIGRATIONS = os.path.join(REPO, guard.MIGRATIONS)
LATER = "20991231000000_later.sql"  # a migration after the baseline


class Guard(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        for f in os.listdir(MIGRATIONS):
            shutil.copy(os.path.join(MIGRATIONS, f), self.dir)

    def write(self, name, sql):
        with open(os.path.join(self.dir, name), "w") as f:
            f.write(sql)

    def edit(self, name, old, new):
        path = os.path.join(self.dir, name)
        with open(path) as f:
            text = f.read()
        self.assertEqual(text.count(old), 1, old)
        with open(path, "w") as f:
            f.write(text.replace(old, new))

    def problems(self):
        return guard.check(self.dir)[0]

    def assertFires(self, *needles):
        problems = self.problems()
        self.assertTrue(problems, "the check passed but should have failed")
        text = "\n".join(problems)
        for needle in needles:
            self.assertIn(needle, text)

    def assertPasses(self):
        self.assertEqual(self.problems(), [])

    # MARK: the repository as it is

    def test_the_repository_passes(self):
        self.assertPasses()
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(guard.main(["--dir", MIGRATIONS]), 0)
        self.assertIn("0 problems", out.getvalue())

    def test_every_table_before_the_baseline_is_in_the_baseline(self):
        problems, migrations = guard.check(MIGRATIONS)
        baseline = next(m for m in migrations if m.name == guard.BASELINE)
        created = {name for m in migrations if m.name < guard.BASELINE for _, name, _ in m.created}
        self.assertEqual(len(created), 29)
        self.assertEqual(created - {name for kind, name in baseline.granted if kind == "table"}, set())

    # MARK: mutations of the repository's own files

    def test_a_table_dropped_from_the_baseline_fires(self):
        self.edit(guard.BASELINE, "  public.vendors\nto service_role;", "  public.desk_state\nto service_role;")
        self.edit(guard.BASELINE, "  public.vendors\nto authenticated;", "  public.desk_state\nto authenticated;")
        self.assertFires("20261019090000_desk_sync.sql:194: table public.vendors is created without a Data API GRANT")

    def test_a_missing_baseline_fires(self):
        os.remove(os.path.join(self.dir, guard.BASELINE))
        self.assertFires(f"{guard.BASELINE}: missing", "table public.app_admins is created without")

    def test_a_new_table_in_an_old_migration_fires(self):
        self.edit("20261018090000_sentinel.sql", "create table public.inventory_snapshots (",
                  "create table public.sentinel_notes (id int primary key);\ncreate table public.inventory_snapshots (")
        self.assertFires("table public.sentinel_notes is created without a Data API GRANT")

    # MARK: a later migration

    def test_a_new_table_without_a_grant_fires(self):
        self.write(LATER, "create table public.notes (id int primary key);\nalter table public.notes enable row level security;\n")
        self.assertFires(f"{LATER}:1: table public.notes is created without a Data API GRANT")
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(guard.main(["--dir", self.dir]), 1)
        self.assertIn("1 problem\n", out.getvalue())

    def test_a_new_table_with_a_grant_passes(self):
        self.write(LATER, "create table public.notes (id int primary key);\n"
                          "grant select, insert on table public.notes to authenticated;\n"
                          "revoke all on table public.notes from anon;\n")
        self.assertPasses()

    def test_unqualified_quoted_and_if_not_exists_names_count_as_public(self):
        self.write(LATER, 'create table if not exists notes (id int);\ncreate table "public"."Odd" (id int);\n')
        self.assertFires("table public.notes is created", "table public.Odd is created")
        self.write(LATER, 'create table if not exists notes (id int);\ncreate table "public"."Odd" (id int);\n'
                          'grant select on notes, "Odd" to authenticated;\n')
        self.assertPasses()

    def test_a_grant_only_in_a_comment_or_to_another_role_fires(self):
        self.write(LATER, "create table public.notes (id int);\n-- grant select on public.notes to authenticated;\n"
                          "/* grant select on public.notes to anon; */\ngrant select on public.notes to postgres;\n")
        self.assertFires("table public.notes is created without")

    def test_a_grant_in_another_migration_fires(self):
        self.write(LATER, "create table public.notes (id int);\n")
        self.write("20991231000001_grant.sql", "grant select on public.notes to authenticated;\n")
        self.assertFires(f"{LATER}:1: table public.notes")

    def test_a_grant_on_another_table_fires(self):
        self.write(LATER, "create table public.notes (id int);\ngrant select on public.note to authenticated;\n")
        self.assertFires("table public.notes is created without")

    def test_a_view_and_a_sequence_need_grants(self):
        self.write(LATER, "create or replace view public.open_issues as select 1 as one;\n"
                          "create materialized view public.counts as select 1 as one;\ncreate sequence public.ticket_no;\n")
        self.assertFires("view public.open_issues", "view public.counts", "sequence public.ticket_no")
        self.write(LATER, "create or replace view public.open_issues as select 1 as one;\n"
                          "create materialized view public.counts as select 1 as one;\ncreate sequence public.ticket_no;\n"
                          "grant select on public.open_issues, public.counts to authenticated;\n"
                          "grant usage on sequence public.ticket_no to authenticated;\n")
        self.assertPasses()

    def test_a_serial_column_needs_a_grant_on_its_sequence(self):
        self.write(LATER, "create table public.notes (\n  id bigserial primary key,\n  body text\n);\n"
                          "grant select, insert on public.notes to authenticated;\n")
        self.assertFires("sequence public.notes_id_seq")
        self.write(LATER, "create table public.notes (\n  id bigserial primary key,\n  body text\n);\n"
                          "grant select, insert on public.notes to authenticated;\n"
                          "grant usage on sequence public.notes_id_seq to authenticated;\n")
        self.assertPasses()

    def test_an_identity_column_needs_no_sequence_grant(self):
        self.write(LATER, "create table public.notes (id bigint generated always as identity primary key);\n"
                          "grant select, insert on public.notes to authenticated;\n")
        self.assertPasses()

    def test_a_table_moved_into_public_needs_a_grant(self):
        self.write(LATER, "create table private.notes (id int);\nalter table private.notes set schema public;\n")
        self.assertFires("table public.notes is created without")

    def test_temporary_and_other_schemas_are_not_checked(self):
        self.write(LATER, "create temp table scratch (id int);\ncreate table private.notes (id int);\n"
                          "create table if not exists extensions.x (id int);\n")
        self.assertPasses()

    def test_a_table_created_at_run_time_fires(self):
        self.write(LATER, "do $$ begin execute format('create table public.%I (id int)', 'notes'); end $$;\n")
        self.assertFires("a table is created with a name built at run time")

    # MARK: revoke-only intent

    def test_revoke_only_needs_both_the_marker_and_the_revoke(self):
        table = "create table public.outbox (id int);\n"
        revoke = "revoke all on table public.outbox from anon, authenticated;\n"
        marker = "-- data-api: revoke-only public.outbox: written and read only by security-definer functions\n"
        self.write(LATER, table + revoke + marker)
        self.assertPasses()
        self.write(LATER, table + "revoke all on public.outbox from anon;\nrevoke all on public.outbox from authenticated;\n" + marker)
        self.assertPasses()
        self.write(LATER, table + revoke)
        self.assertFires("table public.outbox is created without")
        self.write(LATER, table + marker)
        self.assertFires("marked revoke-only but the migration has no REVOKE")
        self.write(LATER, table + "revoke all on public.outbox from anon;\n" + marker)
        self.assertFires("marked revoke-only but the migration has no REVOKE")
        self.write(LATER, table + revoke + "-- data-api: revoke-only public.outbox\n")
        self.assertFires("unreadable marker")
        self.write(LATER, table + revoke + marker + "-- data-api: revoke-only public.inbox: not created here\n")
        self.assertFires("marker for public.inbox, which this migration doesn't create")

    # MARK: grants that reach tables nobody listed

    def test_automatic_or_schema_wide_grants_fire(self):
        self.write(LATER, "alter default privileges for role postgres in schema public grant all on tables to anon;\n")
        self.assertFires("alter default privileges ... grant")
        self.write(LATER, "alter default privileges grant execute on functions to anon;\n")
        self.assertFires("alter default privileges ... grant")
        self.write(LATER, "grant select on all tables in schema public to anon;\n")
        self.assertFires("grant ... on all tables in schema public")
        self.write(LATER, "create table public.notes (id int);\ngrant select on all tables in schema public to anon;\n")
        self.assertFires("table public.notes is created without")

    def test_revoking_defaults_and_other_schemas_pass(self):
        self.write(LATER, "alter default privileges for role postgres in schema public "
                          "revoke select, insert, update, delete on tables from anon, authenticated, service_role;\n"
                          "alter default privileges in schema private grant all on tables to service_role;\n"
                          "grant select on all tables in schema private to service_role;\n")
        self.assertPasses()


if __name__ == "__main__":
    unittest.main(verbosity=1)
