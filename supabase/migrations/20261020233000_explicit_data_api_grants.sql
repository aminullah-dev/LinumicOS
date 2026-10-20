-- Explicit Data API grants for every table in `public`, and for the sequences behind their identity columns.
--
-- Why: Supabase changes a default on 2026-10-30 (https://github.com/orgs/supabase/discussions/45329 and
-- https://supabase.com/docs/guides/api/securing-your-api, "Default privileges for new tables and functions"). Until
-- then the default privileges of the role postgres grant every new table and sequence in `public` to anon,
-- authenticated and service_role. From that date a new table gets no Data API grant unless a migration gives it one.
-- The live tables keep their grants. But anything that replays these migrations (a new project, a preview branch, a
-- local reset, a rebuild after a disaster) would build the tables without them, and the API would answer "permission
-- denied" (42501). The app's security-invoker RPCs (export_inventory, import_inventory, export_licences,
-- upsert_licences, export_oversight, upsert_oversight, sentinel_overview, sentinel_recent_events, desk_sync_pull) read
-- and write these tables as `authenticated`, so they would fail too.
--
-- What: exactly the grants the live project (mczuclgfqxffcbiwvecf) holds. They were read on 2026-10-20 from
-- information_schema.role_table_grants and pg_class.relacl. Nothing is widened or narrowed, so on the live project
-- every statement below changes nothing, and running the file again changes nothing either. Each table is named here,
-- with no "on all tables", so that a table added later never gets a grant by accident.
--
-- The rule from here on: a migration that creates a table in `public` grants it, and revokes what it must not have,
-- in the same file. tools/supabase/check_migration_grants.py fails CI otherwise (docs/security.md). The tables
-- created before this file are covered by this file; supabase/tests/grants/ checks the result of a replay.
--
-- Whether to tighten the anon grants below is a separate decision for the owner. RLS gives anon no policy on any of
-- these tables, so today anon reaches no row through them.

-- MARK: Admin-managed tables (RLS: admins only). All privileges for anon, authenticated and service_role.

grant all on table
  public.app_admins,
  public.audit_events,
  public.content_items,
  public.deployments,
  public.inventory_meta,
  public.issues,
  public.licences,
  public.market_evidence,
  public.market_finding_evidence,
  public.market_findings,
  public.market_sources,
  public.oversight_repos,
  public.platforms,
  public.products,
  public.releases,
  public.repositories,
  public.roadmap_items,
  public.store_listings,
  public.unresolved_items
to anon, authenticated, service_role;

-- MARK: Sentinel tables (20261018090000_sentinel.sql). anon and authenticated read only. Only the service role and
-- the security-definer functions write.

grant all on table
  public.inventory_snapshots,
  public.sentinel_checks,
  public.sentinel_events,
  public.sentinel_rounds,
  public.sentinel_target_state
to service_role;

grant select, references, trigger on table
  public.inventory_snapshots,
  public.sentinel_checks,
  public.sentinel_events,
  public.sentinel_rounds,
  public.sentinel_target_state
to anon, authenticated;

revoke insert, update, delete, truncate on table
  public.inventory_snapshots,
  public.sentinel_checks,
  public.sentinel_events,
  public.sentinel_rounds,
  public.sentinel_target_state
from anon, authenticated;

-- MARK: Desk sync tables (20261019090000_desk_sync.sql). authenticated reads only. anon has nothing. Writes go
-- through the push RPCs (security definer).

grant all on table
  public.desk_items,
  public.desk_ledger_reading,
  public.desk_state,
  public.obligations,
  public.vendors
to service_role;

grant select, references, trigger on table
  public.desk_items,
  public.desk_ledger_reading,
  public.desk_state,
  public.obligations,
  public.vendors
to authenticated;

revoke insert, update, delete, truncate on table
  public.desk_items,
  public.desk_ledger_reading,
  public.desk_state,
  public.obligations,
  public.vendors
from authenticated;

revoke all on table
  public.desk_items,
  public.desk_ledger_reading,
  public.desk_state,
  public.obligations,
  public.vendors
from anon;

-- MAINTAIN (VACUUM, ANALYZE, LOCK and the like) exists from Postgres 17, and the live project runs 17. Live holds it
-- wherever a role has SELECT through the old defaults. "grant all" above already includes it on 17. The Data API can't
-- use it. Postgres 16 has no MAINTAIN, so the grant is skipped there.
do $$
begin
  if current_setting('server_version_num')::int >= 170000 then
    execute 'grant maintain on table public.inventory_snapshots, public.sentinel_checks, public.sentinel_events, '
         || 'public.sentinel_rounds, public.sentinel_target_state to anon, authenticated';
    execute 'grant maintain on table public.desk_items, public.desk_ledger_reading, public.desk_state, '
         || 'public.obligations, public.vendors to authenticated';
  end if;
end $$;

-- MARK: Sequences of the identity columns. An insert into an identity column needs no grant on its sequence. These
-- grants only copy what live holds (SELECT, UPDATE, USAGE through the old defaults).

grant select, update, usage on sequence
  public.audit_events_id_seq,
  public.inventory_snapshots_id_seq,
  public.sentinel_checks_id_seq,
  public.sentinel_events_id_seq,
  public.sentinel_rounds_id_seq
to anon, authenticated, service_role;
