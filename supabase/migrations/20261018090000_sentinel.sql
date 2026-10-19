-- Sentinel: checks that keep running on Supabase while the owner's Mac is off.
--
-- What is here: the tables and functions. The schedule (pg_cron, pg_net, the shared secret in Vault) is in
-- 20261018090100_sentinel_schedule.sql, so this file can be applied and tested on any Postgres.
--
--   * sentinel_rounds / sentinel_checks: one row per round, one row per public target per round, written only by
--     the `sentinel` Edge Function through sentinel_record_round() (service role). Kept 14 days.
--   * sentinel_target_state: the last judged state of each target, used to emit events on changes only.
--   * sentinel_events: what changed (down after 2 failed rounds in a row, recovered, a licence crossing 30/7/1/0
--     days), deduplicated by dedup_key so a re-run never repeats an event. Admins acknowledge them through
--     ack_sentinel_event(); nothing else is writable from the API.
--   * inventory_snapshots: a weekly copy of export_inventory(), newest 12 kept (Supabase Free has no PITR).
--
-- The targets are the Monitor's public URLs (LinumicCore MonitorCatalog); no credential is ever sent to them.

create table public.sentinel_rounds (
  id bigint generated always as identity primary key,
  started_at timestamptz not null,
  finished_at timestamptz not null,
  source text not null default 'cron' check (source in ('cron', 'manual')),
  target_count int not null check (target_count >= 0),
  up_count int not null check (up_count >= 0),
  degraded_count int not null check (degraded_count >= 0),
  down_count int not null check (down_count >= 0),
  check (finished_at >= started_at)
);
create index on public.sentinel_rounds (started_at desc);

create table public.sentinel_checks (
  id bigint generated always as identity primary key,
  round_id bigint not null references public.sentinel_rounds (id) on delete cascade,
  target_id text not null check (length(target_id) > 0),
  product text not null,
  checked_at timestamptz not null,
  state text not null check (state in ('up', 'degraded', 'down')),
  status_code int,
  latency_ms int check (latency_ms is null or latency_ms >= 0),
  health_status text,
  reason text check (reason is null or reason in ('transport', 'httpStatus', 'unhealthy', 'unreadableHealth', 'slow')),
  failure text
);
create index on public.sentinel_checks (target_id, checked_at desc);
create index on public.sentinel_checks (round_id);
create index on public.sentinel_checks (checked_at);

create table public.sentinel_target_state (
  target_id text primary key,
  product text not null,
  -- unknown until the first answer; down only after 2 failed rounds in a row.
  state text not null default 'unknown' check (state in ('unknown', 'up', 'down')),
  consecutive_failures int not null default 0 check (consecutive_failures >= 0),
  since timestamptz not null,
  last_checked_at timestamptz not null,
  last_failure_at timestamptz,
  last_failure text
);

create table public.sentinel_events (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  kind text not null check (kind in ('targetDown', 'targetRecovered', 'licenceExpiring', 'licenceExpired')),
  severity text not null check (severity in ('info', 'warning', 'critical')),
  -- The target id or the licence id the event is about.
  subject text not null,
  product text not null,
  title text not null,
  detail jsonb not null default '{}'::jsonb,
  dedup_key text not null unique,
  acknowledged_at timestamptz,
  acknowledged_by uuid
);
create index on public.sentinel_events (occurred_at desc);
create index on public.sentinel_events (occurred_at desc) where acknowledged_at is null;

create table public.inventory_snapshots (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  schema_version int,
  bytes int not null,
  data jsonb not null
);
create index on public.inventory_snapshots (created_at desc);

