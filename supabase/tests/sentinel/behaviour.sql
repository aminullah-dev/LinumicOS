-- Sentinel behaviour checks, run by run.sh on a throwaway database. TEST DATA only (made-up rounds and licences).
\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on

create function pg_temp.check(ok boolean, label text) returns void language plpgsql as $$
begin
  if not ok then raise exception 'FAIL: %', label; end if;
  raise notice 'ok: %', label;
end $$;

insert into auth.users values ('00000000-0000-0000-0000-00000000000a'), ('00000000-0000-0000-0000-00000000000b');
insert into public.app_admins (user_id) values ('00000000-0000-0000-0000-00000000000a');

-- MARK: rounds and state changes (as the Edge Function: service_role)
set role service_role;
create function pg_temp.round(minute int, a text, b text) returns jsonb language sql as $$
  select public.sentinel_record_round(jsonb_build_object('source', 'cron',
    'startedAt', '2026-10-18T09:00:00Z'::timestamptz + make_interval(mins => minute),
    'finishedAt', '2026-10-18T09:00:05Z'::timestamptz + make_interval(mins => minute),
    'checks', jsonb_build_array(
      jsonb_build_object('targetID', 'velro.api.live', 'product', 'velro',
        'checkedAt', '2026-10-18T09:00:00Z'::timestamptz + make_interval(mins => minute), 'state', a,
        'statusCode', case when a = 'down' then 503 else 200 end, 'latencyMS', 120, 'healthStatus', 'alive',
        'reason', case when a = 'down' then 'httpStatus' end, 'failure', null),
      jsonb_build_object('targetID', 'website.home', 'product', 'website',
        'checkedAt', '2026-10-18T09:00:00Z'::timestamptz + make_interval(mins => minute), 'state', b,
        'statusCode', null, 'latencyMS', null, 'reason', case when b = 'down' then 'transport' end,
        'failure', case when b = 'down' then 'TimeoutError: timed out' end))))
$$;
select pg_temp.check((pg_temp.round(0, 'up', 'down')->>'events')::int = 0, 'round 1: no events (A up first sight, B one failure)');
select pg_temp.check((select state from public.sentinel_target_state where target_id = 'website.home') = 'unknown', 'one failure keeps unknown');
select pg_temp.check((pg_temp.round(10, 'down', 'down')->>'events')::int = 1, 'round 2: B down after 2 failures');
select pg_temp.check((pg_temp.round(20, 'down', 'down')->>'events')::int = 1, 'round 3: A down after 2 failures, B no repeat');
select pg_temp.check((pg_temp.round(30, 'down', 'degraded')->>'events')::int = 1, 'round 4: B recovered (degraded is available)');
select pg_temp.check((pg_temp.round(40, 'degraded', 'up')->>'events')::int = 1, 'round 5: A recovered');
select pg_temp.check((pg_temp.round(50, 'up', 'up')->>'events')::int = 0, 'round 6: nothing changed');
select pg_temp.check((select count(*) from public.sentinel_events) = 4, '4 events in total');
select pg_temp.check((select string_agg(kind || ':' || subject, ',' order by id) from public.sentinel_events)
  = 'targetDown:website.home,targetDown:velro.api.live,targetRecovered:website.home,targetRecovered:velro.api.live', 'event order');
select pg_temp.check((select count(*) from public.sentinel_checks) = 12 and (select count(*) from public.sentinel_rounds) = 6, 'rows');
select pg_temp.check((select since from public.sentinel_target_state where target_id = 'velro.api.live') = '2026-10-18T09:40:00Z', 'since = recovery time');
reset role;

-- MARK: API roles
set role anon;
do $$ begin
  perform public.sentinel_record_round('{"checks":[]}');
  raise exception 'FAIL: anon recorded a round';
exception when insufficient_privilege then raise notice 'ok: anon cannot record';
end $$;
reset role;
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
select pg_temp.check((select count(*) from public.sentinel_events) = 0, 'non-admin reads no events');
do $$ begin
  perform public.sentinel_record_round('{"checks":[]}');
  raise exception 'FAIL: authenticated recorded a round';
exception when insufficient_privilege then raise notice 'ok: authenticated cannot record';
end $$;
do $$ begin
  perform public.ack_sentinel_event(1);
  raise exception 'FAIL: non-admin acknowledged';
exception when insufficient_privilege then raise notice 'ok: non-admin cannot acknowledge';
end $$;
do $$ begin
  perform public.request_sentinel_round();
  raise exception 'FAIL: non-admin requested a round';
exception when insufficient_privilege then raise notice 'ok: non-admin cannot request a round';
end $$;
do $$ begin
  perform public.sentinel_overview();
  raise exception 'FAIL: non-admin read the overview';
exception when insufficient_privilege then raise notice 'ok: non-admin cannot read the overview';
end $$;
do $$ begin
  update public.sentinel_events set acknowledged_at = now();
  raise exception 'FAIL: direct update allowed';
exception when insufficient_privilege then raise notice 'ok: no direct update';
end $$;
do $$ begin
  perform public.sentinel_secret_ok('x');
  raise exception 'FAIL: authenticated may test the secret';
exception when insufficient_privilege then raise notice 'ok: authenticated cannot test the secret';
end $$;
do $$ begin
  perform private.take_inventory_snapshot();
  raise exception 'FAIL: authenticated took a snapshot';
exception when insufficient_privilege then raise notice 'ok: authenticated cannot take a snapshot';
end $$;

