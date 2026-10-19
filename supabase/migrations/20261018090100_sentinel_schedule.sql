-- Sentinel schedule: pg_cron runs the jobs, pg_net calls the `sentinel` Edge Function, Vault holds the shared secret.
-- Depends on 20261018090000_sentinel.sql. Rollback: docs/sentinel.md.
--
-- The secret is generated here and never leaves the database: the Edge Function does not store a copy, it asks
-- sentinel_secret_ok() (service role only) whether the header it received matches.

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- The shared secret and the function URL, created once (re-running this file keeps the existing values).
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'sentinel_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'sentinel_secret',
                                'Shared secret between pg_cron and the sentinel Edge Function (x-sentinel-secret).');
  end if;
  if not exists (select 1 from vault.secrets where name = 'sentinel_function_url') then
    -- The live project. A local stack points it elsewhere with vault.update_secret (docs/sentinel.md).
    perform vault.create_secret('https://mczuclgfqxffcbiwvecf.supabase.co/functions/v1/sentinel', 'sentinel_function_url',
                                'Where pg_cron sends the sentinel round request.');
  end if;
end $$;

-- True when `candidate` is the shared secret. Called by the Edge Function with the service role key.
create or replace function public.sentinel_secret_ok(candidate text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select candidate is not null and length(candidate) >= 32 and exists (
    select 1 from vault.decrypted_secrets where name = 'sentinel_secret' and decrypted_secret = candidate)
$$;
revoke execute on function public.sentinel_secret_ok(text) from public, anon, authenticated;
grant execute on function public.sentinel_secret_ok(text) to service_role;

-- Asks the Edge Function for one round (asynchronous: pg_net sends it after the transaction commits).
create or replace function private.sentinel_invoke(source text default 'cron')
returns bigint language plpgsql volatile security definer set search_path = ''
as $$
declare
  fn_url text;
  secret text;
begin
  select decrypted_secret into fn_url from vault.decrypted_secrets where name = 'sentinel_function_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'sentinel_secret';
  if fn_url is null or secret is null then
    raise exception 'sentinel: Vault secrets sentinel_function_url / sentinel_secret are missing';
  end if;
  return net.http_post(
    url := fn_url,
    body := jsonb_build_object('source', source),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sentinel-secret', secret),
    timeout_milliseconds := 60000);
end $$;
revoke execute on function private.sentinel_invoke(text) from public, anon, authenticated;

-- "Check now" from the app: one manual round, at most one request every 2 minutes.
create table if not exists private.sentinel_manual_requests (
  id bigint generated always as identity primary key,
  requested_at timestamptz not null default now(),
  requested_by uuid
);
revoke all on private.sentinel_manual_requests from public, anon, authenticated;

create or replace function public.request_sentinel_round()
returns boolean language plpgsql volatile security definer set search_path = ''
as $$
begin
  -- Not assert_admin(): inside a security-definer function current_user is the owner, which it would accept.
  if not coalesce(private.is_admin(), false) then
    raise exception 'Not authorised: Linumic OS admins only' using errcode = '42501';
  end if;
  if exists (select 1 from private.sentinel_manual_requests where requested_at > now() - interval '2 minutes') then
    return false;
  end if;
  insert into private.sentinel_manual_requests (requested_by) values ((select auth.uid()));
  delete from private.sentinel_manual_requests where requested_at < now() - interval '14 days';
  perform private.sentinel_invoke('manual');
  return true;
end $$;
revoke execute on function public.request_sentinel_round() from public, anon;
grant execute on function public.request_sentinel_round() to authenticated;

-- The jobs (cron.schedule replaces a job of the same name, so re-running is safe). Times are UTC.
select cron.schedule('sentinel-round', '*/10 * * * *', $$select private.sentinel_invoke('cron')$$);
-- 06:15 UTC = 10:45 in Kabul.
select cron.schedule('sentinel-licences', '15 6 * * *', $$select private.sentinel_licence_sweep()$$);
-- Sundays 02:30 UTC.
select cron.schedule('sentinel-snapshot', '30 2 * * 0', $$select private.take_inventory_snapshot()$$);
select cron.schedule('sentinel-prune', '45 3 * * *', $$select private.sentinel_prune()$$);