-- Row-level security: admins read; nobody writes through the API (the functions below are security definer).
do $$
declare t text;
begin
  foreach t in array array['sentinel_rounds', 'sentinel_checks', 'sentinel_target_state', 'sentinel_events', 'inventory_snapshots']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "admins read %1$s" on public.%1$I for select to authenticated using ((select private.is_admin()))', t);
    execute format('revoke insert, update, delete, truncate on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- Acknowledgements are audited (who, when). System-written rows are not: the check rows would flood the log.
create trigger sentinel_events_audit after update on public.sentinel_events
  for each row execute function public.audit_trigger();

-- MARK: Recording a round (Edge Function, service role only)

-- Takes {"source": "cron", "startedAt": ..., "finishedAt": ..., "checks": [{targetID, product, checkedAt, state,
-- statusCode, latencyMS, healthStatus, reason, failure}]}; writes the round, the checks, the per-target state and
-- any events. Returns {"roundID": n, "events": k}.
create or replace function public.sentinel_record_round(round jsonb)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare
  rid bigint;
  c jsonb;
  st public.sentinel_target_state%rowtype;
  checked timestamptz;
  failed boolean;
  new_state text;
  new_failures int;
  emitted int := 0;
  n int;
begin
  if jsonb_typeof(round->'checks') is distinct from 'array' then
    raise exception 'round.checks must be a JSON array';
  end if;

  insert into public.sentinel_rounds (started_at, finished_at, source, target_count, up_count, degraded_count, down_count)
  select (round->>'startedAt')::timestamptz, (round->>'finishedAt')::timestamptz, coalesce(round->>'source', 'cron'),
         jsonb_array_length(round->'checks'),
         count(*) filter (where x->>'state' = 'up'),
         count(*) filter (where x->>'state' = 'degraded'),
         count(*) filter (where x->>'state' = 'down')
  from jsonb_array_elements(round->'checks') x
  returning id into rid;

  for c in select * from jsonb_array_elements(round->'checks') loop
    checked := (c->>'checkedAt')::timestamptz;
    insert into public.sentinel_checks (round_id, target_id, product, checked_at, state, status_code, latency_ms,
                                        health_status, reason, failure)
    values (rid, c->>'targetID', c->>'product', checked, c->>'state', (c->>'statusCode')::int, (c->>'latencyMS')::int,
            c->>'healthStatus', c->>'reason', left(c->>'failure', 500));

    failed := c->>'state' = 'down';
    select * into st from public.sentinel_target_state where target_id = c->>'targetID' for update;
    if not found then
      st.target_id := c->>'targetID';
      st.state := 'unknown';
      st.consecutive_failures := 0;
      st.since := checked;
    end if;

    new_failures := case when failed then st.consecutive_failures + 1 else 0 end;
    new_state := case
      when failed and new_failures >= 2 then 'down'
      when failed then st.state            -- one failed round is not an outage yet
      else 'up' end;

    if new_state = 'down' and st.state <> 'down' then
      insert into public.sentinel_events (occurred_at, kind, severity, subject, product, title, detail, dedup_key)
      values (checked, 'targetDown', 'critical', st.target_id, c->>'product',
              format('%s is down', st.target_id),
              jsonb_strip_nulls(jsonb_build_object('reason', c->>'reason', 'statusCode', (c->>'statusCode')::int,
                                                   'failure', left(c->>'failure', 500), 'failedRounds', new_failures)),
              format('down:%s:%s', st.target_id, public.iso8601(checked)))
      on conflict (dedup_key) do nothing;
      get diagnostics n = row_count;
      emitted := emitted + n;
    elsif new_state = 'up' and st.state = 'down' then
      insert into public.sentinel_events (occurred_at, kind, severity, subject, product, title, detail, dedup_key)
      values (checked, 'targetRecovered', 'info', st.target_id, c->>'product',
              format('%s is back up', st.target_id),
              jsonb_build_object('downSince', public.iso8601(st.since)),
              format('up:%s:%s', st.target_id, public.iso8601(checked)))
      on conflict (dedup_key) do nothing;
      get diagnostics n = row_count;
      emitted := emitted + n;
    end if;

    insert into public.sentinel_target_state as t (target_id, product, state, consecutive_failures, since, last_checked_at,
                                                   last_failure_at, last_failure)
    values (st.target_id, c->>'product', new_state, new_failures,
            case when new_state is distinct from st.state then checked else st.since end, checked,
            case when failed then checked else st.last_failure_at end,
            case when failed then left(coalesce(c->>'failure', c->>'reason'), 500) else st.last_failure end)
    on conflict (target_id) do update set
      product = excluded.product, state = excluded.state, consecutive_failures = excluded.consecutive_failures,
      since = excluded.since, last_checked_at = excluded.last_checked_at,
      last_failure_at = excluded.last_failure_at, last_failure = excluded.last_failure;
  end loop;

  return jsonb_build_object('roundID', rid, 'events', emitted);
end $$;
revoke execute on function public.sentinel_record_round(jsonb) from public, anon, authenticated;
grant execute on function public.sentinel_record_round(jsonb) to service_role;

-- MARK: Licence expiry (daily, pg_cron)

-- Emits one event per active licence for the most urgent threshold it has crossed: 30, 7, 1 days left or expired
-- (expired only within the last 30 days, so years-old licences don't flood the list). dedup_key includes the
-- expiry date, so a renewal (a new licence row) starts its own thresholds. Returns the number of new events.
create or replace function private.sentinel_licence_sweep(today date default (now() at time zone 'utc')::date)
returns int language plpgsql volatile security definer set search_path = ''
as $$
declare
  emitted int;
begin
  insert into public.sentinel_events (kind, severity, subject, product, title, detail, dedup_key)
  select case when b.threshold = 0 then 'licenceExpired' else 'licenceExpiring' end,
         case when b.threshold <= 1 then 'critical' when b.threshold = 7 then 'warning' else 'info' end,
         b.licence_id, b.product,
         case when b.threshold = 0 then format('Licence %s (%s) has expired', b.licence_id, b.customer)
              else format('Licence %s (%s) expires in %s days', b.licence_id, b.customer, b.days_left) end,
         jsonb_build_object('customer', b.customer, 'expires', to_char(b.expires, 'YYYY-MM-DD'),
                            'daysLeft', b.days_left, 'threshold', b.threshold, 'edition', b.edition),
         format('licence:%s:%s:%s', b.licence_id, to_char(b.expires, 'YYYY-MM-DD'), b.threshold)
  from (
    select l.licence_id, l.product, l.customer, l.edition, l.expires, (l.expires - today) as days_left,
           case when l.expires - today < 0 then 0
                when l.expires - today <= 1 then 1
                when l.expires - today <= 7 then 7
                else 30 end as threshold
    from public.licences l
    where l.status = 'active' and l.expires is not null
      and l.expires - today <= 30 and l.expires - today >= -30
  ) b
  on conflict (dedup_key) do nothing;
  get diagnostics emitted = row_count;
  return emitted;
end $$;
revoke execute on function private.sentinel_licence_sweep(date) from public, anon, authenticated;

-- MARK: Weekly inventory snapshot (pg_cron)

-- Copies export_inventory() into inventory_snapshots and keeps the newest 12. Runs as the function owner
-- (postgres), which assert_admin() accepts; never callable through the API.
create or replace function private.take_inventory_snapshot()
returns bigint language plpgsql volatile security definer set search_path = ''
as $$
declare
  doc jsonb;
  sid bigint;
begin
  doc := public.export_inventory();
  insert into public.inventory_snapshots (schema_version, bytes, data)
  values ((doc->>'schemaVersion')::int, octet_length(doc::text), doc)
  returning id into sid;
  delete from public.inventory_snapshots
  where id not in (select id from public.inventory_snapshots order by created_at desc, id desc limit 12);
  return sid;
end $$;
revoke execute on function private.take_inventory_snapshot() from public, anon, authenticated;

-- MARK: Pruning (daily, pg_cron)

-- Rounds and checks older than 14 days (checks go with their round). Events and snapshots are kept.
create or replace function private.sentinel_prune(keep interval default interval '14 days')
returns int language plpgsql volatile security definer set search_path = ''
as $$
declare
  removed int;
begin
  delete from public.sentinel_rounds where started_at < now() - keep;
  get diagnostics removed = row_count;
  return removed;
end $$;
revoke execute on function private.sentinel_prune(interval) from public, anon, authenticated;

-- MARK: Reading (admins, through the app)

-- Everything the app shows in one call, so it never pages through thousands of check rows:
-- {"generatedAt", "lastRound": {...}|null, "targets": [{targetID, product, state, consecutiveFailures, since,
--  lastCheckedAt, lastFailureAt, lastFailure, samples, available, avgLatencyMS, lastLatencyMS, lastCheckState}],
--  "unacknowledged": n, "lastSnapshot": {id, createdAt, bytes}|null}
create or replace function public.sentinel_overview(hours int default 24)
returns jsonb language plpgsql stable security invoker set search_path = ''
as $$
begin
  perform public.assert_admin();
  return jsonb_build_object(
    'generatedAt', public.iso8601(now()),
    'windowHours', hours,
    'lastRound', (select jsonb_build_object('id', r.id, 'startedAt', public.iso8601(r.started_at),
                         'finishedAt', public.iso8601(r.finished_at), 'source', r.source, 'targetCount', r.target_count,
                         'upCount', r.up_count, 'degradedCount', r.degraded_count, 'downCount', r.down_count)
                  from public.sentinel_rounds r order by r.started_at desc limit 1),
    'targets', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'targetID', s.target_id, 'product', s.product, 'state', s.state, 'consecutiveFailures', s.consecutive_failures,
        'since', public.iso8601(s.since), 'lastCheckedAt', public.iso8601(s.last_checked_at),
        'lastFailureAt', public.iso8601(s.last_failure_at), 'lastFailure', s.last_failure,
        'samples', w.samples, 'available', w.available, 'avgLatencyMS', w.avg_latency,
        'lastLatencyMS', lc.latency_ms, 'lastCheckState', lc.state)) order by s.product, s.target_id)
      from public.sentinel_target_state s
      left join lateral (
        select count(*)::int as samples,
               (count(*) filter (where k.state in ('up', 'degraded')))::int as available,
               round(avg(k.latency_ms))::int as avg_latency
        from public.sentinel_checks k
        where k.target_id = s.target_id and k.checked_at >= now() - make_interval(hours => hours)
      ) w on true
      left join lateral (
        select k.latency_ms, k.state from public.sentinel_checks k
        where k.target_id = s.target_id order by k.checked_at desc limit 1
      ) lc on true), '[]'::jsonb),
    'unacknowledged', (select count(*) from public.sentinel_events e where e.acknowledged_at is null),
    'snapshotCount', (select count(*) from public.inventory_snapshots),
    'lastSnapshot', (select jsonb_build_object('id', i.id, 'createdAt', public.iso8601(i.created_at), 'bytes', i.bytes,
                                               'schemaVersion', i.schema_version)
                     from public.inventory_snapshots i order by i.created_at desc limit 1)
  );
