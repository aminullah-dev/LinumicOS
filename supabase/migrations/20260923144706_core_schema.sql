-- Linumic Command Center: core schema (mirrors LinumicCore's Codable model, schema 2).

-- Who may use the Command Center. Filled in once Sign in with Apple is set up.
create table public.app_admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.app_admins where user_id = (select auth.uid())) $$;

-- Evidence rules (see PRODUCTS.md): VERIFIED / PARTIALLY VERIFIED need at least one source and a date.
create or replace function public.verification_is_consistent(v jsonb)
returns boolean language sql immutable set search_path = ''
as $$
  select v is not null
     and v->>'status' in ('verified','partiallyVerified','unknown','conflicting')
     and (v->>'status' not in ('verified','partiallyVerified')
          or (jsonb_array_length(coalesce(v->'sources','[]'::jsonb)) > 0 and v ? 'verifiedAt'))
$$;

-- Every fact in a product's `facts` object must be consistent, and a verified fact must carry a value.
create or replace function public.facts_are_consistent(f jsonb)
returns boolean language sql immutable set search_path = ''
as $$
  select coalesce(bool_and(
           public.verification_is_consistent(e.value->'verification')
           and (e.value->'verification'->>'status' not in ('verified','partiallyVerified') or e.value ? 'value')
         ), true)
  from jsonb_each(f) as e
$$;

create table public.inventory_meta (
  id int primary key default 1 check (id = 1),
  schema_version int not null default 2,
  seed_revision int not null default 1,
  updated_at timestamptz not null default now()
);
insert into public.inventory_meta (id) values (1);

create table public.products (
  id text primary key,
  name text not null check (length(trim(name)) > 0),
  facts jsonb not null default '{}'::jsonb check (public.facts_are_consistent(facts)),
  documentation jsonb not null default '[]'::jsonb,
  social_accounts jsonb not null default '[]'::jsonb,
  analytics jsonb not null default '[]'::jsonb,
  notes text not null default '',
  provenance jsonb not null,
  updated_at timestamptz not null default now()
);

create table public.repositories (
  id uuid primary key,
  product_id text not null references public.products (id) on delete cascade,
  name text not null,
  owner text,
  url text,
  host text not null default 'github' check (host in ('github','other')),
  type text not null default 'unknown',
  link jsonb not null check (public.verification_is_consistent(link)),
  github jsonb,
  local_checkouts jsonb not null default '[]'::jsonb,
  notes text not null default '',
  sort_order int not null default 0
);

create table public.platforms (
  id uuid primary key,
  product_id text not null references public.products (id) on delete cascade,
  platform text not null,
  component text,
  identifier text,
  source_version text,
  verification jsonb not null check (public.verification_is_consistent(verification)),
  sort_order int not null default 0
);

create table public.store_listings (
  id uuid primary key,
  product_id text not null references public.products (id) on delete cascade,
  store text not null check (store in ('appStore','googlePlay')),
  app_name text,
  app_identifier text,
  url text,
  storefront text,
  seller text,
  production_version text,
  latest_submitted_version text,
  review_status text,
  verification jsonb not null check (public.verification_is_consistent(verification)),
  sort_order int not null default 0
);

create table public.releases (
  id uuid primary key,
  product_id text not null references public.products (id) on delete cascade,
  version text not null,
  build_number text,
  platform text not null,
  environment text not null default 'production',
  stage text not null default 'planning',
  is_release_candidate boolean not null default false,
  release_date timestamptz,
  notes text not null default ''
);

create table public.roadmap_items (
  id uuid primary key,
  product_id text not null references public.products (id) on delete cascade,
  title text not null,
  detail text not null default '',
  status text not null default 'planned',
  target_version text,
  target_date timestamptz
);

create table public.issues (
  id uuid primary key,
  product_id text not null references public.products (id) on delete cascade,
  title text not null,
  severity text not null default 'medium' check (severity in ('low','medium','high','critical')),
  is_open boolean not null default true,
  url text
);

create table public.deployments (
  id uuid primary key,
  product_id text not null references public.products (id) on delete cascade,
  environment text not null,
  target text not null,
  status text not null default 'unknown',
  version text,
  deployed_at timestamptz
);

create table public.unresolved_items (
  id text primary key,
  kind text not null check (kind in ('possibleProduct','unresolvedRepository','sidelined')),
  name text not null,
  location text not null,
  findings text not null,
  question text,
  verification jsonb not null check (public.verification_is_consistent(verification))
);

