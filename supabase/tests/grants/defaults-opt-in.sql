-- Supabase's default from 2026-10-30: the old defaults, then the statements Supabase publishes to opt in early
-- (https://supabase.com/docs/guides/api/securing-your-api, "Default privileges for new tables and functions").
-- They leave TRUNCATE, REFERENCES, TRIGGER (and MAINTAIN on Postgres 17) in the table defaults, and UPDATE in the
-- sequence defaults. The last statement changes nothing: PUBLIC's EXECUTE is Postgres's own default, which a
-- per-schema revoke can't remove.
\ir defaults-old.sql
alter default privileges for role postgres in schema public
  revoke select, insert, update, delete on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke usage, select on sequences from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke execute on functions from public;