end $$;
revoke execute on function public.sentinel_overview(int) from public, anon;
grant execute on function public.sentinel_overview(int) to authenticated;

-- The newest events in the app's Codable shape (whole-second ISO 8601 dates, camelCase), newest first.
create or replace function public.sentinel_recent_events(max_rows int default 50, include_acknowledged boolean default true)
returns jsonb language plpgsql stable security invoker set search_path = ''
as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id', e.id, 'occurredAt', public.iso8601(e.occurred_at), 'kind', e.kind, 'severity', e.severity,
      'subject', e.subject, 'product', e.product, 'title', e.title, 'detail', e.detail,
      'acknowledgedAt', public.iso8601(e.acknowledged_at))) order by e.occurred_at desc, e.id desc)
    from (select * from public.sentinel_events x
          where include_acknowledged or x.acknowledged_at is null
          order by x.occurred_at desc, x.id desc limit greatest(1, least(max_rows, 500))) e), '[]'::jsonb);
end $$;
revoke execute on function public.sentinel_recent_events(int, boolean) from public, anon;
grant execute on function public.sentinel_recent_events(int, boolean) to authenticated;

-- Marks one event as seen. Idempotent: an acknowledged event keeps its first acknowledgement.
create or replace function public.ack_sentinel_event(event_id bigint)
returns void language plpgsql volatile security definer set search_path = ''
as $$
begin
  -- Not assert_admin(): inside a security-definer function current_user is the owner, which it would accept.
  if not coalesce(private.is_admin(), false) then
    raise exception 'Not authorised: Linumic OS admins only' using errcode = '42501';
  end if;
  update public.sentinel_events
  set acknowledged_at = now(), acknowledged_by = (select auth.uid())
  where id = event_id and acknowledged_at is null;
end $$;
revoke execute on function public.ack_sentinel_event(bigint) from public, anon;
grant execute on function public.ack_sentinel_event(bigint) to authenticated;
