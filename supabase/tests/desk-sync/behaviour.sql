-- Desk sync behaviour checks, run by run.sh on a throwaway database. TEST DATA only (made-up marks, obligations and
-- accounts; the sweep rows come from Packages/LinumicCore/Tests/LinumicCoreTests/Fixtures/desk-sync-sweep.json).
\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on

create function pg_temp.check(ok boolean, label text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAIL: %', label; end if;
  raise notice 'ok: %', label;
end $$;

-- The status of the one change in a push answer, and its row's version.
create function pg_temp.status(answer jsonb) returns text language sql as $$ select answer->0->>'status' $$;
create function pg_temp.version(answer jsonb) returns bigint language sql as $$ select (answer->0->'row'->>'version')::bigint $$;
create function pg_temp.mark(id text, expected bigint, kind text, extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('id', id, 'expectedVersion', expected,
    'data', case when kind is null then null else
      jsonb_build_object('kind', kind, 'at', '2026-10-19T10:00:00Z', 'factHash', '0123456789abcdef') || extra end))
$$;

insert into auth.users values ('00000000-0000-0000-0000-00000000000a'), ('00000000-0000-0000-0000-00000000000b');
insert into public.app_admins (user_id) values ('00000000-0000-0000-0000-00000000000a');

-- MARK: who may do what
set role anon;
do $$ begin
  perform public.desk_sync_pull();
  raise exception 'FAIL: anon pulled';
exception when insufficient_privilege then raise notice 'ok: anon cannot pull';
end $$;
do $$ begin
  perform public.push_desk_state('[]', 'macOS');
  raise exception 'FAIL: anon pushed';
exception when insufficient_privilege then raise notice 'ok: anon cannot push';
end $$;
do $$ begin
  perform count(*) from public.desk_state;
  raise exception 'FAIL: anon read desk_state';
exception when insufficient_privilege then raise notice 'ok: anon cannot read the tables';
end $$;
reset role;

set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
do $$ begin
  perform public.desk_sync_pull();
  raise exception 'FAIL: a non-admin pulled';
exception when insufficient_privilege then raise notice 'ok: a non-admin cannot pull';
end $$;
do $$ begin
  perform public.push_obligations('[]', 'macOS');
  raise exception 'FAIL: a non-admin pushed';
exception when insufficient_privilege then raise notice 'ok: a non-admin cannot push';
end $$;
do $$ begin
  perform public.replace_desk_items(0, '{}');
  raise exception 'FAIL: a non-admin replaced the ledger reading';
exception when insufficient_privilege then raise notice 'ok: a non-admin cannot replace the ledger reading';
end $$;

set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
do $$ begin
  insert into public.desk_state (id, kind, marked_at, fact_hash, written_on)
  values ('ledger.talar|x|checkbox', 'done', now(), '0123456789abcdef', 'macOS');
  raise exception 'FAIL: an admin inserted around the RPC';
exception when insufficient_privilege then raise notice 'ok: no direct insert, even for an admin';
end $$;
do $$ begin
  update public.obligations set data = data;
  raise exception 'FAIL: an admin updated around the RPC';
exception when insufficient_privilege then raise notice 'ok: no direct update, even for an admin';
end $$;
do $$ begin
  perform public.push_desk_state('[]', 'Android');
  raise exception 'FAIL: an unknown device was taken';
exception when invalid_parameter_value then raise notice 'ok: device must be macOS or iOS';
end $$;

-- MARK: desk_state, one version at a time
select pg_temp.check(pg_temp.status(public.push_desk_state(pg_temp.mark('ledger.worktrack|abc|checkbox', 0, 'done'), 'macOS')) = 'applied',
  'a new mark is applied at version 1');
select pg_temp.check(pg_temp.version(public.push_desk_state(pg_temp.mark('ledger.worktrack|abc|checkbox', 0, 'waiting'), 'iOS')) = 1,
  'a second "new" mark for the same item is stale and answers the row the server holds');
select pg_temp.check((public.desk_sync_pull()->'deskState'->0->'data'->>'kind') = 'done', 'the stale write changed nothing');
select pg_temp.check(pg_temp.version(public.push_desk_state(pg_temp.mark('ledger.worktrack|abc|checkbox', 1, 'snoozed', '{"until":"2026-10-22T00:00:00Z"}'), 'iOS')) = 2,
  'based on version 1: applied as version 2');
select pg_temp.check(pg_temp.status(public.push_desk_state(pg_temp.mark('ledger.worktrack|abc|checkbox', 1, 'done'), 'macOS')) = 'stale',
  'another write based on version 1 is refused');
select pg_temp.check((public.push_desk_state(pg_temp.mark('ledger.worktrack|abc|checkbox', 1, 'done'), 'macOS')->0->'row'->'data'->>'until') = '2026-10-22T00:00:00Z',
  'and answers the current row (the snooze), so both sides can be shown');
select pg_temp.check(pg_temp.status(public.push_desk_state(pg_temp.mark('ledger.worktrack|abc|checkbox', 2, null), 'macOS')) = 'applied',
  'undoing a mark writes a tombstone');
select pg_temp.check((select deleted and kind is null and version = 3 from public.desk_state where id = 'ledger.worktrack|abc|checkbox'),
  'the tombstone is a new version with no mark');
select pg_temp.check(pg_temp.version(public.push_desk_state(pg_temp.mark('ledger.worktrack|abc|checkbox', 3, 'done'), 'iOS')) = 4,
  'a mark after the tombstone is version 4');
select pg_temp.check(pg_temp.status(public.push_desk_state(pg_temp.mark('ledger.talar|never|checkbox', 0, null), 'iOS')) = 'applied',
  'a tombstone for a row never on the server is answered as applied');
select pg_temp.check(not exists (select 1 from public.desk_state where id = 'ledger.talar|never|checkbox'), 'and writes nothing');
select pg_temp.check(pg_temp.status(public.push_desk_state(pg_temp.mark('ledger.talar|gone|checkbox', 5, 'done'), 'iOS')) = 'stale',
  'a change based on a version the server does not hold is stale');
select pg_temp.check(pg_temp.status(public.push_desk_state(pg_temp.mark('brief.worktrack|worktrack.expired.emu_herat|fact', 0, 'done'), 'macOS')) = 'invalid',
  'a WorkTrack company id in clear is refused');
select pg_temp.check(pg_temp.status(public.push_desk_state(pg_temp.mark('brief.worktrack|h-0123456789abcdef|fact', 0, 'done'), 'macOS')) = 'applied',
  'the same item with its subject hashed is taken');
select pg_temp.check(pg_temp.status(public.push_desk_state(pg_temp.mark('brief.siteMessages|site.42|fact', 0, 'waiting'), 'macOS')) = 'invalid',
  'a website entry id in clear is refused');
select pg_temp.check(pg_temp.status(public.push_desk_state(pg_temp.mark('ledger.talar|y|checkbox', 0, 'dismissed'), 'macOS')) = 'invalid',
  'a dismissal without its reason is refused');
select pg_temp.check(pg_temp.status(public.push_desk_state(pg_temp.mark('ledger.talar|y|checkbox', 0, 'dismissed',
  jsonb_build_object('reason', 'token ghp_' || repeat('a', 36))), 'macOS')) = 'invalid', 'a reason that holds a token is refused');
select pg_temp.check(pg_temp.status(public.push_desk_state(pg_temp.mark('ledger.talar|y|checkbox', 0, 'snoozed'), 'macOS')) = 'invalid',
  'a snooze without its end is refused');
select pg_temp.check(pg_temp.status(public.push_desk_state(pg_temp.mark('ledger.talar|y|checkbox', 0, 'done', '{"factHash":"not-a-hash"}'), 'macOS')) = 'invalid',
  'a fact hash that is not one is refused');
select pg_temp.check(pg_temp.version(public.push_desk_state(pg_temp.mark('ledger.talar|y|checkbox', 0, 'dismissed',
  '{"reason":"Handled by the owner","title":"Sample Clinic owes 300 USD","detail":"x"}'), 'macOS')) = 1,
  'a dismissal with its reason is taken');
select pg_temp.check(not (public.desk_sync_pull()::text ~ 'Sample Clinic'), 'a title sent with a mark is never stored');
select pg_temp.check((select count(*) = 3 from jsonb_array_elements(
    public.push_desk_state('[{"id":"ledger.velro|a|checkbox","expectedVersion":0,"data":{"kind":"done","at":"2026-10-19T10:00:00Z","factHash":"0123456789abcdef"}},
                             {"id":"bad id","expectedVersion":0,"data":{"kind":"done","at":"2026-10-19T10:00:00Z","factHash":"0123456789abcdef"}},
                             {"id":"ledger.velro|b|checkbox","expectedVersion":0,"data":{"kind":"done","at":"2026-10-19T10:00:00Z","factHash":"0123456789abcdef"}}]', 'macOS')) r
    where r->>'status' = case when r->>'id' = 'bad id' then 'invalid' else 'applied' end),
  'one refused row in a batch leaves the others applied');

-- MARK: obligations and vendors
create function pg_temp.ob(id text, entry text, key text, expected bigint, data jsonb, rev int default null) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('id', id, 'entry', entry, 'key', key, 'expectedVersion', expected,
                                                                'data', data, 'seedRevision', rev)))