set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select pg_temp.check((select count(*) from public.sentinel_events) = 4, 'admin reads events');
select public.ack_sentinel_event(1);
select public.ack_sentinel_event(1);
select pg_temp.check((select acknowledged_by from public.sentinel_events where id = 1) = '00000000-0000-0000-0000-00000000000a', 'ack records the admin');
select pg_temp.check((public.sentinel_overview()->>'unacknowledged')::int = 3, 'overview counts unacknowledged');
select pg_temp.check(jsonb_array_length(public.sentinel_overview()->'targets') = 2, 'overview lists 2 targets');
select pg_temp.check(public.request_sentinel_round(), 'admin requests a round');
select pg_temp.check(not public.request_sentinel_round(), 'second request within 2 minutes is refused');
reset role;
reset request.jwt.claim.sub;
select pg_temp.check((select count(*) from net.requests where body->>'source' = 'manual'
  and headers->>'x-sentinel-secret' = (select decrypted_secret from vault.decrypted_secrets where name = 'sentinel_secret')) = 1,
  'manual request carries the secret');
select pg_temp.check((select count(*) from public.audit_events where table_name = 'sentinel_events') = 1, 'ack audited once');

select decrypted_secret as secret from vault.decrypted_secrets where name = 'sentinel_secret' \gset
set role service_role;
select pg_temp.check(public.sentinel_secret_ok(:'secret'), 'secret ok');
select pg_temp.check(not public.sentinel_secret_ok('0000000000000000000000000000000000000000'), 'wrong secret refused');
select pg_temp.check(not coalesce(public.sentinel_secret_ok(null), false), 'null secret refused');
reset role;
select pg_temp.check(length((select decrypted_secret from vault.decrypted_secrets where name = 'sentinel_secret')) = 64, 'secret is 32 random bytes');

-- MARK: licences
insert into public.licences (id, product, licence_id, customer, machine, issued, expires, status) values
  (gen_random_uuid(), 'mediflow', 'L-20', 'Clinic A', '*', '2026-01-01', '2026-11-07', 'active'),   -- 20 days
  (gen_random_uuid(), 'mediflow', 'L-5', 'Clinic B', '*', '2026-01-01', '2026-10-23', 'active'),    -- 5 days
  (gen_random_uuid(), 'khayatyar', 'L-1', 'Tailor C', '*', '2026-01-01', '2026-10-19', 'active'),   -- 1 day
  (gen_random_uuid(), 'khayatyar', 'L-X', 'Tailor D', '*', '2026-01-01', '2026-10-15', 'active'),   -- expired 3 days ago
  (gen_random_uuid(), 'khayatyar', 'L-OLD', 'Tailor E', '*', '2026-01-01', '2026-09-01', 'active'), -- expired 47 days ago
  (gen_random_uuid(), 'mediflow', 'L-NONE', 'Clinic F', '*', '2026-01-01', null, 'active'),
  (gen_random_uuid(), 'mediflow', 'L-SUP', 'Clinic G', '*', '2026-01-01', '2026-10-20', 'superseded');
select pg_temp.check(private.sentinel_licence_sweep('2026-10-18') = 4, 'sweep: 4 licence events');
select pg_temp.check(private.sentinel_licence_sweep('2026-10-18') = 0, 'sweep again: none');
select pg_temp.check((select string_agg(subject || '=' || (detail->>'threshold') || '/' || severity, ',' order by subject)
  from public.sentinel_events where kind like 'licence%') = 'L-1=1/critical,L-20=30/info,L-5=7/warning,L-X=0/critical', 'thresholds');
select pg_temp.check(private.sentinel_licence_sweep('2026-11-01') = 3, 'two weeks on: L-20 crosses 7, L-5 and L-1 expire, L-X already reported');
select pg_temp.check(private.sentinel_licence_sweep('2026-11-01') = 0, 'and only once');

-- MARK: snapshots and pruning
select private.take_inventory_snapshot() from generate_series(1, 13);
select pg_temp.check((select count(*) from public.inventory_snapshots) = 12, 'newest 12 snapshots kept');
select pg_temp.check((select min(id) from public.inventory_snapshots) = 2, 'oldest dropped');
select pg_temp.check((select data ? 'licences' and bytes > 0 from public.inventory_snapshots order by id desc limit 1), 'snapshot holds export_inventory()');
select pg_temp.check(private.sentinel_prune() = 0, 'prune: nothing within 14 days');
select pg_temp.check(private.sentinel_prune(interval '1 hour') = 6, 'prune: the 6 test rounds are older than an hour');
select pg_temp.check((select count(*) from public.sentinel_checks) = 0, 'checks went with their rounds');
-- The Sentinel's four jobs (20261019090100_obligation_sweep.sql adds a fifth, 'sentinel-obligations', of its own).
select pg_temp.check((select count(*) from cron.job
                      where jobname in ('sentinel-round', 'sentinel-licences', 'sentinel-snapshot', 'sentinel-prune')) = 4, '4 cron jobs');
select pg_temp.check((select command from cron.job where jobname = 'sentinel-licences') = 'select private.sentinel_licence_sweep()',
  'the 06:15 job runs the licence sweep');
\set QUIET 1
\ir schedule.sql
select pg_temp.check((select count(*) from vault.secrets where name like 'sentinel_%') = 2, 're-running the schedule keeps one copy of each secret');
select pg_temp.check((select count(*) from cron.job
                      where jobname in ('sentinel-round', 'sentinel-licences', 'sentinel-snapshot', 'sentinel-prune')) = 4
  and (select count(*) from cron.job where jobname like 'sentinel-%')
      = 4 + (select count(*) from cron.job where jobname = 'sentinel-obligations'), 'and still 4 jobs, none twice');
\echo ALL SENTINEL SQL CHECKS PASSED