-- Market intelligence: every evidence item has a source and a collection date; findings cite evidence.
create table public.market_sources (
  id uuid primary key,
  name text not null,
  kind text not null,
  publisher text,
  url text,
  language text,
  reliability_note text not null default ''
);

create table public.market_evidence (
  id uuid primary key,
  source_id uuid not null references public.market_sources (id) on delete restrict,
  excerpt text not null check (length(trim(excerpt)) > 0),
  published_at timestamptz,
  collected_at timestamptz not null,
  region text,
  sector text,
  language text,
  tags text[] not null default '{}'
);

create table public.market_findings (
  id uuid primary key,
  statement text not null,
  kind text not null check (kind in ('verified','derived')),
  method text not null default '',
  product_ids text[] not null default '{}',
  review text not null default 'draft' check (review in ('draft','reviewed')),
  created_at timestamptz not null,
  created_by text not null,
  check (kind <> 'derived' or length(trim(method)) > 0)
);

create table public.market_finding_evidence (
  finding_id uuid not null references public.market_findings (id) on delete cascade,
  evidence_id uuid not null references public.market_evidence (id) on delete restrict,
  primary key (finding_id, evidence_id)
);

create table public.content_items (
  id uuid primary key,
  title text not null,
  body text not null default '',
  networks text[] not null default '{}',
  product_id text references public.products (id) on delete set null,
  kind text not null default 'general',
  campaign text,
  language text,
  status text not null default 'draft' check (status in ('idea','draft','inReview','approved','scheduled','published','cancelled')),
  scheduled_for timestamptz,
  approved_by text,
  approved_at timestamptz,
  published_url text,
  published_at timestamptz,
  notes text not null default '',
  -- Nothing is posted by the system; "published" is recorded by a person, with the link, after approval.
  check (status <> 'published' or (published_url is not null and approved_at is not null)),
  check (status <> 'scheduled' or (scheduled_for is not null and approved_at is not null))
);

-- Foreign-key indexes.
create index on public.repositories (product_id);
create index on public.platforms (product_id);
create index on public.store_listings (product_id);
create index on public.releases (product_id);
create index on public.roadmap_items (product_id);
create index on public.issues (product_id);
create index on public.deployments (product_id);
create index on public.market_evidence (source_id);
create index on public.market_finding_evidence (evidence_id);
create index on public.content_items (product_id);

-- Append-only audit log: who, what, when, before and after.
create table public.audit_events (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  actor uuid default auth.uid(),
  actor_role text not null default current_user,
  table_name text not null,
  row_id text,
  action text not null check (action in ('INSERT','UPDATE','DELETE')),
  old_row jsonb,
  new_row jsonb
);
create index on public.audit_events (table_name, occurred_at desc);

create or replace function public.audit_trigger()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  rid text;
begin
  rid := coalesce(to_jsonb(new)->>'id', to_jsonb(old)->>'id',
                  to_jsonb(new)->>'finding_id', to_jsonb(old)->>'finding_id');
  insert into public.audit_events (table_name, row_id, action, old_row, new_row)
  values (tg_table_name, rid, tg_op,
          case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = ''
as $$ begin new.updated_at := now(); return new; end $$;

create trigger products_touch before update on public.products for each row execute function public.touch_updated_at();

do $$
declare t text;
begin
  foreach t in array array['products','repositories','platforms','store_listings','releases','roadmap_items','issues',
                           'deployments','unresolved_items','market_sources','market_evidence','market_findings',
                           'market_finding_evidence','content_items','app_admins','inventory_meta']
  loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_trigger()', t || '_audit', t);
  end loop;
end $$;

-- Row-level security: only listed admins may read or write. Nobody else, including the anon key.
do $$
declare t text;
begin
  foreach t in array array['app_admins','inventory_meta','products','repositories','platforms','store_listings','releases',
                           'roadmap_items','issues','deployments','unresolved_items','market_sources','market_evidence',
                           'market_findings','market_finding_evidence','content_items','audit_events']
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
  foreach t in array array['inventory_meta','products','repositories','platforms','store_listings','releases',
                           'roadmap_items','issues','deployments','unresolved_items','market_sources','market_evidence',
                           'market_findings','market_finding_evidence','content_items']
  loop
    execute format('create policy "admins manage %1$s" on public.%1$I for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()))', t);
  end loop;
end $$;

create policy "admins read admins" on public.app_admins for select to authenticated using ((select public.is_admin()));
create policy "admins read audit" on public.audit_events for select to authenticated using ((select public.is_admin()));
-- No insert/update/delete policies on audit_events: it's written only by the security-definer trigger.

revoke execute on function public.audit_trigger() from public, anon, authenticated;