$$;
select pg_temp.check(pg_temp.status(public.push_obligations(pg_temp.ob('row:owner.1', 'row', 'owner.1', 0,
  '{"id":"owner.1","title":"Pay the sample host","area":"accounts","due":"2026-11-01","source":"","recordedOn":"2026-10-19","leadDays":[30,14,7,1],"origin":"owner"}'), 'macOS')) = 'invalid',
  'an owner row without a source is refused');
select pg_temp.check(pg_temp.status(public.push_obligations(pg_temp.ob('row:seed.x', 'row', 'seed.x', 0,
  '{"id":"seed.x","title":"A seed row passed off as the owner''s","area":"accounts","source":"x","recordedOn":"2026-10-19","leadDays":[30],"origin":"owner"}'), 'macOS')) = 'invalid',
  'an owner row whose id is not owner.* is refused');
select pg_temp.check(pg_temp.status(public.push_obligations(pg_temp.ob('row:owner.1', 'row', 'owner.1', 0,
  '{"id":"owner.1","title":"Pay the sample host","area":"accounts","due":"2026-11-01","source":"sample bill","recordedOn":"2026-10-19","leadDays":[30,14,7,1],"origin":"owner"}'), 'macOS')) = 'applied',
  'an owner row with its source is taken');
select pg_temp.check((select due from public.obligations where id = 'row:owner.1') = '2026-11-01', 'its due day is read from the row');
select pg_temp.check(pg_temp.status(public.push_obligations(pg_temp.ob('done:owner.1|2026-11-01', 'done', 'owner.1', 0,
  '{"obligationID":"owner.1","due":"2026-11-01","on":"2026-10-19","evidence":"  ","enteredAt":"2026-10-19T10:00:00Z"}'), 'iOS')) = 'invalid',
  'a Done without evidence is refused');
