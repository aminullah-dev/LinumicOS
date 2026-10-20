-- Minimal stand-ins for what Supabase provides, so the repo's migrations run on plain Postgres 16.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create role supabase_admin nologin;
grant anon, authenticated, service_role to postgres;
create schema extensions;
create extension pgcrypto with schema extensions;
create extension "uuid-ossp" with schema extensions;
create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
-- Supabase's default privileges in `public` are in ../grants/defaults-<SUPABASE_DEFAULTS>.sql (old, opt-in or none).
-- Vault
create schema vault;
create table vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, secret text, description text);
create view vault.decrypted_secrets as select id, name, secret as decrypted_secret, description from vault.secrets;
create function vault.create_secret(new_secret text, new_name text, new_description text default '') returns uuid
language sql as $$ insert into vault.secrets (name, secret, description) values (new_name, new_secret, new_description) returning id $$;
-- pg_cron / pg_net
-- pg_cron keys a named job by (jobname, username): cron.schedule replaces only a job of the same name owned by the role
-- running it, and cron.unschedule(name) removes only that role's job.
create schema cron;
create table cron.job (jobid bigint generated always as identity primary key, schedule text, command text,
                       jobname text, username text not null default current_user, active boolean not null default true,
                       unique (jobname, username));
create function cron.schedule(job_name text, schedule text, command text) returns bigint language sql as $$
  insert into cron.job (jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname, username) do update set schedule = excluded.schedule, command = excluded.command
  returning jobid $$;
create function cron.unschedule(job_name text) returns boolean language sql as $$
  delete from cron.job where jobname = job_name and username = current_user returning true $$;
create function cron.unschedule(job_id bigint) returns boolean language sql as $$
  delete from cron.job where jobid = job_id returning true $$;
create schema net;
create table net.requests (id bigint generated always as identity primary key, url text, body jsonb, headers jsonb);
create function net.http_post(url text, body jsonb default '{}', params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000)
returns bigint language sql as $$ insert into net.requests (url, body, headers) values (url, body, headers) returning id $$;
