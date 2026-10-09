-- Licence ledger (LNM1 offline licences for MediFlow and KhayatYar), issued from Linumic OS.
--
-- What is here: the ledger only (customer, machine code, dates, edition, features, the issued key text,
-- status). What is never here: private signing keys. They stay in the issuing Mac's Keychain.
--
-- Sync rules (mirrored by LicenceLedger.merge in LinumicCore):
--   * rows are never deleted (no delete policy; upsert_licences never deletes);
--   * the signed fields of a licence never change after insert;
--   * status only moves forward: active -> superseded -> void;
--   * key_text and features can go from unknown (null) to known, never change after that;
--   * notes come from the copy edited last (updated_at).

create table public.licences (
  id uuid primary key,
  product text not null check (product in ('mediflow', 'khayatyar')),
  licence_id text not null unique check (length(trim(licence_id)) > 0),
  customer text not null check (length(trim(customer)) > 0),
  machine text not null check (machine = '*' or machine ~ '^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$'),
  issued date not null,
  expires date,
  edition text not null default 'standard',
  features text[],
  key_text text check (key_text is null or key_text like 'LNM1.%'),
  status text not null default 'active' check (status in ('active', 'superseded', 'void')),
  renewed_from text check (renewed_from is null or renewed_from <> licence_id),
  notes text not null default '',
  created_by text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expires is null or expires >= issued)
);
create index on public.licences (product, expires);
create index on public.licences (renewed_from);

-- Guard: signed fields are immutable, status never moves back, known key/features never change.
create or replace function public.licences_guard()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if (new.id, new.product, new.licence_id, new.customer, new.machine, new.issued, new.expires, new.edition)
     is distinct from (old.id, old.product, old.licence_id, old.customer, old.machine, old.issued, old.expires, old.edition) then
    raise exception 'Licence %: signed fields cannot change after issue', old.licence_id using errcode = '23514';
  end if;
  if old.key_text is not null and new.key_text is distinct from old.key_text then
    raise exception 'Licence %: the issued key cannot change', old.licence_id using errcode = '23514';
  end if;
  if old.features is not null and new.features is distinct from old.features then
    raise exception 'Licence %: features cannot change after issue', old.licence_id using errcode = '23514';
  end if;
  if (old.status = 'void' and new.status <> 'void') or (old.status = 'superseded' and new.status = 'active') then
    raise exception 'Licence %: status cannot go back from % to %', old.licence_id, old.status, new.status using errcode = '23514';
  end if;
  new.created_at := old.created_at;
  new.created_by := old.created_by;
  return new;
end $$;
revoke execute on function public.licences_guard() from public, anon, authenticated;

create trigger licences_guard before update on public.licences for each row execute function public.licences_guard();
create trigger licences_audit after insert or update or delete on public.licences for each row execute function public.audit_trigger();

-- Row-level security: admins only, and no delete policy at all.
alter table public.licences enable row level security;
create policy "admins read licences" on public.licences for select to authenticated using ((select private.is_admin()));
create policy "admins add licences" on public.licences for insert to authenticated with check ((select private.is_admin()));
create policy "admins update licences" on public.licences for update to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));

-- The ledger in the app's Codable shape (LicenceRecord).
create or replace function public.export_licences()
returns jsonb language plpgsql stable security invoker set search_path = ''
as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id', l.id, 'product', l.product, 'licenceID', l.licence_id, 'customer', l.customer, 'machine', l.machine,
      'issued', to_char(l.issued, 'YYYY-MM-DD'), 'expires', to_char(l.expires, 'YYYY-MM-DD'), 'edition', l.edition,
      'features', to_jsonb(l.features), 'keyText', l.key_text, 'status', l.status, 'renewedFrom', l.renewed_from,
      'notes', l.notes, 'createdBy', l.created_by, 'createdAt', public.iso8601(l.created_at),
      'updatedAt', public.iso8601(l.updated_at))) order by l.issued desc, l.licence_id desc)
    from public.licences l), '[]'::jsonb);
end $$;
revoke execute on function public.export_licences() from public, anon;
grant execute on function public.export_licences() to authenticated;

-- Inserts new licences and merges changes into existing ones. Never deletes.
create or replace function public.upsert_licences(rows jsonb)
returns void language plpgsql volatile security invoker set search_path = ''
as $$
declare
  clash text;