select pg_temp.check(pg_temp.status(public.push_obligations(pg_temp.ob('done:owner.1|2026-11-02', 'done', 'owner.1', 0,
  '{"obligationID":"owner.1","due":"2026-11-01","on":"2026-10-19","evidence":"receipt 1","enteredAt":"2026-10-19T10:00:00Z"}'), 'iOS')) = 'invalid',
  'a Done whose id names another due day is refused');
select pg_temp.check(pg_temp.status(public.push_obligations(pg_temp.ob('done:owner.1|2026-11-01', 'done', 'owner.1', 0,
  '{"obligationID":"owner.1","due":"2026-11-01","on":"2026-10-19","evidence":"sample receipt 1","enteredAt":"2026-10-19T10:00:00Z"}'), 'iOS')) = 'applied',
  'a Done with its evidence is taken');
select pg_temp.check(pg_temp.status(public.push_obligations(pg_temp.ob('done:owner.1|2026-11-01', 'done', 'owner.1', 0,
  '{"obligationID":"owner.1","due":"2026-11-01","on":"2026-10-18","evidence":"another receipt","enteredAt":"2026-10-19T10:05:00Z"}'), 'macOS')) = 'stale',
  'a second Done for the same day from another device is stale, not written over the first');
select pg_temp.check(pg_temp.status(public.push_obligations(pg_temp.ob('done:owner.1|2026-11-01', 'done', 'owner.1', 1, null), 'macOS')) = 'applied',
  'reopening is applied');
select pg_temp.check((select deleted and data is null and due = '2026-11-01' and version = 2 from public.obligations where id = 'done:owner.1|2026-11-01'),
  'as a tombstone that keeps its day');
select pg_temp.check(pg_temp.status(public.push_obligations(pg_temp.ob('done:owner.1|2026-11-01', 'date', 'owner.1', 2,
  '{"obligationID":"owner.1","due":"2026-11-01","source":"x","enteredAt":"2026-10-19T10:00:00Z"}'), 'macOS')) = 'invalid',
  'the entry of a row cannot change');
select pg_temp.check(pg_temp.status(public.push_obligations(pg_temp.ob('date:owner.1', 'date', 'owner.1', 0,
  '{"obligationID":"owner.1","due":"2026-11-03","source":"","enteredAt":"2026-10-19T10:00:00Z"}'), 'macOS')) = 'invalid',
  'a date without its source is refused');
