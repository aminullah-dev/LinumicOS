-- The Data API grants every table and sequence in `public` must end with: the live project's grants, read on
-- 2026-10-20 from information_schema.role_table_grants and pg_class.relacl, and restated by
-- supabase/migrations/20261020233000_explicit_data_api_grants.sql. A table added later belongs here too.
--
--   full  every table privilege this Postgres knows (SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER,
--         and MAINTAIN from Postgres 17)
--   read  SELECT, REFERENCES, TRIGGER (and MAINTAIN from Postgres 17)
--   seq   SELECT, UPDATE, USAGE on a sequence
--   none  nothing
--
-- Run by run.sh with -v expect=match (fails on any difference) or -v expect=mismatch (prints how many grants differ,
-- and fails when nothing does: proof that the check can fail).
\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on

create temp table expected (relname text primary key, anon text, authenticated text, service_role text);
insert into expected values
  -- Admin-managed tables (RLS: admins only).
  ('app_admins', 'full', 'full', 'full'),
  ('audit_events', 'full', 'full', 'full'),
  ('content_items', 'full', 'full', 'full'),
  ('deployments', 'full', 'full', 'full'),
  ('inventory_meta', 'full', 'full', 'full'),
  ('issues', 'full', 'full', 'full'),
  ('licences', 'full', 'full', 'full'),
  ('market_evidence', 'full', 'full', 'full'),
  ('market_finding_evidence', 'full', 'full', 'full'),
  ('market_findings', 'full', 'full', 'full'),
  ('market_sources', 'full', 'full', 'full'),
  ('oversight_repos', 'full', 'full', 'full'),
  ('platforms', 'full', 'full', 'full'),
  ('products', 'full', 'full', 'full'),
  ('releases', 'full', 'full', 'full'),
  ('repositories', 'full', 'full', 'full'),
  ('roadmap_items', 'full', 'full', 'full'),
  ('store_listings', 'full', 'full', 'full'),
  ('unresolved_items', 'full', 'full', 'full'),
  -- Sentinel: anon and authenticated read only.
  ('inventory_snapshots', 'read', 'read', 'full'),
  ('sentinel_checks', 'read', 'read', 'full'),
  ('sentinel_events', 'read', 'read', 'full'),
  ('sentinel_rounds', 'read', 'read', 'full'),
  ('sentinel_target_state', 'read', 'read', 'full'),
  -- Desk sync: authenticated reads only, no anon.
  ('desk_items', 'none', 'read', 'full'),
  ('desk_ledger_reading', 'none', 'read', 'full'),
  ('desk_state', 'none', 'read', 'full'),
  ('obligations', 'none', 'read', 'full'),
  ('vendors', 'none', 'read', 'full'),
  -- Sequences of the identity columns.
  ('audit_events_id_seq', 'seq', 'seq', 'seq'),
  ('inventory_snapshots_id_seq', 'seq', 'seq', 'seq'),
  ('sentinel_checks_id_seq', 'seq', 'seq', 'seq'),
  ('sentinel_events_id_seq', 'seq', 'seq', 'seq'),
  ('sentinel_rounds_id_seq', 'seq', 'seq', 'seq');

create temp table levels (level text, privilege text);
insert into levels
select 'full', p from unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p
union all select 'read', p from unnest(array['SELECT', 'REFERENCES', 'TRIGGER']) p
union all select l, 'MAINTAIN' from unnest(array['full', 'read']) l where current_setting('server_version_num')::int >= 170000
union all select 'seq', p from unnest(array['SELECT', 'UPDATE', 'USAGE']) p;

-- What each relation in `public` grants to PUBLIC and the three API roles.
create temp view actual as
select c.relname, c.relkind, case a.grantee when 0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end as role,
       a.privilege_type as privilege
from pg_class c
cross join lateral aclexplode(c.relacl) a
where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'S', 'f')
  and (a.grantee = 0 or pg_get_userbyid(a.grantee) in ('anon', 'authenticated', 'service_role'));

create temp view wanted as
select e.relname, r.role, l.privilege
from expected e
cross join lateral (values ('anon', e.anon), ('authenticated', e.authenticated), ('service_role', e.service_role)) r(role, level)
join levels l on l.level = r.level;

create temp view differences as
select format('%s: %s lacks %s', relname, role, privilege) as difference
from (select relname, role, privilege from wanted except select relname, role, privilege from actual) missing
union all
select format('%s: %s has %s, which live does not', relname, role, privilege)
from (select relname, role, privilege from actual except select relname, role, privilege from wanted) extra
union all
select format('%s is in public but not in the expected grants (add it here and grant it in its migration)', c.relname)
from pg_class c
where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'S', 'f')
  and c.relname not in (select relname from expected)
union all
select format('%s is expected but not in public', e.relname)
from expected e
where not exists (select 1 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname = e.relname);

select set_config('grants.expect', :'expect', false) \g /dev/null
do $$
declare
  n int := (select count(*) from differences);
  shown text := (select string_agg(difference, E'\n  ' order by difference) from (select difference from differences order by 1 limit 20) d);
  tables int := (select count(*) from expected where anon <> 'seq');
  sequences int := (select count(*) from expected where anon = 'seq');
begin
  if current_setting('grants.expect') = 'match' then
    if n > 0 then
      raise exception E'FAIL: % grant(s) differ from the live matrix:\n  %', n, shown;
    end if;
    raise notice 'ok: % tables and % sequences in public have exactly the live grants (Postgres %)',
      tables, sequences, current_setting('server_version');
  else
    if n = 0 then
      raise exception 'FAIL: expected missing grants, found none (the check could not fail)';
    end if;
    raise notice 'ok: % grant(s) differ, as expected, for example: %', n, (select min(difference) from differences);
  end if;
end $$;