begin
  perform public.assert_admin();
  if jsonb_typeof(rows) is distinct from 'array' then
    raise exception 'rows must be a JSON array';
  end if;

  -- The same licence id with different signed contents is a real conflict (two devices issued the same id).
  select string_agg(t.licence_id, ', ') into clash
  from public.licences t
  join jsonb_array_elements(rows) x on x->>'licenceID' = t.licence_id
  where (t.product, t.customer, t.machine, t.issued, t.expires, t.edition)
        is distinct from (x->>'product', x->>'customer', x->>'machine', (x->>'issued')::date, (x->>'expires')::date,
                          coalesce(x->>'edition', 'standard'))
     or (t.key_text is not null and x->>'keyText' is not null and t.key_text <> x->>'keyText');
  if clash is not null then
    raise exception 'Licence ids already used with different contents: %', clash using errcode = '23505';
  end if;

  insert into public.licences as t (id, product, licence_id, customer, machine, issued, expires, edition, features,
                                    key_text, status, renewed_from, notes, created_by, created_at, updated_at)
  select (x->>'id')::uuid, x->>'product', x->>'licenceID', x->>'customer', x->>'machine', (x->>'issued')::date,
         (x->>'expires')::date, coalesce(x->>'edition', 'standard'),
         case when jsonb_typeof(x->'features') = 'array' then array(select jsonb_array_elements_text(x->'features')) end,
         x->>'keyText', coalesce(x->>'status', 'active'), x->>'renewedFrom', coalesce(x->>'notes', ''),
         coalesce(x->>'createdBy', ''), coalesce((x->>'createdAt')::timestamptz, now()),
         coalesce((x->>'updatedAt')::timestamptz, now())
  from jsonb_array_elements(rows) x
  on conflict (licence_id) do update set
    features = coalesce(t.features, excluded.features),
    key_text = coalesce(t.key_text, excluded.key_text),
    status = case when 'void' in (t.status, excluded.status) then 'void'
                  when 'superseded' in (t.status, excluded.status) then 'superseded'
                  else 'active' end,
    renewed_from = coalesce(t.renewed_from, excluded.renewed_from),
    notes = case when excluded.updated_at > t.updated_at then excluded.notes else t.notes end,
    updated_at = greatest(t.updated_at, excluded.updated_at)
  where (t.features, t.key_text, t.status, t.renewed_from, t.notes, t.updated_at)
        is distinct from (coalesce(t.features, excluded.features), coalesce(t.key_text, excluded.key_text),
                          case when 'void' in (t.status, excluded.status) then 'void'
                               when 'superseded' in (t.status, excluded.status) then 'superseded' else 'active' end,
                          coalesce(t.renewed_from, excluded.renewed_from),
                          case when excluded.updated_at > t.updated_at then excluded.notes else t.notes end,
                          greatest(t.updated_at, excluded.updated_at));
end $$;
revoke execute on function public.upsert_licences(jsonb) from public, anon;
grant execute on function public.upsert_licences(jsonb) to authenticated;