select pg_temp.check(pg_temp.status(public.push_obligations(pg_temp.ob('row:owner.2', 'row', 'owner.2', 0,
  jsonb_build_object('id', 'owner.2', 'title', 'Renew', 'area', 'other', 'source', 'key -----BEGIN PRIVATE KEY----- here',
                     'recordedOn', '2026-10-19', 'leadDays', '[30]'::jsonb, 'origin', 'owner')), 'macOS')) = 'invalid',
  'a row that holds a key is refused');
select pg_temp.check(pg_temp.status(public.push_obligations(pg_temp.ob('seed:test.x', 'seed', 'test.x', 0,
  '{"id":"test.x","title":"Sample","area":"other","source":"s","recordedOn":"2026-10-19","leadDays":[30],"origin":"seed"}'), 'macOS')) = 'invalid',
  'a seed row without its revision is refused');
create function pg_temp.vd(id text, entry text, key text, expected bigint, data jsonb, rev int default null) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('id', id, 'entry', entry, 'key', key, 'expectedVersion', expected,
                                                                'data', data, 'seedRevision', rev)))
$$;
select pg_temp.check(pg_temp.status(public.push_vendors(pg_temp.vd('account:owner.a', 'account', 'owner.a', 0,
  '{"id":"owner.a","name":"Sample","purpose":"","source":"s","recordedOn":"2026-10-19","origin":"owner","cost":{"amount":0,"currency":"USD","cycle":"yearly","source":"bill"}}'), 'macOS')) = 'invalid',
  'an account with a cost of zero is refused');
select pg_temp.check(pg_temp.status(public.push_vendors(pg_temp.vd('facts:sample', 'facts', 'sample', 0,
  '{"edits":[{"accountID":"sample","renewal":"2026-12-01","enteredAt":"2026-10-19T10:00:00Z"}]}'), 'macOS')) = 'invalid',
  'a renewal recorded without its source is refused');
select pg_temp.check(pg_temp.status(public.push_vendors(pg_temp.vd('facts:sample', 'facts', 'sample', 0,
  '{"edits":[{"accountID":"other","renewal":"2026-12-01","renewalSource":"bill","enteredAt":"2026-10-19T10:00:00Z"}]}'), 'macOS')) = 'invalid',
  'an edit filed under another account is refused');
select pg_temp.check(pg_temp.status(public.push_vendors(pg_temp.vd('facts:sample', 'facts', 'sample', 0,
  '{"edits":[{"accountID":"sample","renewal":"2026-12-01","renewalSource":"bill","enteredAt":"2026-10-19T10:00:00Z"}]}'), 'macOS')) = 'applied',
  'an account''s facts with their sources are taken');
-- A renewal (or any day the sweep reads) is a real day or nothing: one bad row must never stop the daily sweeps.
select pg_temp.check(pg_temp.status(public.push_vendors(pg_temp.vd('account:owner.b', 'account', 'owner.b', 0,
  '{"id":"owner.b","name":"Sample","purpose":"","source":"s","recordedOn":"2026-10-19","origin":"owner","renewal":"next spring","renewalSource":"bill"}'), 'macOS')) = 'invalid',
  'an account renewal of ''next spring'' is refused');
select pg_temp.check(pg_temp.status(public.push_vendors(pg_temp.vd('account:owner.b', 'account', 'owner.b', 0,
  '{"id":"owner.b","name":"Sample","purpose":"","source":"s","recordedOn":"2026-10-19","origin":"owner","renewal":"tomorrow","renewalSource":"bill"}'), 'macOS')) = 'invalid',
  'an account renewal of ''tomorrow'' is refused');
select pg_temp.check(pg_temp.status(public.push_vendors(pg_temp.vd('facts:sample2', 'facts', 'sample2', 0,
  '{"edits":[{"accountID":"sample2","renewal":"2026-02-30","renewalSource":"bill","enteredAt":"2026-10-19T10:00:00Z"}]}'), 'macOS')) = 'invalid',
  'a recorded renewal of 2026-02-30 is refused');
select pg_temp.check(pg_temp.status(public.push_vendors(pg_temp.vd('facts:sample2', 'facts', 'sample2', 0,
  '{"edits":[{"accountID":"sample2","renewal":"2026-12-01","renewalSource":"bill","enteredAt":"2026-10-19T10:00:00Z"},{"accountID":"sample2","renewal":"infinity","renewalSource":"bill","enteredAt":"2026-10-19T11:00:00Z"}]}'), 'macOS')) = 'invalid',
  'a recorded renewal of ''infinity'' is refused, even after a good one');
