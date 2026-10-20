-- Supabase's default privileges in `public` before 2026-10-30, as the live project has them (pg_default_acl, read
-- 2026-10-20): every table, sequence and function the role postgres creates there is granted to anon, authenticated
-- and service_role. Loaded after ../sentinel/stubs.sql when SUPABASE_DEFAULTS is old (the default).
alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role;
