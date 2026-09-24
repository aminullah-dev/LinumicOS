-- Store insights: rating, recent reviews and TestFlight builds per store listing, as read from the
-- stores (read-only). One jsonb column mirrors StoreListing.insights; export/import carry it through.

alter table public.store_listings add column if not exists insights jsonb;

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
        'publishedAt', public.iso8601(c.published_at), 'notes', c.notes))) from public.content_items c), '[]'::jsonb)
  );
end $$;

create or replace function public.import_inventory(doc jsonb)
returns void language plpgsql volatile security invoker set search_path = ''
as $$
declare
  fact_keys text[] := array['isLinumicProduct','legalOwner','priority','alsoKnownAs','summary','category',
                            'projectType','status','currentVersion','nextVersion','backend','website'];
  p jsonb;
  pid text;
begin
  perform public.assert_admin();
  if (doc->>'schemaVersion')::int is distinct from 2 then
    raise exception 'Unsupported schemaVersion %', doc->>'schemaVersion';
  end if;

  update public.inventory_meta set seed_revision = coalesce((doc->>'seedRevision')::int, 1), updated_at = now()
   where id = 1 and seed_revision is distinct from coalesce((doc->>'seedRevision')::int, 1);

  -- Products and their children.
  delete from public.products where id not in (select x->>'id' from jsonb_array_elements(doc->'products') x);

  for p in select * from jsonb_array_elements(doc->'products') loop
    pid := p->>'id';
    insert into public.products as t (id, name, facts, documentation, social_accounts, analytics, notes, provenance)
    values (pid, p->>'name',
            (select coalesce(jsonb_object_agg(k, p->k), '{}'::jsonb) from unnest(fact_keys) k where p ? k),
            coalesce(p->'documentation','[]'), coalesce(p->'socialAccounts','[]'), coalesce(p->'analytics','[]'),
            coalesce(p->>'notes',''), p->'provenance')
    on conflict (id) do update set name = excluded.name, facts = excluded.facts, documentation = excluded.documentation,
      social_accounts = excluded.social_accounts, analytics = excluded.analytics, notes = excluded.notes, provenance = excluded.provenance
    where (t.name, t.facts, t.documentation, t.social_accounts, t.analytics, t.notes, t.provenance)
          is distinct from (excluded.name, excluded.facts, excluded.documentation, excluded.social_accounts, excluded.analytics, excluded.notes, excluded.provenance);

    delete from public.repositories where product_id = pid and id not in (select (x->>'id')::uuid from jsonb_array_elements(coalesce(p->'repositories','[]')) x);
    insert into public.repositories as t (id, product_id, name, owner, url, host, type, link, github, local_checkouts, notes, sort_order)
    select (x->>'id')::uuid, pid, x->>'name', x->>'owner', x->>'url', coalesce(x->>'host','github'), coalesce(x->>'type','unknown'),
           x->'link', x->'gitHub', coalesce(x->'localCheckouts','[]'), coalesce(x->>'notes',''), (o - 1)::int
    from jsonb_array_elements(coalesce(p->'repositories','[]')) with ordinality as a(x, o)
    on conflict (id) do update set product_id = excluded.product_id, name = excluded.name, owner = excluded.owner, url = excluded.url,
      host = excluded.host, type = excluded.type, link = excluded.link, github = excluded.github,
      local_checkouts = excluded.local_checkouts, notes = excluded.notes, sort_order = excluded.sort_order
    where (t.product_id, t.name, t.owner, t.url, t.host, t.type, t.link, t.github, t.local_checkouts, t.notes, t.sort_order)
          is distinct from (excluded.product_id, excluded.name, excluded.owner, excluded.url, excluded.host, excluded.type, excluded.link,
                            excluded.github, excluded.local_checkouts, excluded.notes, excluded.sort_order);

    delete from public.platforms where product_id = pid and id not in (select (x->>'id')::uuid from jsonb_array_elements(coalesce(p->'platforms','[]')) x);
    insert into public.platforms as t (id, product_id, platform, component, identifier, source_version, verification, sort_order)
    select (x->>'id')::uuid, pid, x->>'platform', x->>'component', x->>'identifier', x->>'sourceVersion', x->'verification', (o - 1)::int
    from jsonb_array_elements(coalesce(p->'platforms','[]')) with ordinality as a(x, o)
    on conflict (id) do update set product_id = excluded.product_id, platform = excluded.platform, component = excluded.component,
      identifier = excluded.identifier, source_version = excluded.source_version, verification = excluded.verification, sort_order = excluded.sort_order
    where (t.product_id, t.platform, t.component, t.identifier, t.source_version, t.verification, t.sort_order)
          is distinct from (excluded.product_id, excluded.platform, excluded.component, excluded.identifier, excluded.source_version, excluded.verification, excluded.sort_order);

    delete from public.store_listings where product_id = pid and id not in (select (x->>'id')::uuid from jsonb_array_elements(coalesce(p->'storeListings','[]')) x);
    insert into public.store_listings as t (id, product_id, store, app_name, app_identifier, url, storefront, seller,
                                            production_version, latest_submitted_version, review_status, verification, insights, sort_order)
    select (x->>'id')::uuid, pid, x->>'store', x->>'appName', x->>'appIdentifier', x->>'url', x->>'storefront', x->>'seller',
           x->>'productionVersion', x->>'latestSubmittedVersion', x->>'reviewStatus', x->'verification', x->'insights', (o - 1)::int
    from jsonb_array_elements(coalesce(p->'storeListings','[]')) with ordinality as a(x, o)
    on conflict (id) do update set product_id = excluded.product_id, store = excluded.store, app_name = excluded.app_name,
      app_identifier = excluded.app_identifier, url = excluded.url, storefront = excluded.storefront, seller = excluded.seller,
      production_version = excluded.production_version, latest_submitted_version = excluded.latest_submitted_version,
      review_status = excluded.review_status, verification = excluded.verification,
      -- A client that predates insights sends none; keep what a newer client stored.
      insights = coalesce(excluded.insights, t.insights),
      sort_order = excluded.sort_order
    where (t.product_id, t.store, t.app_name, t.app_identifier, t.url, t.storefront, t.seller, t.production_version,
           t.latest_submitted_version, t.review_status, t.verification, t.insights, t.sort_order)
          is distinct from (excluded.product_id, excluded.store, excluded.app_name, excluded.app_identifier, excluded.url, excluded.storefront,
                            excluded.seller, excluded.production_version, excluded.latest_submitted_version, excluded.review_status,
                            excluded.verification, coalesce(excluded.insights, t.insights), excluded.sort_order);

    delete from public.releases where product_id = pid and id not in (select (x->>'id')::uuid from jsonb_array_elements(coalesce(p->'releases','[]')) x);
    insert into public.releases as t (id, product_id, version, build_number, platform, environment, stage, is_release_candidate, release_date, notes)
    select (x->>'id')::uuid, pid, x->>'version', x->>'buildNumber', x->>'platform', coalesce(x->>'environment','production'),
           coalesce(x->>'stage','planning'), coalesce((x->>'isReleaseCandidate')::boolean, false), (x->>'releaseDate')::timestamptz, coalesce(x->>'notes','')
    from jsonb_array_elements(coalesce(p->'releases','[]')) x
    on conflict (id) do update set product_id = excluded.product_id, version = excluded.version, build_number = excluded.build_number,
      platform = excluded.platform, environment = excluded.environment, stage = excluded.stage,
      is_release_candidate = excluded.is_release_candidate, release_date = excluded.release_date, notes = excluded.notes
    where (t.product_id, t.version, t.build_number, t.platform, t.environment, t.stage, t.is_release_candidate, t.release_date, t.notes)
          is distinct from (excluded.product_id, excluded.version, excluded.build_number, excluded.platform, excluded.environment,
                            excluded.stage, excluded.is_release_candidate, excluded.release_date, excluded.notes);

    delete from public.roadmap_items where product_id = pid and id not in (select (x->>'id')::uuid from jsonb_array_elements(coalesce(p->'roadmap','[]')) x);
    insert into public.roadmap_items as t (id, product_id, title, detail, status, target_version, target_date)
    select (x->>'id')::uuid, pid, x->>'title', coalesce(x->>'detail',''), coalesce(x->>'status','planned'), x->>'targetVersion', (x->>'targetDate')::timestamptz
    from jsonb_array_elements(coalesce(p->'roadmap','[]')) x
    on conflict (id) do update set product_id = excluded.product_id, title = excluded.title, detail = excluded.detail,
      status = excluded.status, target_version = excluded.target_version, target_date = excluded.target_date
    where (t.product_id, t.title, t.detail, t.status, t.target_version, t.target_date)
          is distinct from (excluded.product_id, excluded.title, excluded.detail, excluded.status, excluded.target_version, excluded.target_date);

    delete from public.issues where product_id = pid and id not in (select (x->>'id')::uuid from jsonb_array_elements(coalesce(p->'issues','[]')) x);
    insert into public.issues as t (id, product_id, title, severity, is_open, url)
    select (x->>'id')::uuid, pid, x->>'title', coalesce(x->>'severity','medium'), coalesce((x->>'isOpen')::boolean, true), x->>'url'
    from jsonb_array_elements(coalesce(p->'issues','[]')) x
    on conflict (id) do update set product_id = excluded.product_id, title = excluded.title, severity = excluded.severity,
      is_open = excluded.is_open, url = excluded.url
    where (t.product_id, t.title, t.severity, t.is_open, t.url)
          is distinct from (excluded.product_id, excluded.title, excluded.severity, excluded.is_open, excluded.url);

    delete from public.deployments where product_id = pid and id not in (select (x->>'id')::uuid from jsonb_array_elements(coalesce(p->'deployments','[]')) x);
    insert into public.deployments as t (id, product_id, environment, target, status, version, deployed_at)
    select (x->>'id')::uuid, pid, x->>'environment', x->>'target', coalesce(x->>'status','unknown'), x->>'version', (x->>'deployedAt')::timestamptz
    from jsonb_array_elements(coalesce(p->'deployments','[]')) x
    on conflict (id) do update set product_id = excluded.product_id, environment = excluded.environment, target = excluded.target,
      status = excluded.status, version = excluded.version, deployed_at = excluded.deployed_at
    where (t.product_id, t.environment, t.target, t.status, t.version, t.deployed_at)
          is distinct from (excluded.product_id, excluded.environment, excluded.target, excluded.status, excluded.version, excluded.deployed_at);
  end loop;

  -- Unresolved items.
  delete from public.unresolved_items where id not in (select x->>'id' from jsonb_array_elements(coalesce(doc->'unresolved','[]')) x);
  insert into public.unresolved_items as t (id, kind, name, location, findings, question, verification)
  select x->>'id', x->>'kind', x->>'name', x->>'location', x->>'findings', x->>'question', x->'verification'
  from jsonb_array_elements(coalesce(doc->'unresolved','[]')) x
  on conflict (id) do update set kind = excluded.kind, name = excluded.name, location = excluded.location,
    findings = excluded.findings, question = excluded.question, verification = excluded.verification
  where (t.kind, t.name, t.location, t.findings, t.question, t.verification)
        is distinct from (excluded.kind, excluded.name, excluded.location, excluded.findings, excluded.question, excluded.verification);

  -- Market intelligence (order matters because of foreign keys).
  delete from public.market_finding_evidence fe where not exists (
    select 1 from jsonb_array_elements(coalesce(doc->'market'->'findings','[]')) f, jsonb_array_elements_text(coalesce(f->'evidenceIDs','[]')) e
    where (f->>'id')::uuid = fe.finding_id and e::uuid = fe.evidence_id);
  delete from public.market_findings where id not in (select (x->>'id')::uuid from jsonb_array_elements(coalesce(doc->'market'->'findings','[]')) x);
  delete from public.market_evidence where id not in (select (x->>'id')::uuid from jsonb_array_elements(coalesce(doc->'market'->'evidence','[]')) x);
  delete from public.market_sources where id not in (select (x->>'id')::uuid from jsonb_array_elements(coalesce(doc->'market'->'sources','[]')) x);

  insert into public.market_sources as t (id, name, kind, publisher, url, language, reliability_note)
  select (x->>'id')::uuid, x->>'name', x->>'kind', x->>'publisher', x->>'url', x->>'language', coalesce(x->>'reliabilityNote','')
  from jsonb_array_elements(coalesce(doc->'market'->'sources','[]')) x
  on conflict (id) do update set name = excluded.name, kind = excluded.kind, publisher = excluded.publisher, url = excluded.url,
    language = excluded.language, reliability_note = excluded.reliability_note
  where (t.name, t.kind, t.publisher, t.url, t.language, t.reliability_note)
        is distinct from (excluded.name, excluded.kind, excluded.publisher, excluded.url, excluded.language, excluded.reliability_note);

  insert into public.market_evidence as t (id, source_id, excerpt, published_at, collected_at, region, sector, language, tags)
  select (x->>'id')::uuid, (x->>'sourceID')::uuid, x->>'excerpt', (x->>'publishedAt')::timestamptz, (x->>'collectedAt')::timestamptz,
         x->>'region', x->>'sector', x->>'language', coalesce(array(select jsonb_array_elements_text(x->'tags')), '{}')
  from jsonb_array_elements(coalesce(doc->'market'->'evidence','[]')) x
  on conflict (id) do update set source_id = excluded.source_id, excerpt = excluded.excerpt, published_at = excluded.published_at,
    collected_at = excluded.collected_at, region = excluded.region, sector = excluded.sector, language = excluded.language, tags = excluded.tags
  where (t.source_id, t.excerpt, t.published_at, t.collected_at, t.region, t.sector, t.language, t.tags)
        is distinct from (excluded.source_id, excluded.excerpt, excluded.published_at, excluded.collected_at, excluded.region,
                          excluded.sector, excluded.language, excluded.tags);

  insert into public.market_findings as t (id, statement, kind, method, product_ids, review, created_at, created_by)
  select (x->>'id')::uuid, x->>'statement', x->>'kind', coalesce(x->>'method',''),
         coalesce(array(select jsonb_array_elements_text(x->'productIDs')), '{}'), coalesce(x->>'review','draft'),
         (x->>'createdAt')::timestamptz, coalesce(x->>'createdBy','Owner')
  from jsonb_array_elements(coalesce(doc->'market'->'findings','[]')) x
  on conflict (id) do update set statement = excluded.statement, kind = excluded.kind, method = excluded.method,
    product_ids = excluded.product_ids, review = excluded.review, created_at = excluded.created_at, created_by = excluded.created_by
  where (t.statement, t.kind, t.method, t.product_ids, t.review, t.created_at, t.created_by)
        is distinct from (excluded.statement, excluded.kind, excluded.method, excluded.product_ids, excluded.review, excluded.created_at, excluded.created_by);

  insert into public.market_finding_evidence (finding_id, evidence_id)
  select (f->>'id')::uuid, e::uuid
  from jsonb_array_elements(coalesce(doc->'market'->'findings','[]')) f, jsonb_array_elements_text(coalesce(f->'evidenceIDs','[]')) e
  on conflict do nothing;

  -- Content calendar.
  delete from public.content_items where id not in (select (x->>'id')::uuid from jsonb_array_elements(coalesce(doc->'content','[]')) x);
  insert into public.content_items as t (id, title, body, networks, product_id, kind, campaign, language, status, scheduled_for,
                                         approved_by, approved_at, published_url, published_at, notes)
  select (x->>'id')::uuid, x->>'title', coalesce(x->>'body',''), coalesce(array(select jsonb_array_elements_text(x->'networks')), '{}'),
         x->>'productID', coalesce(x->>'kind','general'), x->>'campaign', x->>'language', coalesce(x->>'status','draft'),
         (x->>'scheduledFor')::timestamptz, x->>'approvedBy', (x->>'approvedAt')::timestamptz, x->>'publishedURL',
         (x->>'publishedAt')::timestamptz, coalesce(x->>'notes','')
  from jsonb_array_elements(coalesce(doc->'content','[]')) x
  on conflict (id) do update set title = excluded.title, body = excluded.body, networks = excluded.networks, product_id = excluded.product_id,
    kind = excluded.kind, campaign = excluded.campaign, language = excluded.language, status = excluded.status,
    scheduled_for = excluded.scheduled_for, approved_by = excluded.approved_by, approved_at = excluded.approved_at,
    published_url = excluded.published_url, published_at = excluded.published_at, notes = excluded.notes
  where (t.title, t.body, t.networks, t.product_id, t.kind, t.campaign, t.language, t.status, t.scheduled_for, t.approved_by,
         t.approved_at, t.published_url, t.published_at, t.notes)
        is distinct from (excluded.title, excluded.body, excluded.networks, excluded.product_id, excluded.kind, excluded.campaign,
                          excluded.language, excluded.status, excluded.scheduled_for, excluded.approved_by, excluded.approved_at,
                          excluded.published_url, excluded.published_at, excluded.notes);
end $$;