select pg_temp.check(pg_temp.status(public.push_vendors(pg_temp.vd('seed:sample3', 'seed', 'sample3', 0,
  '{"id":"sample3","name":"Sample","purpose":"","source":"s","recordedOn":"2026-10-19","origin":"seed","renewal":"2026-13-01","renewalSource":"bill"}', 3), 'macOS')) = 'invalid',
  'a seed account with a renewal that is not a day is refused');
select pg_temp.check(pg_temp.status(public.push_obligations(pg_temp.ob('row:owner.3', 'row', 'owner.3', 0,
  '{"id":"owner.3","title":"Sample","area":"other","due":"infinity","source":"s","recordedOn":"2026-10-19","leadDays":[30],"origin":"owner"}'), 'macOS')) = 'invalid',
  'an owner row due ''infinity'' is refused');
select pg_temp.check(pg_temp.status(public.push_obligations(pg_temp.ob('date:owner.1', 'date', 'owner.1', 0,
  '{"obligationID":"owner.1","due":"tomorrow","source":"x","enteredAt":"2026-10-19T10:00:00Z"}'), 'macOS')) = 'invalid',
  'a date of ''tomorrow'' is refused');
select pg_temp.check(pg_temp.status(public.push_obligations(pg_temp.ob('date:account.sample.renewal', 'date', 'account.sample.renewal', 0,
  '{"obligationID":"account.sample.renewal","due":"2026-12-02","source":"x","enteredAt":"2026-10-19T10:00:00Z"}'), 'macOS')) = 'invalid',
  'an account''s renewal day is set on its card, never as a date');
reset role;
select pg_temp.check(not private.is_iso_day('2026-2-01') and not private.is_iso_day('2026-02-01T00:00:00Z') and not private.is_iso_day(null)
  and private.is_iso_day('2028-02-29') and not private.is_iso_day('2027-02-29'), 'is_iso_day: YYYY-MM-DD and a real day only');
set role authenticated;
select pg_temp.check((select count(*) from public.audit_events where table_name in ('desk_state', 'obligations', 'vendors')) > 0
  and (select bool_and(actor = '00000000-0000-0000-0000-00000000000a') from public.audit_events where table_name in ('desk_state', 'obligations', 'vendors')),
  'every write is audited with the admin who made it');

-- MARK: the Mac's ledger reading
create function pg_temp.reading(at text, title text) returns jsonb language sql as $$
  select jsonb_build_object('readAt', at, 'digest', encode(sha256(convert_to(title, 'UTF8')), 'hex'),
    'sources', '[{"id":"worktrack","path":"~/Projects/Multiplatform/WorkTrack/PRIORITIES.md","state":"read","open":1,"ticked":0}]'::jsonb,
    'items', jsonb_build_array(jsonb_build_object('id', 'ledger.worktrack|0123|checkbox', 'title', title, 'domain', 'worktrack',
      'domainName', 'WorkTrack', 'severity', 'high', 'kind', 'task', 'kindKey', 'checkbox', 'subject', 'P0',
      'file', '~/Projects/Multiplatform/WorkTrack/PRIORITIES.md', 'line', 12, 'ownerAction', false, 'factHash', '0123456789abcdef')))
$$;
select pg_temp.check(public.replace_desk_items(0, pg_temp.reading('2026-10-19T10:00:00Z', 'Sign the sample contract'))->>'status' = 'applied',
  'the first reading is applied');
select pg_temp.check(public.replace_desk_items(1, pg_temp.reading('2026-10-19T10:30:00Z', 'Sign the sample contract'))->>'status' = 'unchanged',
  'the same lines are "unchanged"');
select pg_temp.check((select version = 2 and read_at = '2026-10-19T10:30:00Z' from public.desk_ledger_reading), 'and only move the time');
select pg_temp.check(public.replace_desk_items(1, pg_temp.reading('2026-10-19T11:00:00Z', 'Changed'))->>'status' = 'stale',
  'a reading based on an old version is stale');
select pg_temp.check(public.replace_desk_items(2, jsonb_set(pg_temp.reading('2026-10-19T11:00:00Z', 'Changed'), '{items,0,id}',
  '"brief.licences|licence.expired.L-1|fact"'))->>'status' = 'invalid', 'a Brief line is never a ledger item');
select pg_temp.check(public.replace_desk_items(2, jsonb_set(pg_temp.reading('2026-10-19T11:00:00Z', 'Changed'), '{items,0,subject}',
  to_jsonb('see ghp_' || repeat('a', 36))))->>'status' = 'invalid', 'a line whose subject holds a token is refused');