-- The whole-inventory export also carries the licence ledger, so a saved export_inventory() is a
-- complete backup. import_inventory() ignores it on purpose: its "delete what's missing" rule must
-- never apply to licences, which sync only through upsert_licences().
create or replace function public.export_inventory()
returns jsonb language plpgsql stable security invoker set search_path = ''
as $$
begin
  perform public.assert_admin();
  return jsonb_build_object(
    'schemaVersion', (select schema_version from public.inventory_meta where id = 1),
    'seedRevision', (select seed_revision from public.inventory_meta where id = 1),
    'products', coalesce((
      select jsonb_agg(
        p.facts || jsonb_build_object(
          'id', p.id, 'name', p.name, 'notes', p.notes, 'provenance', p.provenance,
          'documentation', p.documentation, 'socialAccounts', p.social_accounts, 'analytics', p.analytics,
          'repositories', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
              'id', r.id, 'name', r.name, 'owner', r.owner, 'url', r.url, 'host', r.host, 'type', r.type,
              'link', r.link, 'gitHub', r.github, 'localCheckouts', r.local_checkouts, 'notes', r.notes)) order by r.sort_order)
            from public.repositories r where r.product_id = p.id), '[]'::jsonb),
          'platforms', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
              'id', x.id, 'platform', x.platform, 'component', x.component, 'identifier', x.identifier,
              'sourceVersion', x.source_version, 'verification', x.verification)) order by x.sort_order)
            from public.platforms x where x.product_id = p.id), '[]'::jsonb),
          'storeListings', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
              'id', l.id, 'store', l.store, 'appName', l.app_name, 'appIdentifier', l.app_identifier, 'url', l.url,
              'storefront', l.storefront, 'seller', l.seller, 'productionVersion', l.production_version,
              'latestSubmittedVersion', l.latest_submitted_version, 'reviewStatus', l.review_status,
              'verification', l.verification, 'insights', l.insights)) order by l.sort_order)
            from public.store_listings l where l.product_id = p.id), '[]'::jsonb),
          'releases', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
              'id', r.id, 'version', r.version, 'buildNumber', r.build_number, 'platform', r.platform,
              'environment', r.environment, 'stage', r.stage, 'isReleaseCandidate', r.is_release_candidate,
              'releaseDate', public.iso8601(r.release_date), 'notes', r.notes)))
            from public.releases r where r.product_id = p.id), '[]'::jsonb),
          'roadmap', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
              'id', r.id, 'title', r.title, 'detail', r.detail, 'status', r.status,
              'targetVersion', r.target_version, 'targetDate', public.iso8601(r.target_date))))
            from public.roadmap_items r where r.product_id = p.id), '[]'::jsonb),
          'issues', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
              'id', i.id, 'title', i.title, 'severity', i.severity, 'isOpen', i.is_open, 'url', i.url)))
            from public.issues i where i.product_id = p.id), '[]'::jsonb),
          'deployments', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
              'id', d.id, 'environment', d.environment, 'target', d.target, 'status', d.status,
              'version', d.version, 'deployedAt', public.iso8601(d.deployed_at))))
            from public.deployments d where d.product_id = p.id), '[]'::jsonb)
        ) order by p.name)
      from public.products p), '[]'::jsonb),
    'unresolved', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'id', u.id, 'kind', u.kind, 'name', u.name, 'location', u.location, 'findings', u.findings,
        'question', u.question, 'verification', u.verification)) order by u.id) from public.unresolved_items u), '[]'::jsonb),
    'market', jsonb_build_object(
      'sources', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
          'id', s.id, 'name', s.name, 'kind', s.kind, 'publisher', s.publisher, 'url', s.url,
          'language', s.language, 'reliabilityNote', s.reliability_note))) from public.market_sources s), '[]'::jsonb),
      'evidence', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
          'id', e.id, 'sourceID', e.source_id, 'excerpt', e.excerpt, 'publishedAt', public.iso8601(e.published_at),
          'collectedAt', public.iso8601(e.collected_at), 'region', e.region, 'sector', e.sector,
          'language', e.language, 'tags', to_jsonb(e.tags)))) from public.market_evidence e), '[]'::jsonb),
      'findings', coalesce((select jsonb_agg(jsonb_build_object(
          'id', f.id, 'statement', f.statement, 'kind', f.kind, 'method', f.method,
          'productIDs', to_jsonb(f.product_ids), 'review', f.review, 'createdAt', public.iso8601(f.created_at),
          'createdBy', f.created_by,
          'evidenceIDs', coalesce((select jsonb_agg(fe.evidence_id) from public.market_finding_evidence fe where fe.finding_id = f.id), '[]'::jsonb)))
        from public.market_findings f), '[]'::jsonb)),
    'content', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'id', c.id, 'title', c.title, 'body', c.body, 'networks', to_jsonb(c.networks), 'productID', c.product_id,
        'kind', c.kind, 'campaign', c.campaign, 'language', c.language, 'status', c.status,
        'scheduledFor', public.iso8601(c.scheduled_for), 'approvedBy', c.approved_by,
        'approvedAt', public.iso8601(c.approved_at), 'publishedURL', c.published_url,
        'publishedAt', public.iso8601(c.published_at), 'notes', c.notes))) from public.content_items c), '[]'::jsonb),
    'licences', public.export_licences()
  );
end $$;
