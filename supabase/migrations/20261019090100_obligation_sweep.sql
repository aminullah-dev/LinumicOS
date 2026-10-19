-- Obligation reminders while the Mac is off: a daily sweep of the obligations synced by 20261019090000_desk_sync.sql,
-- in its own pg_cron job at 06:16 UTC (a minute after the Sentinel's licence sweep, which is left exactly as it is),
-- writing one sentinel event per obligation and lead window.
-- Depends on 20261018090000_sentinel.sql, 20261018090100_sentinel_schedule.sql and 20261019090000_desk_sync.sql.
-- Rollback: docs/desk-sync.md.
--
-- The schedule is built as the app's register builds it (ObligationsBuilder, ObligationAlerts): the seed and the
-- owner's rows, with the owner's date when he set one; each account's renewal once its day is recorded; Done for that
-- due day closes it. Live rows (domains, certificates, licences, restore tests, the continuity export) are read on the
-- devices and are not here, and neither is a seed row a live reading replaces on the devices (domain.linumic.com: the
-- Monitor's RDAP date, not the seed's); licences have their own sweep. The event's dedup_key is the app's own
-- notification key, obligation:<id>:<due>:<lead>, so a re-run never writes an event twice.

-- MARK: Events of the new kind

alter table public.sentinel_events drop constraint sentinel_events_kind_check;
alter table public.sentinel_events add constraint sentinel_events_kind_check
  check (kind in ('targetDown', 'targetRecovered', 'licenceExpiring', 'licenceExpired', 'obligationDue'));

-- MARK: The schedule

-- Lead days the register can use (Obligation.usableLeadDays): at least one, each a whole day from 1 to 366; anything
-- else gives the defaults 30, 14, 7 and 1.
create or replace function private.usable_lead_days(j jsonb)
returns int[] language sql immutable set search_path = ''
as $$
  select case
    when jsonb_typeof(j) = 'array' and jsonb_array_length(j) > 0
         and not exists (select 1 from jsonb_array_elements(j) x
                         where jsonb_typeof(x) <> 'number' or (x::text)::numeric not between 1 and 366
                            or (x::text)::numeric <> trunc((x::text)::numeric))
    then array(select (x::text)::int from jsonb_array_elements(j) x)
    else array[30, 14, 7, 1] end
$$;

-- Every obligation the app would alert about, with its due day as the register has it and whether it is done for that
-- day: {obligation_id, title, renewal, product, due, lead_days, closed}. For an account's renewal, `title` is the
-- account's name and `renewal` is true (the app words it "<name>: renewal").
-- Ids of rows the devices read from a live source (ObligationsBuilder.derived: domain., tls., licence., keys.,
-- continuity.). A seed row with such an id is only a placeholder until the source is read, so it is never swept.
create or replace function private.is_live_obligation_id(id text)
returns boolean language sql immutable set search_path = ''
as $$ select id ~ '^(domain|tls|licence|keys|continuity)\.' $$;

create or replace function private.obligation_schedule()
returns table (obligation_id text, title text, renewal boolean, product text, due date, lead_days int[], closed boolean)
language sql stable set search_path = ''
as $$
  with rows as (
    -- The seed (as the newest app that synced wrote it) and the owner's own rows, each with a title, source and day.
    select o.obligation_id, o.data, o.due
    from public.obligations o
    where not o.deleted and o.entry in ('seed', 'row') and not private.is_live_obligation_id(o.obligation_id)
      and private.nonblank(o.data->>'title') and private.nonblank(o.data->>'source') and o.data ? 'recordedOn'
  ), dates as (
    -- The owner's date for a row, with its source (one per obligation).
    select o.obligation_id, o.due
    from public.obligations o
    where not o.deleted and o.entry = 'date' and private.nonblank(o.data->>'source')
  ), accounts as (
    select v.account_id, v.data
    from public.vendors v
    where not v.deleted and v.entry in ('seed', 'account')
      and private.nonblank(v.data->>'name') and private.nonblank(v.data->>'source') and v.data ? 'recordedOn'
  ), renewals as (
    -- The renewal day as recorded last on the account's card (an edit with its source), else on the account itself.
    -- Every day is read with iso_day: one that is not a real day (the server refuses those, but a row written before
    -- that or by hand) is skipped, never cast, so it can't stop the sweep.
    select a.account_id, a.data->>'name' as name,
           coalesce((select private.iso_day(e->>'renewal')
                     from public.vendors f, jsonb_array_elements(f.data->'edits') e
                     where f.entry = 'facts' and not f.deleted and f.account_id = a.account_id
                       and private.iso_day(e->>'renewal') is not null and private.nonblank(e->>'renewalSource')
                     order by e->>'enteredAt' desc limit 1),
                    case when private.nonblank(a.data->>'renewalSource') then private.iso_day(a.data->>'renewal') end) as due
    from accounts a
  ), effective as (
    select r.obligation_id, r.data->>'title' as title, false as renewal, r.data->>'product' as product,
           coalesce(d.due, r.due) as due, private.usable_lead_days(r.data->'leadDays') as lead_days
    from rows r left join dates d on d.obligation_id = r.obligation_id
    union all
    select 'account.' || n.account_id || '.renewal', n.name, true, null, n.due, array[30, 14, 7, 1]
    from renewals n
    where n.due is not null
  )
  select e.obligation_id, e.title, e.renewal, e.product, e.due, e.lead_days,
         exists (select 1 from public.obligations c
                 where c.entry = 'done' and not c.deleted and c.obligation_id = e.obligation_id
                   and c.due is not distinct from e.due) as closed
  from effective e
$$;
revoke execute on function private.usable_lead_days(jsonb), private.is_live_obligation_id(text), private.obligation_schedule()
  from public, anon, authenticated;

-- MARK: The sweep (daily, pg_cron)

-- One event per open, dated obligation for the window it is in today: 30, 14, 7 or 1 days before its day (the
-- smallest lead day at or above the days left), and 0 on the day or after it. Severity as the app's: overdue or within
-- a day critical, the 7- and 14-day windows warning, the 30-day window info. Returns the number of new events.
create or replace function private.sentinel_obligation_sweep(today date default (now() at time zone 'utc')::date)
returns int language plpgsql volatile security definer set search_path = ''
as $$
declare
  emitted int;
begin
  insert into public.sentinel_events (kind, severity, subject, product, title, detail, dedup_key)
  select 'obligationDue',
         case when b.lead <= 1 then 'critical' when b.lead in (7, 14) then 'warning' else 'info' end,
         b.obligation_id, coalesce(b.product, 'Linumic'),
         case when b.days_left < 0 then format('%s is overdue by %s days', b.name, -b.days_left)
              when b.days_left = 0 then format('%s is due today', b.name)
              else format('%s is due in %s days', b.name, b.days_left) end,
         -- What the app words the line from: the obligation's own title (or the account's name), and where it stands.
         jsonb_build_object('obligationID', b.obligation_id, 'title', b.title, 'renewal', b.renewal,
                            'due', to_char(b.due, 'YYYY-MM-DD'), 'daysLeft', b.days_left, 'lead', b.lead, 'key', b.key),
         b.key
  from (
    select s.*, case when s.renewal then format('%s: renewal', s.title) else s.title end as name,
           s.due - today as days_left, l.lead,
           format('obligation:%s:%s:%s', s.obligation_id, to_char(s.due, 'YYYY-MM-DD'), l.lead) as key
    from private.obligation_schedule() s
    cross join lateral (select case when s.due - today <= 0 then 0
                                    else (select min(x) from unnest(s.lead_days) x where s.due - today <= x) end as lead) l
    where not s.closed and s.due is not null
  ) b
  where b.lead is not null
  on conflict (dedup_key) do nothing;
  get diagnostics emitted = row_count;
  return emitted;
