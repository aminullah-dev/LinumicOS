-- After the rollback in docs/desk-sync.md (run by run.sh): nothing of the two migrations is left, and the Sentinel is as
-- it was on 2026-10-19.
\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on

create function pg_temp.check(ok boolean, label text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAIL: %', label; end if;
  raise notice 'ok: %', label;
end $$;

select pg_temp.check((select count(*) from pg_tables where schemaname = 'public'
                      and tablename in ('desk_state', 'obligations', 'vendors', 'desk_ledger_reading', 'desk_items')) = 0,
  'rollback: no Desk sync table is left');
select pg_temp.check((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname in ('public', 'private')
                        and p.proname in ('desk_sync_pull', 'push_desk_state', 'push_obligations', 'push_vendors',
                                          'replace_desk_items', 'desk_mark_json', 'obligation_json', 'vendor_json',
                                          'desk_sync_bump', 'vendor_entry_ok', 'obligation_entry_ok', 'cost_ok', 'nonblank',
                                          'desk_sync_has_secret', 'sentinel_obligation_sweep', 'obligation_schedule',
                                          'usable_lead_days')) = 0,
  'rollback: no Desk sync function is left');
select pg_temp.check((select count(*) from public.sentinel_events where kind = 'obligationDue') = 0, 'rollback: no obligation event is left');
do $$ begin
  insert into public.sentinel_events (kind, severity, subject, product, title, dedup_key)
  values ('obligationDue', 'info', 'x', 'x', 'x', 'rollback-test');
  raise exception 'FAIL: the obligation kind is still allowed';
exception when check_violation then raise notice 'ok: rollback: the four kinds of 2026-10-18 only';
end $$;
select pg_temp.check((select command from cron.job where jobname = 'sentinel-licences') = 'select private.sentinel_licence_sweep()',
  'rollback: the 06:15 job runs the licence sweep only');
select pg_temp.check((select count(*) from cron.job where jobname like 'sentinel-%') = 4, 'rollback: the four Sentinel jobs are still there');
select pg_temp.check((select string_agg(pg_get_function_identity_arguments(p.oid), ';') from pg_proc p
                      where p.proname = 'sentinel_recent_events') = 'max_rows integer, include_acknowledged boolean',
  'rollback: sentinel_recent_events takes two arguments again');
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select pg_temp.check(jsonb_typeof(public.sentinel_recent_events(10, true)) = 'array', 'rollback: and an admin can still call it');
reset role;
reset request.jwt.claim.sub;
select pg_temp.check((select count(*) from pg_tables where schemaname = 'public'
                      and tablename in ('licences', 'sentinel_events', 'inventory_snapshots', 'audit_events', 'products')) = 5,
  'rollback: the licence ledger, the Sentinel, the audit log and the inventory are untouched');
\echo ALL DESK SYNC ROLLBACK CHECKS PASSED