select pg_temp.check((select title from public.desk_items) = 'Sign the sample contract', 'and the refused reading left the last one');
select pg_temp.check(public.replace_desk_items(2, pg_temp.reading('2026-10-19T11:00:00Z', 'Changed'))->>'status' = 'applied', 'new lines are applied');
select pg_temp.check((public.desk_sync_pull()->'ledger'->'items'->0->>'title') = 'Changed'
  and (public.desk_sync_pull()->'ledger'->>'version')::int = 3
  and jsonb_array_length(public.desk_sync_pull()->'ledger'->'items') = 1, 'and replace the old ones');
-- A Mac whose clock runs ahead: its reading is stored at the server's time, and the next one (earlier by the Mac's
-- clock, once corrected) still replaces it. The version orders the writes, not the clock.
select pg_temp.check(public.replace_desk_items(3, pg_temp.reading(public.iso8601(now() + interval '2 days'), 'From the future'))->>'status' = 'applied',
  'a reading dated ahead of the server is taken');
select pg_temp.check((select read_at <= now() from public.desk_ledger_reading), 'at the server''s time, never in the future');
select pg_temp.check(public.replace_desk_items(4, pg_temp.reading('2026-10-19T12:00:00Z', 'After the clock was fixed'))->>'status' = 'applied',
  'and a later reading with an earlier time is not refused for its time');
select pg_temp.check((select title from public.desk_items) = 'After the clock was fixed', 'it replaced the lines');
select pg_temp.check(public.replace_desk_items(5, jsonb_build_object('readAt', '2026-10-19T12:30:00Z', 'linesOff', true, 'sources', '[]'::jsonb,
  'items', '[]'::jsonb, 'digest', encode(sha256(convert_to('[]', 'UTF8')), 'hex')))->>'status' = 'applied', 'lines turned off on the Mac');
select pg_temp.check((public.desk_sync_pull()->'ledger'->>'linesOff')::boolean
  and jsonb_array_length(public.desk_sync_pull()->'ledger'->'items') = 0, 'the reading says so, with no lines');
select pg_temp.check(length(public.desk_sync_pull()->>'epoch') = 36 and public.desk_sync_pull()->>'epoch' = public.desk_sync_pull()->>'epoch',
  'the pull names this set of tables (its epoch)');

-- MARK: the sweep, on the fixture's rows (the same rows the Swift parity test reads; all of its seed rows, including
-- the domain one the app no longer sends, as an older app would have sent them)
reset role;
reset request.jwt.claim.sub;
truncate public.obligations, public.vendors;
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select pg_temp.check((select bool_and(r->>'status' = 'applied') from jsonb_array_elements(public.push_obligations(
  (select jsonb_agg(jsonb_build_object('id', 'seed:' || (s->>'id'), 'entry', 'seed', 'key', s->>'id', 'expectedVersion', 0, 'data', s,
                                        'seedRevision', (:'fixture'::jsonb->>'seedRevision')::int))
   from jsonb_array_elements(:'fixture'::jsonb->'seed') s)
  || (select jsonb_agg(jsonb_build_object('id', 'row:' || (o->>'id'), 'entry', 'row', 'key', o->>'id', 'expectedVersion', 0, 'data', o))
      from jsonb_array_elements(:'fixture'::jsonb->'file'->'added') o)
  || (select jsonb_agg(jsonb_build_object('id', 'date:' || (d->>'obligationID'), 'entry', 'date', 'key', d->>'obligationID',
                                          'expectedVersion', 0, 'data', d))
      -- As the app sends them (DeskCloudMapping.localObligations): never a date on an account's renewal row.
      from jsonb_array_elements(:'fixture'::jsonb->'file'->'dates') d where d->>'obligationID' !~ '^account\..+\.renewal$')
  || (select jsonb_agg(jsonb_build_object('id', 'done:' || (c->>'obligationID') || '|' || coalesce(c->>'due', '-'), 'entry', 'done',
                                          'key', c->>'obligationID', 'expectedVersion', 0, 'data', c))
      from jsonb_array_elements(:'fixture'::jsonb->'file'->'completions') c), 'macOS')) r), 'the fixture''s obligations are taken');