end $$;
revoke execute on function private.sentinel_obligation_sweep(date) from public, anon, authenticated;

-- Its own job, at 06:16 UTC (10:46 in Kabul), a minute after the licence sweep ('sentinel-licences', not changed here):
-- pg_cron runs each job in its own transaction, so a failure in one sweep never rolls back the other's events.
-- cron.schedule replaces a job of the same name owned by the same role, so re-running this statement is safe.
select cron.schedule('sentinel-obligations', '16 6 * * *', $$select private.sentinel_obligation_sweep()$$);

-- MARK: Reading

-- The app of 2026-10-18 decodes only the four kinds it knows, so obligation events are left out unless asked for
-- (include_obligations); the app of this change asks. The old two-argument function is replaced, not overloaded, so a
-- call that names two arguments still resolves to one function.
drop function public.sentinel_recent_events(int, boolean);
create function public.sentinel_recent_events(max_rows int default 50, include_acknowledged boolean default true,
                                              include_obligations boolean default false)
returns jsonb language plpgsql stable security invoker set search_path = ''
as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id', e.id, 'occurredAt', public.iso8601(e.occurred_at), 'kind', e.kind, 'severity', e.severity,
      'subject', e.subject, 'product', e.product, 'title', e.title, 'detail', e.detail,
      'acknowledgedAt', public.iso8601(e.acknowledged_at))) order by e.occurred_at desc, e.id desc)
    from (select * from public.sentinel_events x
          where (include_acknowledged or x.acknowledged_at is null)
            and (include_obligations or x.kind <> 'obligationDue')
          order by x.occurred_at desc, x.id desc limit greatest(1, least(max_rows, 500))) e), '[]'::jsonb);
end $$;
revoke execute on function public.sentinel_recent_events(int, boolean, boolean) from public, anon;
grant execute on function public.sentinel_recent_events(int, boolean, boolean) to authenticated;

-- The overview's "unacknowledged" counts the events the app of 2026-10-18 can list and acknowledge, so it never shows a
-- count it can't clear; obligation events are counted on their own ("unacknowledgedObligations"), which the app of this
-- change adds. The same signature, so nothing that calls it changes; only those two counts differ from
-- 20261018090000_sentinel.sql.
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
    'unacknowledged', (select count(*) from public.sentinel_events e
                       where e.acknowledged_at is null and e.kind <> 'obligationDue'),
    'unacknowledgedObligations', (select count(*) from public.sentinel_events e
                                  where e.acknowledged_at is null and e.kind = 'obligationDue'),
    'snapshotCount', (select count(*) from public.inventory_snapshots),
    'lastSnapshot', (select jsonb_build_object('id', i.id, 'createdAt', public.iso8601(i.created_at), 'bytes', i.bytes,
                                               'schemaVersion', i.schema_version)
                     from public.inventory_snapshots i order by i.created_at desc limit 1)
  );
end $$;