select pg_temp.check((select bool_and(r->>'status' = 'applied') from jsonb_array_elements(public.push_vendors(
  (select jsonb_agg(jsonb_build_object('id', 'seed:' || (a->>'id'), 'entry', 'seed', 'key', a->>'id', 'expectedVersion', 0, 'data', a,
                                        'seedRevision', (:'fixture'::jsonb->>'seedRevision')::int))
   from jsonb_array_elements(:'fixture'::jsonb->'seedAccounts') a)
  || (select jsonb_agg(jsonb_build_object('id', 'account:' || (a->>'id'), 'entry', 'account', 'key', a->>'id', 'expectedVersion', 0, 'data', a))
      from jsonb_array_elements(:'fixture'::jsonb->'file'->'accounts') a)
  || (select jsonb_agg(jsonb_build_object('id', 'facts:' || g.account_id, 'entry', 'facts', 'key', g.account_id, 'expectedVersion', 0,
                                          'data', jsonb_build_object('edits', g.edits)))
      from (select e->>'accountID' as account_id, jsonb_agg(e order by e->>'enteredAt') as edits
            from jsonb_array_elements(:'fixture'::jsonb->'file'->'accountEdits') e group by 1) g), 'macOS')) r),
  'the fixture''s accounts are taken');
reset role;
reset request.jwt.claim.sub;

select pg_temp.check(private.sentinel_obligation_sweep((:'fixture'::jsonb->>'today')::date)
  = jsonb_array_length(:'fixture'::jsonb->'expectedKeys'), 'sweep: one event per expected alert');
select pg_temp.check((select jsonb_agg(dedup_key order by dedup_key) from public.sentinel_events where kind = 'obligationDue')
  = :'fixture'::jsonb->'expectedKeys', 'sweep: the same keys as the app''s ObligationAlerts');
select pg_temp.check(private.sentinel_obligation_sweep((:'fixture'::jsonb->>'today')::date) = 0, 'sweep again the same day: nothing new');
select pg_temp.check(private.sentinel_obligation_sweep((:'fixture'::jsonb->>'nextDay')::date)
  = jsonb_array_length(:'fixture'::jsonb->'expectedNextDayKeys'), 'next day: only the windows that moved');
select pg_temp.check((select jsonb_agg(dedup_key order by dedup_key) from public.sentinel_events
                      where kind = 'obligationDue' and dedup_key not in (select jsonb_array_elements_text(:'fixture'::jsonb->'expectedKeys')))
  = :'fixture'::jsonb->'expectedNextDayKeys', 'next day: the keys the app names');
select pg_temp.check((select severity || '|' || title || '|' || (detail->>'lead') || '|' || (detail->>'daysLeft') from public.sentinel_events
                      where dedup_key = 'obligation:test.seed-f:2026-10-19:0') = 'critical|Sample seed row due today is due today|0|0',
  'due today: critical, with its window and days in the detail');
select pg_temp.check((select severity || '|' || product from public.sentinel_events where dedup_key = 'obligation:test.seed-a:2026-10-26:7')
  = 'warning|Linumic', 'the 7-day window is a warning; a row without a product is the company''s');
select pg_temp.check((select severity || '|' || title from public.sentinel_events where dedup_key = 'obligation:account.test-host.renewal:2026-11-03:30')
  = 'info|Sample Host: renewal is due in 15 days', 'an account''s renewal from its newest recorded day, the 30-day window is info');
select pg_temp.check((select detail->>'title' = 'Sample Host' and (detail->>'renewal')::boolean from public.sentinel_events
                      where dedup_key = 'obligation:account.test-host.renewal:2026-11-03:30')
  and (select detail->>'title' = 'Sample seed row due today' and not (detail->>'renewal')::boolean from public.sentinel_events
       where dedup_key = 'obligation:test.seed-f:2026-10-19:0'),
  'the detail carries the title (or the account''s name) for the app to word the line');
select pg_temp.check((select count(*) from public.sentinel_events where subject in ('test.seed-d', 'test.nowhere', 'test.seed-c', 'test.seed-b')) = 0,
  'done, undated, beyond every window and unknown rows bring nothing');
select pg_temp.check(exists (select 1 from public.obligations where id = 'seed:domain.example.com' and not deleted)
  and not exists (select 1 from private.obligation_schedule() where obligation_id = 'domain.example.com')
  and not exists (select 1 from public.sentinel_events where subject = 'domain.example.com'),
  'a seed row a live reading replaces on the devices (a domain) is never swept, even when an app sent it');

-- A Done recorded for the day closes it; a tombstone (reopened) opens it again for the next window.
select pg_temp.check((select count(*) from private.obligation_schedule() where obligation_id = 'test.seed-a' and not closed) = 1, 'test.seed-a open');
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select public.push_obligations(pg_temp.ob('done:test.seed-a|2026-10-26', 'done', 'test.seed-a', 0,
  '{"obligationID":"test.seed-a","due":"2026-10-26","on":"2026-10-20","evidence":"sample post moved","enteredAt":"2026-10-20T10:00:00Z"}'), 'iOS');
reset role;
reset request.jwt.claim.sub;
select pg_temp.check((select closed from private.obligation_schedule() where obligation_id = 'test.seed-a'), 'a Done for its day closes it');
select private.sentinel_obligation_sweep('2026-10-25');
select pg_temp.check(not exists (select 1 from public.sentinel_events where dedup_key = 'obligation:test.seed-a:2026-10-26:1')
  and exists (select 1 from public.sentinel_events where dedup_key = 'obligation:test.seed-g:2026-11-15:30'),
  'a closed row brings no further window, the open ones keep theirs');

-- MARK: reading the events
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select pg_temp.check(not exists (select 1 from jsonb_array_elements(public.sentinel_recent_events(500, true)) e where e->>'kind' = 'obligationDue'),
  'the two-argument call (the app of 2026-10-18) gets no obligation events');
select pg_temp.check(exists (select 1 from jsonb_array_elements(public.sentinel_recent_events(500, true, true)) e
                             where e->>'kind' = 'obligationDue' and e->'detail'->>'key' = 'obligation:test.seed-f:2026-10-19:0'),
  'asked for, they come with the app''s key in the detail');
select pg_temp.check((public.sentinel_overview()->>'unacknowledged')::int = 0
  and (public.sentinel_overview()->>'unacknowledgedObligations')::int
      = (select count(*) from public.sentinel_events where kind = 'obligationDue' and acknowledged_at is null),
  'the overview counts obligation events on their own, so the app of 2026-10-18 never shows a count it can''t clear');
reset role;
reset request.jwt.claim.sub;
select pg_temp.check((select command from cron.job where jobname = 'sentinel-licences') = 'select private.sentinel_licence_sweep()'
  and (select schedule from cron.job where jobname = 'sentinel-licences') = '15 6 * * *', 'the 06:15 licence job is left as it was');
select pg_temp.check((select command from cron.job where jobname = 'sentinel-obligations') = 'select private.sentinel_obligation_sweep()',
  'the obligation sweep is a job of its own');
select pg_temp.check((select schedule from cron.job where jobname = 'sentinel-obligations') = '16 6 * * *', 'at 06:16 UTC');
select pg_temp.check((select count(*) from cron.job where jobname like 'sentinel-%') = 5
  and (select count(distinct username) from cron.job where jobname like 'sentinel-%') = 1, 'five jobs, one owner');

-- One bad row (written before the checks above, or by hand around them) and a licence 5 days from its end: each job
-- runs as pg_cron runs it, alone, and the licence event is still written.
do $$
declare def text;
begin
  select pg_get_constraintdef(c.oid) into def from pg_constraint c
  where c.conrelid = 'public.vendors'::regclass and pg_get_constraintdef(c.oid) like '%vendor_entry_ok%';
  execute 'alter table public.vendors drop constraint ' || (select quote_ident(conname) from pg_constraint
    where conrelid = 'public.vendors'::regclass and pg_get_constraintdef(oid) = def);
  insert into public.vendors (id, entry, account_id, data, written_on) values
    ('facts:test-mail', 'facts', 'test-mail',
     '{"edits":[{"accountID":"test-mail","renewal":"2026-02-30","renewalSource":"by hand","enteredAt":"2026-10-19T10:00:00Z"}]}', 'macOS'),
    ('account:owner.bad', 'account', 'owner.bad',
     '{"id":"owner.bad","name":"Bad","purpose":"","source":"by hand","recordedOn":"2026-10-19","origin":"owner","renewal":"infinity","renewalSource":"by hand"}', 'macOS');
  execute 'alter table public.vendors add constraint vendors_entry_ok ' || def || ' not valid';
end $$;
insert into public.licences (id, product, licence_id, customer, machine, issued, expires, status) values
  (gen_random_uuid(), 'mediflow', 'L-DS5', 'Sample Clinic', '*', '2026-01-01', (now() at time zone 'utc')::date + 5, 'active');
select command from cron.job where jobname in ('sentinel-licences', 'sentinel-obligations') order by jobname \gexec
select pg_temp.check(exists (select 1 from public.sentinel_events where subject = 'L-DS5' and kind = 'licenceExpiring'),
  'with a bad row present, the licence job still writes its event');
select pg_temp.check(not exists (select 1 from private.obligation_schedule() where obligation_id in ('account.test-mail.renewal', 'account.owner.bad.renewal')),
  'and the obligation job skips the days that are not days');
\echo ALL DESK SYNC SQL CHECKS PASSED
